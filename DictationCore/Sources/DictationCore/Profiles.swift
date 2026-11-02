import Foundation
import Synchronization

/// How a dictation reads once it is cleaned up. Each style is a fixed text rule, never a rewrite.
public enum WritingStyle: String, CaseIterable, Codable, Sendable {
    /// The cleaned text as it is.
    case formal
    /// No period at the end.
    case casual
    /// No period at the end, and lowercase except dictionary words and "I".
    case veryCasual

    public var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        }
    }

    /// "i" alone, but not the one in "i.e.".
    private static let loneI = Pattern("\\bi\\b(?!\\.\\w)")
    /// A text ending in an abbreviation whose period is part of it: "U.S.", "e.g.", "i.e.", "etc.".
    private static let abbreviationAtEnd = Pattern("(?i)(?:(?<![\\w.])(?:[a-z]\\.){2,}|\\b(?:etc|inc|ltd|co|corp|jr|sr|vs)\\.)$")

    /// `terms` are the dictionary words. In Very casual a word spelled exactly as one of them keeps its capitals.
    public func apply(_ text: String, keeping terms: [String]) -> String {
        switch self {
        case .formal:
            return text
        case .casual:
            return Self.withoutFinalPeriod(text)
        case .veryCasual:
            let lowered = Self.termOrCharacter(terms).replace(Self.withoutFinalPeriod(text)) { group in
                group(1).isEmpty ? group(0).lowercased() : group(1)
            }
            return Self.loneI.replace(lowered, template: "I")
        }
    }

    /// The last dictionary's pattern, so a dictation compiles nothing while the dictionary stays the same.
    private static let lastTermPattern = Mutex<(terms: [String], pattern: Pattern)?>(nil)

    /// Matches a whole dictionary word, as group 1, or else any one character.
    private static func termOrCharacter(_ terms: [String]) -> Pattern {
        lastTermPattern.withLock { last in
            if let last, last.terms == terms { return last.pattern }
            let alternatives = terms.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            let pattern = Pattern(alternatives.isEmpty ? "()[\\s\\S]" : "(?<!\\w)(" + alternatives.joined(separator: "|") + ")(?!\\w)|[\\s\\S]")
            last = (terms, pattern)
            return pattern
        }
    }

    /// A trailing "..." stays, since it is not a full stop, and so does the period of a final abbreviation.
    private static func withoutFinalPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."), !abbreviationAtEnd.matches(text) else { return text }
        return String(text.dropLast())
    }
}

/// The fixed set of app groups. Every app belongs to exactly one, and an app no group lists belongs to Everything else.
public enum ProfileGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case messages, workChat, email, aiAndCode, everythingElse

    public var id: Self { self }

    public var title: String {
        switch self {
        case .messages: "Messages"
        case .workChat: "Work chat"
        case .email: "Email"
        case .aiAndCode: "AI and code"
        case .everythingElse: "Everything else"
        }
    }

    /// Everything else owns every app the other groups do not list, so it lists none itself.
    public var listsApps: Bool { self != .everythingElse }
}

public struct ProfileRules: Equatable, Codable, Sendable {
    public var style: WritingStyle
    /// Presses Return once the text is pasted, which sends a message in most chat apps.
    public var pressReturn: Bool

    public init(style: WritingStyle, pressReturn: Bool = false) { (self.style, self.pressReturn) = (style, pressReturn) }

    /// A style that does not read fails the whole entry, so its group keeps its default. A Return setting that is
    /// missing or does not read is off.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(WritingStyle.self, forKey: .style)
        pressReturn = (try? container.decodeIfPresent(Bool.self, forKey: .pressReturn)) ?? false
    }
}

/// An app in a group. A bundle ID ending in `*` matches every ID that starts with the rest, such as an app's beta and
/// nightly channels.
public struct ProfileApp: Equatable, Hashable, Codable, Sendable {
    public var bundleID: String
    public var name: String
    public var group: ProfileGroup

    public init(bundleID: String, name: String, group: ProfileGroup) {
        (self.bundleID, self.name, self.group) = (bundleID, name, group)
    }

    var isWildcard: Bool { bundleID.hasSuffix("*") }

    func matches(_ id: String) -> Bool {
        let own = bundleID.lowercased(), other = id.lowercased()
        return isWildcard ? other.hasPrefix(own.dropLast()) : own == other
    }
}

/// The rules of every group and the apps each one lists. No bundle ID is listed twice.
public struct AppProfiles: Equatable, Sendable {
    public private(set) var rules: [ProfileGroup: ProfileRules]
    public private(set) var apps: [ProfileApp]

    public init(rules: [ProfileGroup: ProfileRules], apps: [ProfileApp]) {
        let fallback = Self.defaultRules
        self.rules = Dictionary(uniqueKeysWithValues: ProfileGroup.allCases.map { ($0, rules[$0] ?? fallback[$0]!) })
        self.apps = []
        for app in apps { add(app) }
    }

    /// The group whose app list matches `bundleID`: an exact ID first, then the longest wildcard. Everything else
    /// when none does, or when the app is unknown.
    public func group(for bundleID: String?) -> ProfileGroup {
        guard let bundleID else { return .everythingElse }
        if let exact = apps.first(where: { !$0.isWildcard && $0.matches(bundleID) }) { return exact.group }
        return apps.filter { $0.isWildcard && $0.matches(bundleID) }.max { $0.bundleID.count < $1.bundleID.count }?.group
            ?? .everythingElse
    }

    public func rules(for bundleID: String?) -> ProfileRules { rules[group(for: bundleID)]! }

