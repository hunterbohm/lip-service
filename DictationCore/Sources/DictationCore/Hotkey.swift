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

/// Modifier families a shortcut can require, as the device-independent event flag bits. fn is not one: on a
/// laptop the function and arrow keys carry its flag without it being held, so fn works only as a key of its own.
public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue & Self.all }

    public static let shift = Modifiers(rawValue: 0x2_0000)
    public static let control = Modifiers(rawValue: 0x4_0000)
    public static let option = Modifiers(rawValue: 0x8_0000)
    public static let command = Modifiers(rawValue: 0x10_0000)
    private static let all: UInt64 = 0x1E_0000

    /// The families held in an event's flags.
    public init(flags: UInt64) { self.init(rawValue: flags) }

    /// In Apple's order: ⌃⌥⇧⌘.
    public var symbols: String {
        [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

/// One physical modifier key: its keycode, the device bit set only while that key is down, and its family.
struct ModifierKey {
    let code: Int
    let deviceMask: UInt64
    let family: Modifiers
    let name: String

    static let all = [
        ModifierKey(code: 63, deviceMask: 0x80_0000, family: [], name: "fn"),
        ModifierKey(code: 59, deviceMask: 0x0001, family: .control, name: "Left Control"),
        ModifierKey(code: 62, deviceMask: 0x2000, family: .control, name: "Right Control"),
        ModifierKey(code: 58, deviceMask: 0x0020, family: .option, name: "Left Option"),
        ModifierKey(code: 61, deviceMask: 0x0040, family: .option, name: "Right Option"),
        ModifierKey(code: 55, deviceMask: 0x0008, family: .command, name: "Left Command"),
        ModifierKey(code: 54, deviceMask: 0x0010, family: .command, name: "Right Command"),
        ModifierKey(code: 56, deviceMask: 0x0002, family: .shift, name: "Left Shift"),
        ModifierKey(code: 60, deviceMask: 0x0004, family: .shift, name: "Right Shift"),
    ]

    static func with(code: Int) -> ModifierKey? { all.first { $0.code == code } }
}

/// A key the user holds to dictate, or presses to paste the last dictation: any key, with the modifiers held for
/// it. A modifier key alone, such as fn or Right Option, is a shortcut as well, held and released like any key.
public struct Shortcut: Hashable, Codable, Sendable {
    public var key: Int
    public var modifiers: Modifiers

    public init(key: Int, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let fn = Shortcut(key: 63)
    public static let rightControl = Shortcut(key: 62)
    public static let pasteLast = Shortcut(key: 9, modifiers: [.control, .command])

    private var modifierKey: ModifierKey? { ModifierKey.with(code: key) }
    public var isModifierKey: Bool { modifierKey != nil }

    /// "fn", "Right Option", "⌘ Right Option", "⌃⌘V", "⌥Space", "F5".
    public var title: String {
        if let modifierKey { return modifiers.isEmpty ? modifierKey.name : modifiers.symbols + " " + modifierKey.name }
        return modifiers.symbols + KeyNames.name(key)
    }

    /// Whether its key going down with these flags is this shortcut. The other modifiers held must be exactly its
    /// own, so ⌥Space does not fire on ⌥⇧Space. A modifier key's own family is set by the key itself and ignored.
    public func matches(flags: UInt64) -> Bool {
        var held = Modifiers(flags: flags)
        if let family = modifierKey?.family { held.subtract(family) }
        return held == modifiers
    }

    /// For a modifier key, whether these flags say it is down. Nil for other keys, which report their own key ups.
    public func isDown(flags: UInt64) -> Bool? { modifierKey.map { flags & $0.deviceMask != 0 } }

    /// Why this cannot be a shortcut, or nil when it can.
    public var problem: String? {
        if key == KeyNames.capsLock { return "Caps Lock can't be a shortcut." }
        if isModifierKey || KeyNames.functionKeys.contains(key) { return nil }
        if key == KeyInput.escapeKeyCode, modifiers.isEmpty { return "Escape stops recording, so it can't be a shortcut on its own." }
        if modifiers.isDisjoint(with: [.control, .option, .command]) { return "Add Control, Option or Command, so \(KeyNames.name(key)) still types." }
        return nil
    }

    /// The keys as a person would say them: "fn", "fn or Right Control", "fn, Right Control or ⌥Space".
    public static func phrase(_ shortcuts: [Shortcut]) -> String {
        guard let last = shortcuts.last else { return "" }
        let rest = shortcuts.dropLast().map(\.title)
        return rest.isEmpty ? last.title : rest.joined(separator: ", ") + " or " + last.title
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }
    private static let legacyNames = ["fn": 63, "rightControl": 62, "rightOption": 61, "rightCommand": 54]

    /// Also reads the names the first versions stored, such as "fn" and "rightControl".
    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let key = Self.legacyNames[name] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown key \(name)"))
            }
            self.init(key: key)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(Int.self, forKey: .key),
                  modifiers: try container.decodeIfPresent(Modifiers.self, forKey: .modifiers) ?? [])
    }
}

