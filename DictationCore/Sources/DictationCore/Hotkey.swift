import Foundation

/// Seconds on the system uptime clock. Every timing decision in the app compares Instants read from `now`,
/// including key events, so key times, release times and deadlines share one clock.
public struct Instant: Comparable, Hashable, Sendable {
    public var seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public static var now: Instant { Instant(seconds: ProcessInfo.processInfo.systemUptime) }
    public static func < (a: Self, b: Self) -> Bool { a.seconds < b.seconds }
    public static func + (a: Self, d: Double) -> Self { Self(seconds: a.seconds + d) }
    public static func - (a: Self, b: Self) -> Double { a.seconds - b.seconds }
}

public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case fn, rightControl, rightOption, rightCommand

    public var keyCode: Int {
        switch self {
        case .fn: 63
        case .rightControl: 62
        case .rightOption: 61
        case .rightCommand: 54
        }
    }

    public var title: String {
        switch self {
        case .fn: "fn"
        case .rightControl: "Right Control"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        }
    }

    /// The flag bit that is set while this key is down. The right-side keys use their device-dependent
    /// right-side bits, so a held left-side twin cannot hide the release.
    var downMask: UInt64 {
        switch self {
        case .fn: 0x0080_0000  // maskSecondaryFn
        case .rightControl: 0x0000_2000  // NX_DEVICERCTLKEYMASK
        case .rightOption: 0x0000_0040  // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x0000_0010  // NX_DEVICERCMDKEYMASK
        }
    }
}

public enum KeyInput: Equatable, Sendable {
    case hotkeyDown(Instant), hotkeyUp(Instant)
    /// A keyDown of any key, or another modifier changing.
    case otherKey(Instant, isEscape: Bool)
    /// The bar's buttons, which it shows only hands-free.
    case stopClicked(Instant), cancelClicked(Instant)
    /// The shell's timer reached `HotkeyMachine.deadline`.
    case tick(Instant)

    public enum EventKind: Sendable { case keyDown, flagsChanged }

    public static let escapeKeyCode = 53

    /// Control+Command+V with no Shift or Option, Willow's Paste Previous Transcript.
    public static func isPasteLastTranscript(keyCode: Int, flags: UInt64) -> Bool {
        let shift: UInt64 = 0x2_0000, control: UInt64 = 0x4_0000, option: UInt64 = 0x8_0000, command: UInt64 = 0x10_0000
        return keyCode == 9 && flags & (shift | control | option | command) == control | command
    }

    /// Only a flagsChanged with one of the hotkeys' own keycodes moves the hotkey. Arrow keyDowns carry
    /// maskSecondaryFn without fn held, so the flag alone is not enough.
    public static func classify(kind: EventKind, keyCode: Int, flags: UInt64, hotkeys: [HotkeyChoice],
                                at time: Instant) -> KeyInput {
        if kind == .flagsChanged, let hotkey = hotkeys.first(where: { $0.keyCode == keyCode }) {
            return flags & hotkey.downMask != 0 ? .hotkeyDown(time) : .hotkeyUp(time)
        }
        return .otherKey(time, isEscape: kind == .keyDown && keyCode == escapeKeyCode)
    }
}

public struct HotkeyTiming: Equatable, Sendable {
    public var minHold = 0.30  // shorter presses are taps; also FluidAudio's 0.3 s minimum
    public var doubleTapWindow = 0.35  // release-to-press gap that still makes a double-tap
    public var barDelay = 0.12  // fn+Delete and fn+arrow chords end sooner, so the bar never flashes
    public var maxCapture = 600.0  // a forgotten hands-free session, or a lost key-up, finishes itself
    public init() {}
}

/// What the shell does to the microphone. The bar is not a command. It is derived from the phase.
public enum CaptureCommand: Equatable, Sendable { case start, cancel, finish }

/// The sound for one step of the machine. Only a bar the user saw makes a sound, so a fn chord that ends before
/// `barDelay` stays silent.
public enum Cue: Equatable, Sendable {
    case start, stop, cancel

