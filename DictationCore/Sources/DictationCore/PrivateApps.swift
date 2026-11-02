/// Apps whose text Lip Service never reads through Accessibility: password managers and System Settings. Names from
/// the screen, smart spacing, Press Return and Learn from your fixes all check it before reading a field.
public enum PrivateApps {
    /// Bundle IDs. A trailing `*` matches every ID starting with the rest, which covers an app's other editions.
    public static let bundleIDs = [
        "com.1password.*", "com.agilebits.*", "com.bitwarden.*", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.systempreferences", "com.apple.settings.*", "com.dashlane.*", "com.lastpass.*",
        "me.proton.pass*", "org.keepassxc.*", "com.nordsec.nordpass*", "in.sinew.enpass*", "com.keepersecurity.*",
        "com.callpod.keepermac*", "com.markmcguill.strongbox*",
    ]

    /// True for an app with no bundle ID too, since nothing says it is safe to read.
    public static func contains(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return true }
        return bundleIDs.contains { entry in
            let entry = entry.lowercased()
            return entry.hasSuffix("*") ? id.hasPrefix(entry.dropLast()) : id == entry
        }
    }
}
