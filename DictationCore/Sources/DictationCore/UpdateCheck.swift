import Foundation

/// A release number such as `1.0.9`, compared field by field as numbers so 1.0.10 is newer than 1.0.9. A missing field
/// counts as 0, so 1.1 equals 1.1.0.
public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Reads dotted numbers with an optional leading `v`. Anything else, such as `1.0.9-beta`, is not a version.
    public init?(_ text: String) {
        let fields = text.dropFirst(text.hasPrefix("v") ? 1 : 0).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { field in field.allSatisfy { $0.isASCII && $0.isWholeNumber } ? Int(field) : nil }
        guard numbers.count == fields.count else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func == (lhs: Version, rhs: Version) -> Bool { compare(lhs, rhs) == 0 }
    public static func < (lhs: Version, rhs: Version) -> Bool { compare(lhs, rhs) < 0 }

    private static func compare(_ lhs: Version, _ rhs: Version) -> Int {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let (left, right) = (index < lhs.parts.count ? lhs.parts[index] : 0, index < rhs.parts.count ? rhs.parts[index] : 0)
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// The newest release on GitHub: its version, the page that shows it, and the zip an in-app update installs, when the
/// release has one.
public struct Release: Equatable, Sendable {
    public let version: Version
    public let page: URL
    public let archive: URL?

    public init(version: Version, page: URL, archive: URL? = nil) { (self.version, self.page, self.archive) = (version, page, archive) }

    /// Reads `tag_name`, `html_url` and the release's zip from the body of GitHub's "latest release" response. Nil when
    /// the tag or the page is missing, the tag is not a version, or the page is not an https page on github.com, since
    /// the page is what the app opens. A release with no usable zip is still a release: the page offers the download.
    public init?(json: Data) {
        struct Asset: Decodable { var name: String; var browser_download_url: String }
        struct Body: Decodable { var tag_name: String; var html_url: String; var assets: [Asset]? }
        guard let body = try? JSONDecoder().decode(Body.self, from: json) else { return nil }
        let archive = body.assets?.first { Self.isArchive($0.browser_download_url, name: $0.name, tag: body.tag_name) }?.browser_download_url
        self.init(tag: body.tag_name, page: body.html_url, archive: archive)
    }

    init?(tag: String, page: String, archive: String? = nil) {
        guard let version = Version(tag), let url = URL(string: page), url.scheme == "https", url.host() == "github.com" else { return nil }
        self.init(version: version, page: url, archive: archive.flatMap { Self.isArchive($0, name: Self.archiveName(version), tag: tag) ? URL(string: $0) : nil })
    }

    /// The zip `scripts/release.sh` attaches to a release.
    public static func archiveName(_ version: Version) -> String { "Lip-Service-\(version).zip" }

    /// Only this repository's own release download of the tag counts, so a release body cannot send the app elsewhere.
    private static func isArchive(_ link: String, name: String, tag: String) -> Bool {
        guard let version = Version(tag), name == archiveName(version), let url = URL(string: link), url.scheme == "https", url.host() == "github.com",
              url.query == nil, url.fragment == nil, url.user == nil, url.port == nil else { return false }
        return url.path == "/hunterbohm/lip-service/releases/download/\(tag)/\(name)"
    }
}

/// Where the checker keeps its saved facts: the last UTC day it asked, and the newest release it saw.
public protocol UpdateCheckStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

/// Asks for the newest release at most once per UTC day and keeps what it learned, so the notice survives a relaunch
/// without another request. With the setting off, or a running version that is not a number, it does nothing. The day
/// is marked before the request, so a request that fails is not repeated until tomorrow.
@MainActor public final class UpdateChecker {
    public nonisolated static let dayKey = "updateCheckLastDay"
    public nonisolated static let versionKey = "updateCheckVersion"
    public nonisolated static let pageKey = "updateCheckPage"
    public nonisolated static let archiveKey = "updateCheckArchive"

    private let store: any UpdateCheckStore
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let running: Version?
    private let fetch: @Sendable () async -> Data?

    public init(store: any UpdateCheckStore, isEnabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init,
                running: Version?, fetch: @escaping @Sendable () async -> Data?) {
        (self.store, self.isEnabled, self.now, self.running, self.fetch) = (store, isEnabled, now, running, fetch)
    }

    /// The saved release, when it is newer than the running app.
    public var available: Release? {
        guard isEnabled(), let running, let saved, saved.version > running else { return nil }
        return saved
    }

    public func checkIfDue() async {
        guard isEnabled(), running != nil else { return }
        let day = UsageReporter.day(of: now())
        if let last = store.string(forKey: Self.dayKey), last >= day { return }
        store.set(day, forKey: Self.dayKey)
        guard let body = await fetch(), let release = Release(json: body) else { return }
        store.set(release.version.description, forKey: Self.versionKey)
        store.set(release.page.absoluteString, forKey: Self.pageKey)
        store.set(release.archive?.absoluteString ?? "", forKey: Self.archiveKey)
    }

    private var saved: Release? {
        guard let version = store.string(forKey: Self.versionKey), let page = store.string(forKey: Self.pageKey) else { return nil }
        return Release(tag: "v" + version, page: page, archive: store.string(forKey: Self.archiveKey).flatMap { $0.isEmpty ? nil : $0 })
    }
}
