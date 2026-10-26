import DictationCore
import Foundation
import Observation

/// The single owner of user configuration, which spans UserDefaults (the Settings value) and the file
/// at ~/Library/Application Support/Dictation/vocabulary.txt, seeded from Vocabulary.bundledDefault on first
/// launch. A file saved by hand applies at the next key-down, menu open or window activation, which check its
/// modification date. The Dictionary page's edits apply at once.
@MainActor @Observable final class Preferences {
    private(set) var current: Configuration
    @ObservationIgnored var onChange: ((_ old: Configuration, _ new: Configuration) -> Void)?
    let vocabularyURL: URL
    let isFirstLaunch: Bool

    private static let settingsKey = "settings"

    private let defaults: UserDefaults
    @ObservationIgnored private var loadedStamp: FileStamp?

    init(defaults: UserDefaults = .standard,
         vocabularyURL: URL = URL.applicationSupportDirectory.appending(path: "Dictation/vocabulary.txt")) {
        self.defaults = defaults
        self.vocabularyURL = vocabularyURL
        let stored = defaults.data(forKey: Self.settingsKey)
        isFirstLaunch = stored == nil
        let settings = stored.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        current = Configuration(settings: settings ?? Settings(),
                                vocabulary: Vocabulary.parse(Vocabulary.bundledDefault).vocabulary, issues: [])
        if stored == nil { save(current.settings) }
        seedVocabularyFile()
        reloadVocabularyIfChanged()
    }

    /// Saves at once and tells `onChange` when anything moved.
    func change(_ edit: (inout Settings) -> Void) {
        var settings = current.settings
        edit(&settings)
        guard settings != current.settings else { return }
        save(settings)
        update { $0.settings = settings }
    }

    func saveVocabulary(_ vocabulary: Vocabulary) throws {
        let existing = (try? String(contentsOf: vocabularyURL, encoding: .utf8)) ?? Vocabulary.bundledDefault
        try FileManager.default.createDirectory(at: vocabularyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try vocabulary.fileText(keepingHeaderOf: existing).write(to: vocabularyURL, atomically: true, encoding: .utf8)
        loadedStamp = nil
        reloadVocabularyIfChanged()
    }

    /// A missing file keeps the vocabulary already in use.
    func reloadVocabularyIfChanged() {
        guard let stamp = FileStamp(vocabularyURL), stamp != loadedStamp,
              let text = try? String(contentsOf: vocabularyURL, encoding: .utf8)
        else { return }
        loadedStamp = stamp
        let (vocabulary, issues) = Vocabulary.parse(text)
        update {
            $0.vocabulary = vocabulary
            $0.issues = issues
        }
    }

    /// Recreates the file from the bundled default if the user deleted it.
    func seedVocabularyFile() {
        guard !FileManager.default.fileExists(atPath: vocabularyURL.path) else { return }
        try? FileManager.default.createDirectory(at: vocabularyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Vocabulary.bundledDefault.write(to: vocabularyURL, atomically: true, encoding: .utf8)
    }

    /// fn works as a hotkey only when Keyboard > "Press fn key to" is Do Nothing (0). Unset means a default
    /// that acts on fn.
    var fnKeyNeedsSetting: Bool {
        guard current.settings.hotkeys.contains(.fn) else { return false }
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int != 0
    }

    private func save(_ settings: Settings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func update(_ change: (inout Configuration) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        let old = current
        current = next
        onChange?(old, next)
    }
}

private struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int
        else { return nil }
        (self.modified, self.size) = (modified, size)
    }
}
