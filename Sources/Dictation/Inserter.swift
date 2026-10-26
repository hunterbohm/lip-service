import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DictationCore

/// Where the user was at release, meaning the frontmost app and, when Accessibility exposes it, the focused
/// element.
struct FocusTarget {
    var pid: pid_t?
    var element: AXUIElement?
    var app: HistoryApp?

    @MainActor static func current() -> FocusTarget {
        guard let front = NSWorkspace.shared.frontmostApplication else { return FocusTarget() }
        let pid = front.processIdentifier
        let app = HistoryApp(name: front.localizedName ?? front.bundleIdentifier ?? "Unknown", bundleID: front.bundleIdentifier)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return FocusTarget(pid: pid, app: app) }
        return FocusTarget(pid: pid, element: (value as! AXUIElement), app: app)
    }

    private static let contextLength = 200

    /// "" at the start of the field, nil when the element exposes no selection or text.
    @MainActor func textBeforeCursor() -> String? {
        guard let element else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        if selection.location == 0 { return "" }
        let length = min(selection.location, Self.contextLength)
        var preceding = CFRange(location: selection.location - length, length: length)
        var text: CFTypeRef?
        if let range = AXValueCreate(.cfRange, &preceding),
           AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, range, &text) == .success,
           let string = text as? String, !string.isEmpty {
            return string
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String, selection.location <= string.utf16.count
        else { return nil }
        let end = string.utf16.index(string.utf16.startIndex, offsetBy: selection.location)
        return String(decoding: string.utf16[string.utf16.index(end, offsetBy: -length)..<end], as: UTF16.self)
    }

    /// Electron apps often expose no focused element, so the app alone decides then.
    func matches(_ other: FocusTarget) -> Bool {
        guard pid == other.pid else { return false }
        guard let element, let otherElement = other.element else { return true }
        return CFEqual(element, otherElement)
    }
}

/// The single owner of getting text into another app, and the only code that writes the pasteboard.
@MainActor final class Inserter {
    private let preferences: Preferences
    private let pasteboard = SystemPasteboard()
    private var transaction = ClipboardTransaction()
    /// Time the target app gets to read the pasteboard before the user's clipboard comes back. A busy Electron
    /// app that reads after the restore pastes the old clipboard, so this errs long. A copy inside it still wins.
    private let settle: Duration = .seconds(1)

    init(preferences: Preferences) {
        self.preferences = preferences
        // A hung target app would otherwise block the focus check on main for the default 6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.exposeAccessibility(pid: pid) }
        }
    }

    func insert(_ text: String, target: FocusTarget, releasedAt: Instant) async -> InsertOutcome {
        exposeAccessibility(pid: target.pid)
        let focus = FocusTarget.current()
        let conditions = InsertConditions(trusted: AXIsProcessTrusted(), secureInput: IsSecureEventInputEnabled(),
                                          sameFocus: target.matches(focus), waited: Instant.now - releasedAt)
        switch InsertDecision.decide(conditions) {
        case .copyOnly(let reason):
            transaction.copy(text, on: pasteboard)
            return .copied(reason)
        case .paste:
            let configuration = preferences.current
            let fitted = configuration.settings.smartSpacing
                ? SmartSpacing.adjust(text, after: focus.textBeforeCursor(),
                                      properNouns: configuration.vocabulary.terms.map(\.text) + Cleanup.calendarNames)
                : text
            guard let ticket = transaction.paste(fitted, on: pasteboard, post: Self.postCommandV) else {
                return .copied(.keystrokeFailed)
            }
            try? await Task.sleep(for: settle)
            transaction.restore(ticket, on: pasteboard)
            return .pasted
        }
    }

    /// Copy-only, for the menu's recent dictations.
    func copy(_ text: String) { transaction.copy(text, on: pasteboard) }

    /// Electron and other Chromium apps build their accessibility tree only when asked, so this runs at each app
    /// activation, ahead of the first dictation there. Other apps ignore the attribute.
    private func exposeAccessibility(pid: pid_t?) {
        guard preferences.current.settings.smartSpacing, let pid else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// A private event source and flags of exactly Command, so a held fn or Option never reaches the target.
    /// The marker lets our own key tap skip these events.
    nonisolated private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: KeyTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// NSPasteboard.general behind the DictationCore seam.
final class SystemPasteboard: DictationCore.Pasteboard {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    func write(_ text: String, transient: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if transient { pasteboard.setData(Data(), forType: Self.transientType) }
    }
}