    public static func after(_ commands: [CaptureCommand], wasListening: Bool, isListening: Bool) -> Cue? {
        if commands.contains(.finish), wasListening { return .stop }
        if commands.contains(.cancel), wasListening { return .cancel }
        if isListening, !wasListening { return .start }
        return nil
    }
}

public struct HotkeyStep: Equatable, Sendable {
    public var commands: [CaptureCommand]
    /// Only the Escape that cancels hands-free. Every other event reaches the focused app.
    public var consumeEvent: Bool

    public init(_ commands: [CaptureCommand] = [], consumeEvent: Bool = false) {
        self.commands = commands
        self.consumeEvent = consumeEvent
    }
}

/// The hotkey phase. Capture runs from the first press until cancel or finish, so a double-tap keeps the audio
/// that began on the first tap. Timing decisions compare the event times carried by the inputs, so a late
/// tick never changes the outcome, only when the microphone stops after an ignored tap.
///
///     phase                  input                              next                       commands
///     idle                   down                               pressed(t, shown: false)   start
///     pressed                tick >= since + maxCapture         awaitingRelease            finish
///     pressed                tick >= since + barDelay           pressed(shown: true)
///     pressed                up, held >= minHold                idle                       finish
///     pressed                up, held <  minHold                tapped                     (capture runs on)
///     pressed, pressedAgain  other key                          awaitingRelease            cancel
///     pressed, pressedAgain  down (the release was lost)        pressed(t, shown: false)   cancel, start
///     tapped                 down, gap <= doubleTapWindow       pressedAgain
///     tapped                 down, gap >  doubleTapWindow       pressed(t, shown: false)   cancel, start
///     tapped                 other key, or tick >= window end   idle                       cancel
///     pressedAgain           up, held <  minHold                handsFree
///     pressedAgain           up, held >= minHold                idle                       finish (tap, then hold)
///     pressedAgain           tick >= start + maxCapture         awaitingRelease            finish
///     handsFree              down                               awaitingRelease            finish
///     handsFree              stop clicked                       idle                       finish
///     handsFree              cancel clicked                     idle                       cancel
///     handsFree              Escape                             idle                       cancel, consume
///     handsFree              tick >= start + maxCapture         idle                       finish
///     awaitingRelease        up                                 idle
///     awaitingRelease        down (the release was lost)        pressed(t, shown: false)   start
///
/// Anything else leaves the phase unchanged and returns no commands.
public enum HotkeyMachine: Equatable, Sendable {
    case idle
    case pressed(since: Instant, shown: Bool)
    case tapped(captureStart: Instant, releasedAt: Instant, shown: Bool)
    case pressedAgain(captureStart: Instant, since: Instant)
    case handsFree(captureStart: Instant)
    case awaitingRelease

