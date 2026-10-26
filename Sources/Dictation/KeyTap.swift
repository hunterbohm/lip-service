import ApplicationServices
import CoreGraphics
import DictationCore
import Foundation

/// The single owner of keyboard input and the hotkey phase, through a session CGEventTap on the main run loop.
/// The tap is active, not listen-only, because that needs Accessibility (which paste needs anyway) instead of
/// adding Input Monitoring. Every event passes through except the Escape that cancels hands-free and the
/// Control+Command+V that pastes the last transcript.
@MainActor final class KeyTap {
    /// Marks our own Cmd+V, so a paste landing during the next hold is not taken for a chord.
    nonisolated static let syntheticMarker: Int64 = 0x4449_4354

    private(set) var machine: HotkeyMachine = .idle
    /// After every input that changed the phase, with the sound for that step, and when the tap starts running.
    /// Runs on a later main-queue turn, never inside the tap callback, as does `onPasteLast`.
    var onUpdate: (([CaptureCommand], Cue?) -> Void)?
    var onPasteLast: (() -> Void)?
    var hotkeys: [HotkeyChoice] {
        didSet {
            guard hotkeys != oldValue else { return }
            machine = .idle
            active = nil
            scheduleDeadline()
        }
    }
    var isRunning: Bool { tap != nil }

    private let timing = HotkeyTiming()
    private var tap: CFMachPort?
    private var deadlineTimer: Timer?
    private var trustTimer: Timer?
    /// The hotkey whose press began the current capture. While a key is down only that key moves the machine,
    /// so another chosen hotkey pressed meanwhile counts as a chord.
    private var active: HotkeyChoice?

    init(hotkeys: [HotkeyChoice]) { self.hotkeys = hotkeys }

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

    private func retryTap() {
        guard createTap() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        onUpdate?([], nil)
    }

    private func createTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// A keyDown or flagsChanged. Returns whether to swallow it. Paste Last Transcript still reaches the machine
    /// as a key, so it cancels a hold the way any chord does.
    fileprivate func handle(type: CGEventType, keyCode: Int, flags: UInt64, marker: Int64, isRepeat: Bool) -> Bool {
        guard marker != Self.syntheticMarker else { return false }
        let kind: KeyInput.EventKind = type == .keyDown ? .keyDown : .flagsChanged
        let candidates = machine.expectsKeyDown ? [active ?? hotkeys[0]] : hotkeys
        let input = KeyInput.classify(kind: kind, keyCode: keyCode, flags: flags, hotkeys: candidates, at: .now)
        if case .hotkeyDown = input { active = candidates.first { $0.keyCode == keyCode } }
        let swallow = feed(input)
        guard kind == .keyDown, KeyInput.isPasteLastTranscript(keyCode: keyCode, flags: flags) else { return swallow }
        if !isRepeat {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onPasteLast?() }
            }
        }
        return true
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
        let hotkey = active ?? hotkeys[0]
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let current = KeyInput.classify(kind: .flagsChanged, keyCode: hotkey.keyCode, flags: flags, hotkeys: [hotkey], at: .now)
        let flagsSayDown = if case .hotkeyDown = current { true } else { false }
        let keySaysDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hotkey.keyCode))
        if !flagsSayDown, !keySaysDown { _ = feed(.hotkeyUp(.now)) }
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
    guard type == .keyDown || type == .flagsChanged else {
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
        keyTap.handle(type: type, keyCode: keyCode, flags: flags, marker: marker, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