/// Names for keycodes, on a US layout.
enum KeyNames {
    static let capsLock = 57
    /// A quick fn release on a Mac with a Globe key also sends this key down and up. fn itself is code 63.
    static let globe = 179
    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static func name(_ key: Int) -> String { names[key] ?? "Key \(key)" }

    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape", 57: "Caps Lock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        117: "Forward Delete", 76: "Enter", 71: "Clear", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +",
        75: "Keypad /", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8",
        92: "Keypad 9",
    ]
}

/// Turns the keys pressed while recording into a shortcut. A key pressed with modifiers held records that
/// combination. A modifier pressed and let go with nothing else records that modifier key, with any modifiers held
/// under it. Escape on its own cancels.
public struct ShortcutRecorder: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case recorded(Shortcut)
        case cancelled
        case rejected(String)
    }

    private var candidate: Shortcut?

    public init() {}

    public mutating func handle(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64) -> Outcome? {
        switch kind {
        case .keyDown:
            let shortcut = Shortcut(key: keyCode, modifiers: Modifiers(flags: flags))
            if keyCode == KeyInput.escapeKeyCode, shortcut.modifiers.isEmpty { return .cancelled }
            return Self.outcome(shortcut)
        case .keyUp:
            return nil
        case .flagsChanged:
            if keyCode == KeyNames.capsLock { return .rejected("Caps Lock can't be a shortcut.") }
            guard let key = ModifierKey.with(code: keyCode) else { return nil }
            if flags & key.deviceMask != 0 {
                var others = Modifiers(flags: flags)
                others.subtract(key.family)
                candidate = Shortcut(key: keyCode, modifiers: others)
                return nil
            }
            guard let candidate, candidate.key == keyCode else { return nil }
            return Self.outcome(candidate)
        }
    }

    private static func outcome(_ shortcut: Shortcut) -> Outcome {
        shortcut.problem.map(Outcome.rejected) ?? .recorded(shortcut)
    }
}

public enum KeyInput: Equatable, Sendable {
    case hotkeyDown(Instant), hotkeyUp(Instant)
    /// A keyDown of another key, or another modifier pressed.
    case otherKey(Instant, isEscape: Bool)
    /// The bar's buttons, which it shows only hands-free.
    case stopClicked(Instant), cancelClicked(Instant)
    /// The shell's timer reached `HotkeyMachine.deadline`.
    case tick(Instant)

    public enum EventKind: Sendable { case keyDown, keyUp, flagsChanged }

    public static let escapeKeyCode = 53

    /// What a key event means for dictation, given the shortcuts that may move the machine now. Nil for events
    /// that do not concern it: an autorepeat of a shortcut's key, another key let go, or a modifier released.
    /// Only a shortcut's own keycode moves it, since arrow keyDowns carry fn's flag without fn held.
    public static func classify(kind: EventKind, keyCode: Int, flags: UInt64, isRepeat: Bool, shortcuts: [Shortcut],
                                at time: Instant) -> KeyInput? {
        let own = shortcuts.filter { $0.key == keyCode }
        switch kind {
        case .flagsChanged:
            guard let modifier = ModifierKey.with(code: keyCode) else { return nil }
            let down = flags & modifier.deviceMask != 0
            if !own.isEmpty {
                if !down { return .hotkeyUp(time) }
                return own.contains { $0.matches(flags: flags) } ? .hotkeyDown(time) : .otherKey(time, isEscape: false)
            }
            return down ? .otherKey(time, isEscape: false) : nil
        case .keyDown:
            if own.contains(where: { $0.matches(flags: flags) }) { return isRepeat ? nil : .hotkeyDown(time) }
            if keyCode == KeyNames.globe { return nil }
            return .otherKey(time, isEscape: keyCode == escapeKeyCode)
        case .keyUp:
            return own.isEmpty ? nil : .hotkeyUp(time)
        }
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

/// A microphone level as a 0 to 1 loudness, on a decibel scale from quiet room to loud speech.
public enum Loudness {
    public static func fraction(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-5))
        return min(max((decibels + 52) / 36, 0), 1)
    }
}
