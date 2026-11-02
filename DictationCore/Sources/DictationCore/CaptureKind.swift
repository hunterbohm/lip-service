import Foundation

/// What a held key captures speech for: text typed at the cursor, a draft the agent writes, or a task handed to the
/// agent's own app.
public enum CaptureKind: String, Codable, Sendable, CaseIterable {
    case dictate, ghostwrite, handOff
}

/// Every key that starts a capture, with the kind each starts. The dictation keys come first, so the hotkey
/// machine's fallback key is still the first dictation key.
public struct CaptureKeys: Equatable, Sendable {
    public var dictation: [Shortcut]
    public var ghostwrite: Shortcut?
    public var handOff: Shortcut?

    public init(dictation: [Shortcut], ghostwrite: Shortcut?, handOff: Shortcut?) {
        (self.dictation, self.ghostwrite, self.handOff) = (dictation, ghostwrite, handOff)
    }

    public var all: [Shortcut] { dictation + [ghostwrite, handOff].compactMap { $0 } }

    public func kind(of shortcut: Shortcut) -> CaptureKind {
        if shortcut == ghostwrite { return .ghostwrite }
        if shortcut == handOff { return .handOff }
        return .dictate
    }

    public func shortcut(for kind: CaptureKind, key: Int) -> Shortcut? {
        switch kind {
        case .dictate: dictation.first { $0.key == key }
        case .ghostwrite: ghostwrite.flatMap { $0.key == key ? $0 : nil }
        case .handOff: handOff.flatMap { $0.key == key ? $0 : nil }
        }
    }
}

/// Holding fn and then pressing Control or Option soon after turns the dictation into a Ghostwrite or a Hand off,
/// without restarting the microphone, so the words said since the fn press are kept. Pressed later, the modifier is a
/// chord and cancels, as it always has. Pressing the modifier first needs no rule: the shortcut itself matches.
public enum CaptureRouting: Equatable, Sendable {
    /// Feed this to the hotkey machine. A key-down names the shortcut that began the capture.
    case input(KeyInput, shortcut: Shortcut?)
    /// Keep the capture running and make it this shortcut's kind.
    case retarget(Shortcut)

    public static let window = 0.4

    /// One key event, given the phase and the shortcut whose press began the capture. Nil for events that do not
    /// concern capture.
    public static func route(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64, isRepeat: Bool, machine: HotkeyMachine,
                             active: Shortcut?, keys: CaptureKeys, at time: Instant) -> CaptureRouting? {
        if kind == .flagsChanged, case .pressed(let since, _) = machine, let active,
           let target = retarget(active: active, since: since, modifierCode: keyCode, flags: flags, at: time, keys: keys) {
            return .retarget(target)
        }
        let candidates = machine.expectsKeyDown ? [active ?? keys.all[0]] : keys.all
        guard let input = KeyInput.classify(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat, shortcuts: candidates, at: time)
        else { return nil }
        if case .hotkeyDown = input {
            return .input(input, shortcut: candidates.first { $0.key == keyCode && $0.matches(flags: flags) })
        }
        return .input(input, shortcut: nil)
    }

    /// Only a modifier key held on its own can be re-targeted, and only to a shortcut on that same key whose
    /// modifiers are exactly the ones held now.
    static func retarget(active: Shortcut, since: Instant, modifierCode: Int, flags: UInt64, at time: Instant,
                         keys: CaptureKeys) -> Shortcut? {
        guard active.isModifierKey, active.modifiers.isEmpty, time - since <= window,
              let pressed = ModifierKey.with(code: modifierCode), pressed.code != active.key, flags & pressed.deviceMask != 0,
              active.isDown(flags: flags) == true
        else { return nil }
        return [keys.ghostwrite, keys.handOff].compactMap { $0 }.first { $0.key == active.key && $0.matches(flags: flags) }
    }
}
