import AppKit
import DictationCore
import Foundation
import Observation

extension DefaultsStore: UpdateCheckStore {}

enum UpdateCheck {
    static let url = URL(string: "https://api.github.com/repos/hunterbohm/lip-service/releases/latest")!

    /// Off whenever `LS_DEFAULTS` points the app at a test's settings, so no test or bench run asks GitHub or marks a day.
    @MainActor static func checker(preferences: Preferences) -> UpdateChecker {
        UpdateChecker(
            store: DefaultsStore(.standard),
            isEnabled: { SettingsStore.isReal && preferences.current.settings.checkForUpdates },
            running: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init),
            fetch: get)
    }

    /// A GET with no cookies and no cache that sends only what GitHub requires: a fixed User-Agent, not the system's,
    /// which names the app's build and the macOS kernel. Any failure is dropped.
    static func get() async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lip Service", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }
}

/// The newest release the checker has found that is newer than this app, for the menu and the Home page to show.
@MainActor @Observable final class UpdateNotice {
    @ObservationIgnored private let checker: UpdateChecker
    private var checks = 0

    init(_ checker: UpdateChecker) { self.checker = checker }

    /// Reads `checks` so a finished check redraws what shows it.
    var available: Release? {
        _ = checks
        return checker.available
    }

    func check() async {
        await checker.checkIfDue()
        checks += 1
    }

    func download(_ release: Release) { NSWorkspace.shared.open(release.page) }
}