    public func apps(in group: ProfileGroup) -> [ProfileApp] { apps.filter { $0.group == group } }

    public mutating func set(_ rules: ProfileRules, for group: ProfileGroup) { self.rules[group] = rules }

    /// Moves the app out of any other group. Adding it to Everything else only takes it out of the others.
    public mutating func add(_ app: ProfileApp) {
        remove(app.bundleID)
        if app.group.listsApps { apps.append(app) }
    }

    public mutating func remove(_ bundleID: String) {
        apps.removeAll { $0.bundleID.lowercased() == bundleID.lowercased() }
    }

    static let defaultRules: [ProfileGroup: ProfileRules] = [
        .messages: ProfileRules(style: .casual), .workChat: ProfileRules(style: .casual), .email: ProfileRules(style: .formal),
        .aiAndCode: ProfileRules(style: .formal), .everythingElse: ProfileRules(style: .formal),
    ]

    public static let defaults = AppProfiles(rules: defaultRules, apps: [
        ProfileApp(bundleID: "com.apple.MobileSMS", name: "Messages", group: .messages),
        ProfileApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", group: .messages),
        ProfileApp(bundleID: "desktop.WhatsApp", name: "WhatsApp (older app)", group: .messages),
        ProfileApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", group: .messages),
        ProfileApp(bundleID: "org.telegram.desktop", name: "Telegram Desktop", group: .messages),
        ProfileApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal", group: .messages),
        ProfileApp(bundleID: "com.hnc.Discord", name: "Discord", group: .messages),
        ProfileApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", group: .workChat),
        ProfileApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", group: .workChat),
        ProfileApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)", group: .workChat),
        ProfileApp(bundleID: "com.apple.mail", name: "Mail", group: .email),
        ProfileApp(bundleID: "com.microsoft.Outlook", name: "Outlook", group: .email),
        ProfileApp(bundleID: "com.readdle.SparkDesktop", name: "Spark", group: .email),
        ProfileApp(bundleID: "com.readdle.smartemail-Mac", name: "Spark Classic", group: .email),
        ProfileApp(bundleID: "com.superhuman.electron", name: "Superhuman", group: .email),
        ProfileApp(bundleID: "com.mimestream.Mimestream", name: "Mimestream", group: .email),
        ProfileApp(bundleID: "com.t3tools.t3code*", name: "T3 Code", group: .aiAndCode),
        ProfileApp(bundleID: "com.openai.chat", name: "ChatGPT", group: .aiAndCode),
        ProfileApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude", group: .aiAndCode),
        ProfileApp(bundleID: "com.openai.codex", name: "Codex", group: .aiAndCode),
        ProfileApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", group: .aiAndCode),
        ProfileApp(bundleID: "com.anysphere.*", name: "Cursor (other builds)", group: .aiAndCode),
        ProfileApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", group: .aiAndCode),
        ProfileApp(bundleID: "dev.zed.Zed", name: "Zed", group: .aiAndCode),
        ProfileApp(bundleID: "com.apple.dt.Xcode", name: "Xcode", group: .aiAndCode),
        ProfileApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty", group: .aiAndCode),
        ProfileApp(bundleID: "com.apple.Terminal", name: "Terminal", group: .aiAndCode),
        ProfileApp(bundleID: "com.googlecode.iterm2", name: "iTerm2", group: .aiAndCode),
        ProfileApp(bundleID: "dev.warp.Warp-Stable", name: "Warp", group: .aiAndCode),
    ])
}

/// Stored as the rules keyed by group name and the app list. A group missing from a stored value, or whose rules do not
/// read, takes its defaults. An app that does not read is dropped, and an app list that is missing takes the defaults.
extension AppProfiles: Codable {
    private enum CodingKeys: String, CodingKey { case rules, apps }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? container.decodeIfPresent(LossyValues<ProfileRules>.self, forKey: .rules))?.values ?? [:]
        let rules = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in ProfileGroup(rawValue: key).map { ($0, value) } })
        let apps = (try? container.decodeIfPresent(LossyArray<ProfileApp>.self, forKey: .apps))?.elements ?? Self.defaults.apps
        self.init(rules: rules, apps: apps)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) }), forKey: .rules)
        try container.encode(apps, forKey: .apps)
    }
}

/// What goes into the app for one dictation, decided before anything is pasted.
public struct Insertion: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case dictation
        /// Pasted exactly as saved: no smart spacing.
        case snippet
        case pasteLast
    }

    public var text: String
    public var pressReturn: Bool
    public var source: Source

    public init(text: String, pressReturn: Bool = false, source: Source) {
        (self.text, self.pressReturn, self.source) = (text, pressReturn, source)
    }

    /// For Paste Last Transcript. A snippet goes in exactly as saved again, and nothing presses Return.
    public var again: Insertion { Insertion(text: text, source: source == .snippet ? .snippet : .pasteLast) }

    /// The cleaned dictation for the app it goes into: a snippet when the dictation is its cue, otherwise the text in
    /// its group's style, and whether to press Return.
    public static func make(_ cleaned: String, app bundleID: String?, configuration: Configuration) -> Insertion {
        let rules = configuration.settings.profiles.rules(for: bundleID)
        if let snippet = Snippets.match(cleaned, in: configuration.settings.snippets) {
            return Insertion(text: snippet.text, pressReturn: rules.pressReturn, source: .snippet)
        }
        return Insertion(text: rules.style.apply(cleaned, keeping: configuration.vocabulary.terms.map(\.text)),
                         pressReturn: rules.pressReturn, source: .dictation)
    }
}
