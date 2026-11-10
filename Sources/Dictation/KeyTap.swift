import AppKit
import ApplicationServices
import CoreGraphics
import DictationCore
import Foundation
import os

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
    /// The open card's keys. Asked only between captures; true takes the key from the focused app.
    var onCardKey: ((CardKey) -> Bool)?
    /// Whether a card is open. Until one is, no key is looked at as a card key and no key's characters are read.
    var takesCardKeys = false
    var keys: CaptureKeys {
        didSet {
            guard keys != oldValue else { return }
            reset()
        }
    }
    /// What the capture running now is for. A dictation can become a Ghostwrite or a Hand off mid-press.
    var kind: CaptureKind { active.map(keys.kind(of:)) ?? .dictate }
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
    /// Double-tapping Left Control alone, which starts and ends a live talk. Off while the setting is off or a dictation
    /// key uses Left Control.
    var talkKey = false {
        didSet { if !talkKey { stopWatchingClicks() } }
    }
    var onDoubleTap: (() -> Void)?
    /// ⌃⌥M while a talk runs, which mutes or unmutes it.
    var onMuteKey: (() -> Void)?
    /// While a talk runs, the dictation keys do nothing, since the talk has the microphone.
    var suspended = false {
        didSet { if suspended, machine != .idle { abort() } }
    }
    private var doubleTap = DoubleTapDetector()
    /// A click while Left Control is down, as in Control-click, means the press was not a tap. Watched only while it is
    /// down, so clicks cost nothing the rest of the time, and by a monitor that never holds up the click.
    private var clickWatch: Any?

    init(keys: CaptureKeys, pasteLast: Shortcut?) {
        self.keys = keys
        self.pasteLast = pasteLast
    }

    /// Creates the tap once Accessibility allows it, checking every 2 s. `prompting` shows the system's Accessibility
    /// prompt now if access is missing. Trying the tap untrusted raises that prompt too, so the tap waits for trust.
    func start(prompting: Bool) {
        guard tap == nil else { return }
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary), createTap() { return }
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
        guard AXIsProcessTrusted(), createTap() else { return }
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
    fileprivate func handle(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64, marker: Int64, isRepeat: Bool,
                            characters: () -> String?) -> Bool {
        guard marker != Self.syntheticMarker else { return false }
        if recorder != nil { return record(kind: kind, keyCode: keyCode, flags: flags) }
        if talkKey, let tapInput = DoubleTapDetector.input(kind: kind, keyCode: keyCode, flags: flags) {
            if tapInput == .down { watchClicks() } else { stopWatchingClicks() }
            if doubleTap.feed(tapInput, at: .now) {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onDoubleTap?() } }
            }
        }
        if suspended { return duringTalk(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat) }
        var input: KeyInput?
        switch CaptureRouting.route(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat, machine: machine, active: active,
                                    keys: keys, at: .now) {
        case .retarget(let shortcut):
            active = shortcut
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onUpdate?([], nil) } }
            return false
        case .input(let routed, let shortcut):
            input = routed
            if case .hotkeyDown = routed {
                active = shortcut
                if kind == .keyDown { swallowedKey = keyCode }
            }
        case nil:
            break
        }
        if kind == .keyDown, takesCardKeys, !machine.isCapturing, swallowedKey != keyCode, let onCardKey,
           let key = CardKey(keyCode: keyCode, flags: flags, characters: characters), onCardKey(key) {
            swallowedKey = keyCode
            return true
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

    /// A key while a talk runs, when the dictation keys do nothing. Only the mute shortcut is taken, with its repeats and
    /// its release, so it doesn't also type into the app in front. Returns whether to swallow the key.
    private func duringTalk(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64, isRepeat: Bool) -> Bool {
        if kind == .keyDown, LiveTalkKey.isMute(keyCode: keyCode, flags: flags) {
            if !isRepeat { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onMuteKey?() } } }
            swallowedKey = keyCode
            return true
        }
        guard kind != .flagsChanged, swallowedKey == keyCode else { return false }
        if kind == .keyUp { swallowedKey = nil }
        return true
    }

    private func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.doubleTap.feed(.other, at: .now)
                self.stopWatchingClicks()
            }
        }
    }

    private func stopWatchingClicks() {
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        clickWatch = nil
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
        let wasCapturing = machine.expectsKeyDown
        recoverMissedRelease()
        Logger(subsystem: "com.hunterbohm.dictation", category: "keys")
            .info("key tap was switched off by the system and is back on; capturing \(wasCapturing) -> \(self.machine.expectsKeyDown)")
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
        let shortcut = active ?? keys.all[0]
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
    nonisolated(unsafe) let event = event
    let swallow = MainActor.assumeIsolated {
        keyTap.handle(kind: kind, keyCode: keyCode, flags: flags, marker: marker, isRepeat: isRepeat,
                      characters: { NSEvent(cgEvent: event)?.charactersIgnoringModifiers })
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
