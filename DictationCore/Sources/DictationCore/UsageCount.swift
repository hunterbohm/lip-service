import CryptoKit
import Foundation

/// What the anonymous daily usage count can tell apart. Nothing finer is ever sent.
public enum CountedUse: String, CaseIterable, Codable, Sendable {
    case dictation, ghostwrite, handoff
}

/// The whole body of a daily report. These five fields are everything that leaves the Mac: never audio, text, app or
/// window names, screen content or agent names. `install` is the SHA-256 of a random ID that stays in this Mac's
/// preferences.
public struct DailyReport: Equatable, Codable, Sendable {
    public var install: String
    public var version: String
    public var macos: String
    /// The UTC day, `yyyy-MM-dd`.
    public var day: String
    public var used: [CountedUse]
}

/// Where the reporter keeps its two facts: the random install ID and the last UTC day it reported.
public protocol UsageCountStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

/// Sends at most one report per install per UTC day, when the user first really uses the app that day. With the
/// setting off it does nothing at all, not even create the install ID. A send that fails is not repeated: the day is
/// marked first, so the next try is tomorrow.
@MainActor public final class UsageReporter {
    public static let installKey = "usageCountInstall"
    public static let dayKey = "usageCountLastDay"

    private let store: any UsageCountStore
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let version: String
    private let macOS: String
    private let send: @Sendable (Data) async -> Void
    private var sending: Task<Void, Never>?

    public init(store: any UsageCountStore, isEnabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init,
                version: String, macOS: String, send: @escaping @Sendable (Data) async -> Void) {
        (self.store, self.isEnabled, self.now, self.version, self.macOS, self.send) = (store, isEnabled, now, version, macOS, send)
    }

    /// Call when a dictation finished, a Ghostwrite draft was typed, or a Hand off was sent.
    public func used(_ use: CountedUse) {
        guard isEnabled() else { return }
        let day = Self.day(of: now())
        if let last = store.string(forKey: Self.dayKey), last >= day { return }
        store.set(day, forKey: Self.dayKey)
        let report = DailyReport(install: Self.hash(installID()), version: version, macos: macOS, day: day, used: [use])
        guard let body = try? JSONEncoder().encode(report) else { return }
        let send = send
        sending = Task { await send(body) }
    }

    /// Returns once the report in flight, if any, has been sent or has failed.
    public func finishSending() async { await sending?.value }

    private func installID() -> String {
        if let id = store.string(forKey: Self.installKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        store.set(id, forKey: Self.installKey)
        return id
    }

    nonisolated static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// A POST of the body to `url` with no cookies, no cache and a short timeout. Every failure is dropped.
    public static func post(to url: URL) -> @Sendable (Data) async -> Void {
        { body in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.httpShouldSetCookies = false
            configuration.waitsForConnectivity = false
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession(configuration: configuration).data(for: request)
        }
    }
}