    public mutating func handle(_ input: KeyInput, timing: HotkeyTiming) -> HotkeyStep {
        switch (self, input) {
        case (.idle, .hotkeyDown(let t)), (.awaitingRelease, .hotkeyDown(let t)):
            self = .pressed(since: t, shown: false)
            return HotkeyStep([.start])

        case (.pressed(let since, _), .tick(let t)) where t >= since + timing.maxCapture:
            self = .awaitingRelease
            return HotkeyStep([.finish])
        case (.pressed(let since, false), .tick(let t)) where t >= since + timing.barDelay:
            self = .pressed(since: since, shown: true)
            return HotkeyStep()
        case (.pressed(let since, _), .hotkeyUp(let t)) where t - since >= timing.minHold:
            self = .idle
            return HotkeyStep([.finish])
        case (.pressed(let since, let shown), .hotkeyUp(let t)):
            self = .tapped(captureStart: since, releasedAt: t, shown: shown)
            return HotkeyStep()
        case (.pressed, .otherKey), (.pressedAgain, .otherKey):
            self = .awaitingRelease
            return HotkeyStep([.cancel])
        case (.pressed, .hotkeyDown(let t)), (.pressedAgain, .hotkeyDown(let t)):
            self = .pressed(since: t, shown: false)
            return HotkeyStep([.cancel, .start])

        case (.tapped(let start, let releasedAt, _), .hotkeyDown(let t)):
            if t - releasedAt <= timing.doubleTapWindow {
                self = .pressedAgain(captureStart: start, since: t)
                return HotkeyStep()
            }
            self = .pressed(since: t, shown: false)
            return HotkeyStep([.cancel, .start])
        case (.tapped, .otherKey):
            self = .idle
            return HotkeyStep([.cancel])
        case (.tapped(_, let releasedAt, _), .tick(let t)) where t >= releasedAt + timing.doubleTapWindow:
            self = .idle
            return HotkeyStep([.cancel])

        case (.pressedAgain(let start, let since), .hotkeyUp(let t)):
            if t - since < timing.minHold {
                self = .handsFree(captureStart: start)
                return HotkeyStep()
            }
            self = .idle
            return HotkeyStep([.finish])
        case (.pressedAgain(let start, _), .tick(let t)) where t >= start + timing.maxCapture:
            self = .awaitingRelease
            return HotkeyStep([.finish])

        case (.handsFree, .hotkeyDown):
            self = .awaitingRelease
            return HotkeyStep([.finish])
        case (.handsFree, .stopClicked):
            self = .idle
            return HotkeyStep([.finish])
        case (.handsFree, .cancelClicked):
            self = .idle
            return HotkeyStep([.cancel])
        case (.handsFree, .otherKey(_, isEscape: true)):
            self = .idle
            return HotkeyStep([.cancel], consumeEvent: true)
        case (.handsFree(let start), .tick(let t)) where t >= start + timing.maxCapture:
            self = .idle
            return HotkeyStep([.finish])

        case (.awaitingRelease, .hotkeyUp):
            self = .idle
            return HotkeyStep()

        default:
            return HotkeyStep()
        }
    }

    /// Capture failed to start. Wait out the physical release if the key is down, else go idle.
    public mutating func abort() {
        switch self {
        case .pressed, .pressedAgain, .awaitingRelease: self = .awaitingRelease
        case .idle, .tapped, .handsFree: self = .idle
        }
    }

    /// The next tick the shell must deliver, nil when no timeout is pending.
    public func deadline(_ timing: HotkeyTiming) -> Instant? {
        switch self {
        case .pressed(let since, false): since + timing.barDelay
        case .pressed(let since, true): since + timing.maxCapture
        case .tapped(_, let releasedAt, _): releasedAt + timing.doubleTapWindow
        case .pressedAgain(let start, _), .handsFree(let start): start + timing.maxCapture
        case .idle, .awaitingRelease: nil
        }
    }

    /// Whether the key is physically down as far as the machine knows, for recovering a release that the
    /// event tap missed while it was disabled.
    public var expectsKeyDown: Bool {
        switch self {
        case .pressed, .pressedAgain, .awaitingRelease: true
        case .idle, .tapped, .handsFree: false
        }
    }

    /// The bar reads this, never a copy of it.
    public var showsListening: Bool {
        switch self {
        case .pressed(_, let shown), .tapped(_, _, let shown): shown
        case .pressedAgain, .handsFree: true
        case .idle, .awaitingRelease: false
        }
    }

    public var isHandsFree: Bool { if case .handsFree = self { true } else { false } }
}

extension HotkeyChoice {
    /// The keys as a person would say them: "fn", "fn or Right Control", "fn, Right Control or Right Option".
    public static func phrase(_ keys: [HotkeyChoice]) -> String {
        guard let last = keys.last else { return "" }
        let rest = keys.dropLast().map(\.title)
        return rest.isEmpty ? last.title : rest.joined(separator: ", ") + " or " + last.title
    }
}

/// A microphone level as a 0 to 1 loudness, on a decibel scale from quiet room to loud speech.
public enum Loudness {
    public static func fraction(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-5))
        return min(max((decibels + 52) / 36, 0), 1)
    }
}
