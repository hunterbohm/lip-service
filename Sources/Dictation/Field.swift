import ApplicationServices
import DictationCore

/// A text element in another app, read through Accessibility. Reads block on the other app, so they run off the main
/// thread. Every call has a timeout that ends by the caller's deadline, so a hung app cannot hold a read past it.
struct Field: @unchecked Sendable {
    let element: AXUIElement

    /// A longer value is not read: a big document would cost more to copy than the read is worth.
    static let longest = 20_000
    /// How long one read may take when the caller has no deadline of its own.
    static let readLimit = 0.5

    struct Contents: Equatable, Sendable {
        var value: String
        /// The insertion point, in UTF-16 units, as Accessibility counts.
        var cursor: Int

        /// Whether `text` ends right at the cursor.
        func endsAtCursor(with text: String) -> Bool {
            let units = Array(value.utf16), inserted = Array(text.utf16)
            guard cursor <= units.count, cursor >= inserted.count else { return false }
            return Array(units[(cursor - inserted.count)..<cursor]) == inserted
        }
    }

    init(_ element: AXUIElement) { self.element = element }

    /// The attribute, or nil when it is missing, fails, or `deadline` has passed.
    func copy(_ attribute: String, until deadline: Instant) -> CFTypeRef? {
        let remaining = deadline - .now
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    /// Nil when the element shows no value or selection, holds more than `longest` characters, or does not answer
    /// by `deadline`. The length is read first, so a long value is never copied.
    func read(until deadline: Instant) -> Contents? {
        guard let count = copy(kAXNumberOfCharactersAttribute, until: deadline) as? Int, count <= Self.longest,
              let rangeValue = copy(kAXSelectedTextRangeAttribute, until: deadline), CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              let string = copy(kAXValueAttribute, until: deadline) as? String, string.utf16.count <= Self.longest
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        return Contents(value: string, cursor: selection.location)
    }

    func contents(until deadline: Instant = .now + readLimit) async -> Contents? {
        let field = self
        return await Task.detached { field.read(until: deadline) }.value
    }

    /// Polls until `text` ends at the cursor, which means the paste landed, until `deadline`. The contents then. Nil at
    /// once for a field that cannot be read at all, so a caller does not wait out the deadline on it.
    func waitForText(_ text: String, until deadline: Instant) async -> Contents? {
        while Instant.now < deadline {
            guard let contents = await contents(until: deadline) else { return nil }
            if contents.endsAtCursor(with: text) { return contents }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    /// Whether the element takes typed text: a text role, or editable content in a web page, which marks itself with
    /// an editable ancestor.
    func takesText(until deadline: Instant) -> Bool {
        if let role = copy(kAXRoleAttribute, until: deadline) as? String, PressReturn.textRoles.contains(role) { return true }
        return copy("AXEditableAncestor", until: deadline) != nil
    }
}
