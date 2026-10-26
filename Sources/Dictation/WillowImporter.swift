import DictationCore
import Foundation
import Observation

struct WillowFolder: Sendable {
    var files = 0
    var entries: [HistoryEntry] = []
    var cancelled = 0
    var empty = 0
    var unreadable = 0
    var settings = Willow.ImportedSettings(preferences: nil, barEdgePosition: nil, showMenuBarIcon: nil)

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "com.seewillow.WillowMac")
    private static let domain = "com.seewillow.WillowMac"

    /// Opens Transcripts/*.json and Preferences/preferences.json only. Never Preferences/cached_account_session.json,
    /// which holds Willow's account tokens, and never the audio.
    static func read(_ folder: URL) -> WillowFolder {
        var found = WillowFolder()
        let transcripts = folder.appending(path: "Transcripts")
        let files = ((try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        found.files = files.count
        for file in files {
            switch Willow.transcript((try? Data(contentsOf: file)) ?? Data()) {
            case .dictation(let entry): found.entries.append(entry)
            case .cancelled: found.cancelled += 1
            case .empty: found.empty += 1
            case .unreadable: found.unreadable += 1
            }
        }
        let preferences = try? Data(contentsOf: folder.appending(path: "Preferences/preferences.json"))
        CFPreferencesAppSynchronize(domain as CFString)
        found.settings = Willow.ImportedSettings(
            preferences: preferences,
            barEdgePosition: CFPreferencesCopyAppValue("barEdgePosition" as CFString, domain as CFString) as? String,
            showMenuBarIcon: CFPreferencesCopyAppValue("showMenuBarIcon" as CFString, domain as CFString) as? Bool)
        return found
    }

    static func keysAndTypes(_ value: Any?) -> String {
        switch value {
        case nil: return "missing"
        case let array as [Any]: return "array of \(array.count): " + array.map(keysAndTypes).joined(separator: "; ")
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map { "\($0): \(keysAndTypes(dictionary[$0]))" }.joined(separator: ", ") + "}"
        case let string as String:
            guard let data = Data(base64Encoded: string) else { return "string" }
            if let object = try? JSONSerialization.jsonObject(with: data) { return "base64 JSON " + keysAndTypes(object) }
            if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) { return "base64 plist " + keysAndTypes(object) }
            return "base64 data"
        case is NSNumber: return "number"
        default: return "\(type(of: value!))"
        }
    }
}

@MainActor @Observable final class WillowImporter {
    enum Phase: Equatable {
        case ready, importing, finished(String)
    }

    private static let cardDismissedKey = "willowImportCardDismissed"

    private(set) var phase = Phase.ready
    private(set) var isAvailable = false
    private(set) var cardDismissed: Bool
    let folder: URL
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let preferences: Preferences

    var showsCard: Bool { isAvailable && (!cardDismissed || phase != .ready) }

    init(folder: URL = WillowFolder.defaultURL, defaults: UserDefaults = .standard, history: HistoryStore,
         preferences: Preferences) {
        (self.folder, self.defaults, self.history, self.preferences) = (folder, defaults, history, preferences)
        cardDismissed = defaults.bool(forKey: Self.cardDismissedKey)
        refresh()
    }

    func refresh() { isAvailable = FileManager.default.fileExists(atPath: folder.path) }

    func dismissCard() {
        cardDismissed = true
        defaults.set(true, forKey: Self.cardDismissedKey)
        if case .finished = phase { phase = .ready }
    }

    func run() {
        guard phase != .importing else { return }
        phase = .importing
        let folder = folder
        Task {
            let found = await Task.detached(priority: .userInitiated) { WillowFolder.read(folder) }.value
            let added = history.merge(found.entries)
            preferences.change { found.settings.apply(to: &$0) }
            cardDismissed = true
            defaults.set(true, forKey: Self.cardDismissedKey)
            phase = .finished(Self.message(added: added, settings: !found.settings.isEmpty))
        }
    }

    static func message(added: Int, settings: Bool) -> String {
        let dictations = added == 1 ? "1 dictation" : "\(added.formatted()) dictations"
        return switch (added, settings) {
        case (0, true): "No new dictations to import. Applied your Willow settings."
        case (0, false): "No new dictations to import."
        case (_, true): "Imported \(dictations) and your Willow settings."
        case (_, false): "Imported \(dictations)."
        }
    }

    nonisolated static func dryRun(_ folder: URL) -> Int32 {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            print("No Willow folder at \(folder.path)")
            return 1
        }
        let found = WillowFolder.read(folder)
        let dates = found.entries.map(\.date)
        let byApp = Dictionary(grouping: found.entries) { $0.app?.name ?? "(no app)" }.mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        print("Willow folder: \(folder.path)")
        print("Transcript files: \(found.files)")
        print("Would import \(found.entries.count) dictations, \(found.entries.reduce(0) { $0 + $1.words }) words")
        if let first = dates.min(), let last = dates.max() {
            print("Dates: \(first.formatted(date: .abbreviated, time: .shortened)) to \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        print("With audio length: \(found.entries.count { $0.audioSeconds != nil }), with app: \(found.entries.count { $0.app != nil })")
        print("Skipped: \(found.cancelled) cancelled, \(found.empty) empty, \(found.unreadable) unreadable")
        print("Apps: " + byApp.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("Settings it would apply:")
        for line in found.settings.summary { print("  \(line)") }
        if !found.settings.skippedHotkeys.isEmpty {
            print("Hotkeys it would skip: \(found.settings.skippedHotkeys.joined(separator: ", "))")
        }
        let preferences = (try? Data(contentsOf: folder.appending(path: "Preferences/preferences.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        print("hotkeyDataArray layout: \(WillowFolder.keysAndTypes(preferences?["hotkeyDataArray"]))")
        print("preferences.json keys: \(preferences?.keys.sorted().joined(separator: ", ") ?? "file missing")")
        print("Nothing was written.")
        return 0
    }
}
