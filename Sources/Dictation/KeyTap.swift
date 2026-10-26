import ApplicationServices
import CoreGraphics
import DictationCore
import Foundation

/// The single owner of keyboard input and the hotkey phase, through a session CGEventTap on the main run loop.
/// The tap is active, not listen-only, because that needs Accessibility (which paste needs anyway) instead of
/// adding Input Monitoring. Every event passes through except the Escape that cancels hands-free, the keys of a
/// shortcut that is not a modifier key alone, so they do not also type, and the keys pressed while recording.
@MainActor final class KeyTap {
    /// Marks our own Cmd+V, so a paste landing during the next hold is not taken for a chord.
    nonisolated static let syntheticMarker: Int64 = 0x4449_4354

    private(set) var machine: HotkeyMachine = .idle
    /// After every input that changed the phase, with the sound for that step, and when the tap starts running.
    /// Runs on a later main-queue turn, never inside the tap callback, as do `onPasteLast` and recording results.
    var onUpdate: (([CaptureCommand], Cue?) -> Void)?
    var onPasteLast: (() -> Void)?
    var hotkeys: [Shortcut] {
        didSet {
            guard hotkeys != oldValue else { return }
            reset()
        }
    }
    var pasteLast: Shortcut?
    var isRunning: Bool { tap != nil }

    private let timing = HotkeyTiming()
    private var tap: CFMachPort?
    private var deadlineTimer: Timer?
    private var trustTimer: Timer?
    /// The shortcut whose press began the current capture. While a key is down only that one moves the machine,
    /// so another dictation key pressed meanwhile counts as a chord.
    private var active: Shortcut?
    /// A key this tap swallowed going down, so its autorepeats and its release are swallowed too.
    private var swallowedKey: Int?
    private var recorder: ShortcutRecorder?
    private var recorded: ((ShortcutRecorder.Outcome) -> Void)?

    init(hotkeys: [Shortcut], pasteLast: Shortcut?) {
        self.hotkeys = hotkeys
        self.pasteLast = pasteLast
    }

    /// Prompts for Accessibility once if untrusted, then retries every 2 s until the tap can be created.
    func start() {
        guard tap == nil, !createTap() else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryTap() }
        }
    }

    /// The bar's stop or cancel button.
    func click(_ input: KeyInput) { _ = feed(input) }

    /// Capture failed to start.
    func abort() {
        machine.abort()
        scheduleDeadline()
    }

    /// The next keys pressed become a shortcut instead of reaching dictation or the focused app. `done` gets the
    /// result once, unless `stopRecording` comes first.
    func record(_ done: @escaping (ShortcutRecorder.Outcome) -> Void) {
        reset()
        recorder = ShortcutRecorder()
        recorded = done
    }

    func stopRecording() {
        recorder = nil
        recorded = nil
    }

    private func reset() {
        let wasCapturing = machine != .idle
        machine = .idle
        active = nil
        scheduleDeadline()
        if wasCapturing { onUpdate?([.cancel], nil) }
    }

    private func retryTap() {
        guard createTap() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        onUpdate?([], nil)
    }

    private func createTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
            | 1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// One key event. Returns whether to swallow it. The paste shortcut still reaches the machine as a key, so it
    /// cancels a hold the way any chord does.
    fileprivate func handle(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64, marker: Int64, isRepeat: Bool) -> Bool {
        guard marker != Self.syntheticMarker else { return false }
        if recorder != nil { return record(kind: kind, keyCode: keyCode, flags: flags) }
        let candidates = machine.expectsKeyDown ? [active ?? hotkeys[0]] : hotkeys
        let input = KeyInput.classify(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                                      shortcuts: candidates, at: .now)
        if case .hotkeyDown = input {
            active = candidates.first { $0.key == keyCode && $0.matches(flags: flags) }
            if kind == .keyDown { swallowedKey = keyCode }
        }
        var swallow = input.map(feed) ?? false
        if kind != .flagsChanged, swallowedKey == keyCode {
            if kind == .keyUp { swallowedKey = nil }
            swallow = true
        }
        if kind == .keyDown, let pasteLast, pasteLast.key == keyCode, pasteLast.matches(flags: flags) {
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onPasteLast?() }
                }
            }
            swallowedKey = keyCode
            swallow = true
        }
        return swallow
    }

    /// Typing keys are swallowed while recording, so they do not type into the window. Modifier changes pass, so
    /// the system's idea of which modifiers are down stays right.
    private func record(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64) -> Bool {
        guard var recorder else { return false }
        let outcome = recorder.handle(kind: kind, keyCode: keyCode, flags: flags)
        self.recorder = recorder
        if let outcome {
            let done = recorded
            stopRecording()
            if kind == .keyDown { swallowedKey = keyCode }
            DispatchQueue.main.async { done?(outcome) }
        }
        return kind != .flagsChanged
    }

    /// The system disables a tap whose callback was slow.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        recoverMissedRelease()
    }

    private func feed(_ input: KeyInput) -> Bool {
        let before = machine
        let step = machine.handle(input, timing: timing)
        if machine != before || !step.commands.isEmpty {
            scheduleDeadline()
            let commands = step.commands
            let cue = Cue.after(commands, wasListening: before.showsListening, isListening: machine.showsListening)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onUpdate?(commands, cue) }
            }
        }
        return step.consumeEvent
    }

    /// While the tap was disabled, a release may have gone by unseen. If the key is up now, feed the release.
    private func recoverMissedRelease() {
        guard machine.expectsKeyDown else { return }
        let shortcut = active ?? hotkeys[0]
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let keyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.key))
        guard !keyDown, shortcut.isDown(flags: flags) != true else { return }
        if swallowedKey == shortcut.key { swallowedKey = nil }
        _ = feed(.hotkeyUp(.now))
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = machine.deadline(timing) else { return }
        let timer = Timer(timeInterval: max(0, deadline - .now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    /// Reschedules even when the phase did not move, in case the timer fired a hair before the deadline.
    private func tick() {
        _ = feed(.tick(.now))
        scheduleDeadline()
    }
}

/// Runs on the main run loop, where the tap's source is installed.
private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keyTap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    let kind: KeyInput.EventKind
    switch type {
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    case .flagsChanged: kind = .flagsChanged
    default:
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { keyTap.reenable() }
        }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let marker = event.getIntegerValueField(.eventSourceUserData)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated {
        keyTap.handle(kind: kind, keyCode: keyCode, flags: flags, marker: marker, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
