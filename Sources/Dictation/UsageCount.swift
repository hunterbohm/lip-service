import DictationCore
import Foundation

/// Strings in UserDefaults, under the keys the usage count and the update check keep.
final class DefaultsStore: UsageCountStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
}

enum UsageCount {
    static let url = URL(string: "https://lipservice-usage.hunterbohm.me/v1/ping")!

    /// Off whenever `LS_DEFAULTS` points the app at a test's settings, so no test or bench run is ever counted.
    @MainActor static func reporter(preferences: Preferences) -> UsageReporter {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return UsageReporter(
            store: DefaultsStore(.standard),
            isEnabled: { SettingsStore.isReal && preferences.current.settings.sendUsageCount },
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            send: UsageReporter.post(to: url))
    }
}
