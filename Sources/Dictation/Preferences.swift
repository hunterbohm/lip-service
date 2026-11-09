import DictationCore
import Foundation
import Observation

/// The single owner of user configuration, which spans UserDefaults (the Settings value) and the file
/// at ~/Library/Application Support/Dictation/vocabulary.txt, seeded from Vocabulary.bundledDefault on first
/// launch. A file saved by hand applies at the next key-down, menu open or window activation, which check its
/// modification date. The Dictionary page's edits apply at once.
@MainActor @Observable final class Preferences {
    private(set) var current: Configuration
    /// The last setup an agent applied, until the user dismisses or undoes it.
    private(set) var setupRecord: SetupRecord?
    @ObservationIgnored var onChange: ((_ old: Configuration, _ new: Configuration) -> Void)?
    let vocabularyURL: URL
    /// True from the first launch until the first run is finished or closed, and when an agent set the app up before
    /// it ever ran.
    private(set) var needsOnboarding: Bool

    private let defaults: UserDefaults
    @ObservationIgnored private var loadedStamp: FileStamp?

    init(defaults: UserDefaults = .standard,
         vocabularyURL: URL = SupportFolder.url.appending(path: "vocabulary.txt")) {
        self.defaults = defaults
        self.vocabularyURL = vocabularyURL
        let stored = SettingsStore.read(defaults)
        if stored == nil { defaults.set(true, forKey: SettingsStore.onboardingKey) }
        needsOnboarding = defaults.bool(forKey: SettingsStore.onboardingKey)
        setupRecord = SettingsStore.readRecord(defaults)
        current = Configuration(settings: stored ?? Settings(),
                                vocabulary: Vocabulary.parse(Vocabulary.bundledDefault).vocabulary, issues: [])
        if stored == nil { save(current.settings) }
        AudioDevices.automaticOrder = current.settings.automaticOrder
        seedVocabularyFile()
        reloadVocabularyIfChanged()
    }

    /// The first run was finished, skipped or closed.
    func finishOnboarding() {
        needsOnboarding = false
        defaults.set(false, forKey: SettingsStore.onboardingKey)
    }

    /// A setup an agent applied while the app was running: the settings it wrote, and the record that can undo them.
    func adopt(settings: Settings, record: SetupRecord) {
        setupRecord = record
        guard settings != current.settings else { return }
        save(settings)
        update { $0.settings = settings }
    }

    func undoSetup() {
        guard let record = setupRecord else { return }
        change { $0 = record.undo($0) }
        dismissSetup()
    }

    func dismissSetup() {
        setupRecord = nil
        SettingsStore.clearRecord(defaults)
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
        guard current.settings.hotkeys.contains(where: { $0.key == Shortcut.fn.key }) else { return false }
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int != 0
    }

    private func save(_ settings: Settings) { SettingsStore.write(settings, to: defaults) }

    private func update(_ change: (inout Configuration) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        let old = current
        current = next
        // Before `onChange`, which readies the microphone by it.
        AudioDevices.automaticOrder = next.settings.automaticOrder
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

/// Where the settings live in UserDefaults, shared by the app and `Dictation setup`, which runs as another process.
enum SettingsStore {
    static let settingsKey = "settings"
    static let recordKey = "setupRecord"
    static let onboardingKey = "onboardingPending"
    /// Posted by `setup apply` for a running app. The user info carries the new settings and the record as JSON text.
    static let appliedNotification = Notification.Name("com.hunterbohm.dictation.setupApplied")

    /// `LS_DEFAULTS` names a file to keep the settings in instead, so a test never touches the real ones.
    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["LS_DEFAULTS"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static var isReal: Bool { ProcessInfo.processInfo.environment["LS_DEFAULTS"] == nil }

    static func read(_ defaults: UserDefaults) -> Settings? {
        defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }

    static func write(_ settings: Settings, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    static func readRecord(_ defaults: UserDefaults) -> SetupRecord? {
        defaults.data(forKey: recordKey).flatMap { try? JSONDecoder().decode(SetupRecord.self, from: $0) }
    }

    static func write(_ record: SetupRecord, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: recordKey) }
    }

    static func clearRecord(_ defaults: UserDefaults) { defaults.removeObject(forKey: recordKey) }
}
