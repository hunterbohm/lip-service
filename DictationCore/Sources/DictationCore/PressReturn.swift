/// Whether Press Return may send a dictation that was just pasted. Return goes only into the element the text was
/// pasted into, only when that element takes text, and never late, since a late Return lands wherever focus went.
public enum PressReturn {
    /// Paste to Return. Past it, Return is skipped.
    public static let deadline = 0.6

    /// Roles of elements that take typed text. A web page's editable content can carry another role and is told apart
    /// by its editable ancestor instead.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    public struct Check: Equatable, Sendable {
        /// The focus read just before Return still matches the target at release.
        public var sameFocus: Bool
        /// The app exposes a focused element. Some terminals and Electron apps do not.
        public var exposesElement: Bool
        /// The pasted text was seen at the cursor.
        public var pasteSeen: Bool
        /// The focused element has a text role or sits in a web page's editable content.
        public var takesText: Bool
        /// The app from release is still in front and no other app came to the front since.
        public var appStayedInFront: Bool
        /// Seconds from the paste keystroke to now.
        public var sincePaste: Double

        public init(sameFocus: Bool, exposesElement: Bool, pasteSeen: Bool, takesText: Bool, appStayedInFront: Bool,
                    sincePaste: Double) {
            (self.sameFocus, self.exposesElement, self.pasteSeen) = (sameFocus, exposesElement, pasteSeen)
            (self.takesText, self.appStayedInFront, self.sincePaste) = (takesText, appStayedInFront, sincePaste)
        }
    }

    public static func allows(_ check: Check) -> Bool {
        guard check.sincePaste <= deadline, check.sameFocus else { return false }
        return check.exposesElement ? check.pasteSeen || check.takesText : check.appStayedInFront
    }
}
