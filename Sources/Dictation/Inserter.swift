import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DictationCore
import os

/// Where the user was at release, meaning the frontmost app and, when Accessibility exposes it, the focused
/// element.
struct FocusTarget {
    var pid: pid_t?
    var element: AXUIElement?
    var app: HistoryApp?
    /// Inserter's count of app activations when this was read, so a later check can tell another app came forward.
    var activations = 0

    /// `timeout` bounds the wait on the front app, which answers on its own main thread.
    @MainActor static func current(timeout: Double = 0.25) -> FocusTarget {
        guard let front = NSWorkspace.shared.frontmostApplication else { return FocusTarget() }
        let pid = front.processIdentifier
        let app = HistoryApp(name: front.localizedName ?? front.bundleIdentifier ?? "Unknown", bundleID: front.bundleIdentifier)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Float(max(0.001, timeout)))
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return FocusTarget(pid: pid, app: app) }
        return FocusTarget(pid: pid, element: (value as! AXUIElement), app: app)
    }

    /// Whether Lip Service may read this app's fields at all.
    var isReadable: Bool { !PrivateApps.contains(app?.bundleID) }

    private static let contextLength = 200

    /// "" at the start of the field, nil when the element exposes no selection or text, or is in a PrivateApps app.
    @MainActor func textBeforeCursor() -> String? {
        guard let element, isReadable else { return nil }
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
        var count: CFTypeRef?, value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let count = count as? Int, count <= Field.longest,
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
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

    /// For Press Return, stricter than `matches`: a field known at release that can no longer be read is not the same
    /// focus, since Return could land in something that just opened, such as a dialog. The paste keeps `matches`,
    /// because a field read can miss for a moment and that should not turn a dictation into a copy.
    func stillHas(_ other: FocusTarget) -> Bool {
        if element != nil, other.element == nil { return false }
        return matches(other)
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
    /// App activations since launch. Press Return compares it with the count at release.
    private var activations = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        // A hung target app would otherwise block the focus check on main for the default 6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.activations += 1
                self?.exposeAccessibility(pid: pid)
            }
        }
    }

    /// Where the user is now, with the activation count Press Return checks.
    func releaseTarget() -> FocusTarget {
        var target = FocusTarget.current()
        target.activations = activations
        return target
    }

    /// A dictation that landed in a field that shows its text, kept to learn from the user's fix.
    struct Pasted {
        let field: Field
        let span: PastedSpan
    }

    /// `pasted` is set only for a dictation that Learn from your fixes may watch: pasted, seen in its field, and not
    /// sent with Return.
    /// `onPaste` gets the moment the paste keystroke went out, before the clipboard settle, for timing.
    func insert(_ insertion: Insertion, target: FocusTarget, releasedAt: Instant,
                onPaste: (Instant) -> Void = { _ in }) async -> (outcome: InsertOutcome, pasted: Pasted?) {
        exposeAccessibility(pid: target.pid)
        let focus = FocusTarget.current()
        let conditions = InsertConditions(trusted: AXIsProcessTrusted(), secureInput: IsSecureEventInputEnabled(),
                                          sameFocus: target.matches(focus), waited: Instant.now - releasedAt)
        switch InsertDecision.decide(conditions) {
        case .copyOnly(let reason):
            transaction.copy(insertion.text, on: pasteboard)
            return (.copied(reason), nil)
        case .paste:
            let configuration = preferences.current
            let fitted = configuration.settings.smartSpacing && insertion.source != .snippet && insertion.source != .agentDraft
                ? SmartSpacing.adjust(insertion.text, after: focus.textBeforeCursor(),
                                      properNouns: configuration.vocabulary.terms.map(\.text) + Cleanup.calendarNames)
                : insertion.text
            let pasted = Instant.now
            guard let ticket = transaction.paste(fitted, on: pasteboard, post: { Self.post(kVK_ANSI_V, flags: .maskCommand) }) else {
                return (.copied(.keystrokeFailed), nil)
            }
            onPaste(Instant.now)
            let field = focus.isReadable ? focus.element.map(Field.init) : nil
            let learns = insertion.source == .dictation && !insertion.pressReturn && configuration.settings.learnFixes
            var landed: Field.Contents?
            if insertion.pressReturn {
                landed = await field?.waitForText(fitted, until: pasted + (PressReturn.deadline - Self.returnCheckTime))
                if landed == nil { try? await Task.sleep(for: .seconds(max(0, Self.unseenPaste - (Instant.now - pasted)))) }
                // Return goes where the paste went: a field read only at paste time becomes the one Return checks.
                var pasteTarget = target
                if target.element == nil, let element = focus.element { pasteTarget.element = element }
                if PressReturn.allows(returnCheck(pasteTarget, pasteSeen: landed != nil, pastedAt: pasted)) {
                    _ = Self.post(kVK_Return, flags: [])
                } else {
                    Self.log.info("Press Return skipped")
                }
            } else if learns {
                landed = await field?.waitForText(fitted, until: pasted + Self.landingWait)
            }
            try? await Task.sleep(for: settle - .seconds(Instant.now - pasted))
            transaction.restore(ticket, on: pasteboard)
            guard learns, let field, let landed else { return (.pasted, nil) }
            return (.pasted, Pasted(field: field, span: PastedSpan(value: landed.value, location: landed.cursor - fitted.utf16.count,
                                                                    inserted: fitted)))
        }
    }

    /// When the field cannot be read, Return waits this long after the paste keystroke.
    private static let unseenPaste = 0.2
    /// How long Learn from your fixes looks for the pasted text in its field.
    private static let landingWait = 0.4
    /// Kept from the Return deadline for the focus check just before Return.
    private static let returnCheckTime = 0.15
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "dictation")

    /// The focus just before Return, read within what is left of the deadline.
    private func returnCheck(_ target: FocusTarget, pasteSeen: Bool, pastedAt: Instant) -> PressReturn.Check {
        let deadline = pastedAt + PressReturn.deadline
        let focus = FocusTarget.current(timeout: min(Self.returnCheckTime / 2, deadline - .now))
        let takesText = pasteSeen || (focus.isReadable
            && focus.element.map { Field($0).takesText(until: min(deadline, .now + Self.returnCheckTime / 2)) } ?? false)
        return PressReturn.Check(sameFocus: target.stillHas(focus), exposesElement: focus.element != nil, pasteSeen: pasteSeen,
                                 takesText: takesText,
                                 appStayedInFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
                                     && activations == target.activations,
                                 sincePaste: Instant.now - pastedAt)
    }

    /// Copy-only, for the menu's recent dictations.
    func copy(_ text: String) { transaction.copy(text, on: pasteboard) }

    /// Electron and other Chromium apps build their accessibility tree only when asked, so this runs at each app
    /// activation, ahead of the first dictation there. Other apps ignore the attribute.
    private func exposeAccessibility(pid: pid_t?) {
        guard preferences.current.settings.smartSpacing, let pid else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// A private event source and exactly `flags`, so a held fn or Option never reaches the target. The marker lets
    /// our own key tap skip these events.
    nonisolated private static func post(_ key: Int, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let virtualKey = CGKeyCode(key)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = flags
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
