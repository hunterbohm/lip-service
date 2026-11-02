import ApplicationServices
import DictationCore
import Foundation

/// Reads the text of the front window through Accessibility, for names from the screen: the window's title, the
/// focused field around the cursor, and the static text and text fields on screen. It walks the window's tree only so
/// far and stops at its time budget. Password fields and PrivateApps are never read. Nothing is kept or sent.
enum ScreenReader {
    static let budget = 0.05
    static let maxDepth = 40
    static let maxNodes = 600
    /// Ghostwrite reads more of the window: it waits on the agent anyway, and the text is the reply's context.
    static let agentBudget = 0.15
    static let agentNodes = 1_500
    /// Characters kept from one element, and from the focused field on each side of the cursor.
    static let maxText = 600
    static let fieldBefore = 2_000
    static let fieldAfter = 400
    /// A focused field longer than this is not read. Its length is read first, so it is never copied.
    static let longestField = 200_000

    private static let secure = kAXSecureTextFieldSubrole as String
    private static let readRoles: Set<String> = [kAXStaticTextRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String]

    /// Blocks on the other app, so callers run it off the main thread.
    static func read(pid: pid_t, budget: Double = budget, maxNodes: Int = maxNodes) -> [ScreenText] {
        let deadline = Date().addingTimeInterval(budget)
        func remaining() -> Float { Float(max(0.001, deadline.timeIntervalSinceNow)) }
        func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, remaining())
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }

        let app = AXUIElementCreateApplication(pid)
        var texts: [ScreenText] = []
        var focusCenter: CGPoint?
        if let focused = copy(app, kAXFocusedUIElementAttribute).flatMap(element) {
            let role = copy(focused, kAXRoleAttribute) as? String, subrole = copy(focused, kAXSubroleAttribute) as? String
            if role != secure, subrole != secure {
                focusCenter = frame(position: copy(focused, kAXPositionAttribute), size: copy(focused, kAXSizeAttribute))
                    .map { CGPoint(x: $0.midX, y: $0.midY) }
                if let count = copy(focused, kAXNumberOfCharactersAttribute) as? Int, count <= longestField,
                   let value = copy(focused, kAXValueAttribute) as? String, !value.isEmpty, value.utf16.count <= longestField {
                    texts.append(around(value, cursor: cursor(copy(focused, kAXSelectedTextRangeAttribute), in: value)))
                }
            }
        }
        guard let window = copy(app, kAXFocusedWindowAttribute).flatMap(element) else { return texts }
        if let title = copy(window, kAXTitleAttribute) as? String, !title.isEmpty {
            texts.append(ScreenText(text: String(title.prefix(maxText)), distance: 1))
        }
        let windowFrame = frame(position: copy(window, kAXPositionAttribute), size: copy(window, kAXSizeAttribute))
        let center = focusCenter ?? windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero

        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute, kAXPositionAttribute,
                          kAXSizeAttribute] as CFArray
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes, Date() < deadline {
            let (node, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, remaining())
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, [], &values) == .success,
                  let values = values as? [AnyObject], values.count == 6
            else { continue }
            func present(_ index: Int) -> CFTypeRef? {
                let value = values[index]
                return CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError ? nil : value
            }
            let role = present(0) as? String, subrole = present(1) as? String
            if role == secure || subrole == secure { continue }
            let box = frame(position: present(4), size: present(5))
            if let box, let windowFrame, !box.intersects(windowFrame) { continue }
            if let role, readRoles.contains(role), let value = present(2) as? String, !value.isEmpty {
                let distance = box.map { hypot($0.midX - center.x, $0.midY - center.y) } ?? 10_000
                texts.append(ScreenText(text: String(value.prefix(maxText)), distance: Double(max(2, distance))))
            }
            if depth < maxDepth, queue.count < maxNodes, let children = present(3) as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return texts
    }

    /// The focused field's selected text, unless it is a password field.
    static func selectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value,
              let focused = element(value) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.05)
        var role: CFTypeRef?, subrole: CFTypeRef?, selected: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        guard role as? String != secure, subrole as? String != secure,
              AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return String(text.prefix(fieldBefore))
    }

    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    private static func cursor(_ range: CFTypeRef?, in value: String) -> Int {
        var selection = CFRange()
        guard let range, CFGetTypeID(range) == AXValueGetTypeID(), AXValueGetValue(range as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.location <= value.utf16.count
        else { return value.count }
        let index = String.Index(utf16Offset: selection.location, in: value)
        return value.distance(from: value.startIndex, to: index)
    }

    /// The focused field's text near the cursor, with the cursor's place in it.
    private static func around(_ value: String, cursor: Int) -> ScreenText {
        let start = max(0, cursor - fieldBefore), end = min(value.count, cursor + fieldAfter)
        let lower = value.index(value.startIndex, offsetBy: start), upper = value.index(value.startIndex, offsetBy: end)
        return ScreenText(text: String(value[lower..<upper]), distance: 0, cursor: cursor - start)
    }

    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: point, size: extent)
    }
}
