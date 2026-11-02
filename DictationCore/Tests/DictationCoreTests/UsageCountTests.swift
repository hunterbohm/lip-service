import Foundation
import Testing
@testable import DictationCore

private final class MemoryStore: UsageCountStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func add(_ body: Data) { lock.withLock { bodies.append(body) } }
    var all: [Data] { lock.withLock { bodies } }
}

private let noon = Date(timeIntervalSince1970: 1_793_620_800)

@MainActor private struct Rig {
    let store = MemoryStore()
    let sent = Sent()
    let box = Box()

    final class Box { var enabled = true; var time = noon }

    func reporter(version: String = "1.0.6", macOS: String = "26.0.1") -> UsageReporter {
        let box = box, sent = sent
        return UsageReporter(store: store, isEnabled: { box.enabled }, now: { box.time }, version: version, macOS: macOS,
                             send: { sent.add($0) })
    }
}

@Suite("Usage count") @MainActor struct UsageCountTests {
    @Test func sendsOneReportOnTheFirstUseOfTheDayAndNoMoreThatDay() async {
        let rig = Rig(), reporter = rig.reporter()
        reporter.used(.dictation)
        await reporter.finishSending()
        reporter.used(.dictation)
        reporter.used(.ghostwrite)
        reporter.used(.handoff)
        await reporter.finishSending()
        #expect(rig.sent.all.count == 1)
    }

    @Test func reportsAgainOnTheNextUTCDay() async {
        let rig = Rig(), reporter = rig.reporter()
        reporter.used(.dictation)
        rig.box.time = noon.addingTimeInterval(86_400)
        reporter.used(.ghostwrite)
        await reporter.finishSending()
        #expect(rig.sent.all.count == 2)
        let days = rig.sent.all.compactMap { try? JSONDecoder().decode(DailyReport.self, from: $0).day }
        #expect(days == ["2026-11-02", "2026-11-03"])
    }

    @Test func theDayIsTheUTCDayNotTheLocalOne() {
        let lateEvening = Date(timeIntervalSince1970: 1_793_663_999)
        #expect(UsageReporter.day(of: lateEvening) == "2026-11-02")
        #expect(UsageReporter.day(of: lateEvening.addingTimeInterval(1)) == "2026-11-03")
    }

    @Test func aClockSetBackDoesNotReportTheSameDayTwice() async {
        let rig = Rig(), reporter = rig.reporter()
        reporter.used(.dictation)
        rig.box.time = noon.addingTimeInterval(-86_400)
        reporter.used(.dictation)
        await reporter.finishSending()
        #expect(rig.sent.all.count == 1)
    }

    @Test func withTheSwitchOffNothingIsSentOrStored() async {
        let rig = Rig(), reporter = rig.reporter()
        rig.box.enabled = false
        reporter.used(.dictation)
        reporter.used(.ghostwrite)
        await reporter.finishSending()
        #expect(rig.sent.all.isEmpty)
        #expect(rig.store.values.isEmpty)
    }

    @Test func turningTheSwitchOffMidDaySendsNothingMore() async {
        let rig = Rig(), reporter = rig.reporter()
        rig.box.time = noon
        reporter.used(.dictation)
        rig.box.time = noon.addingTimeInterval(86_400)
        rig.box.enabled = false
        reporter.used(.dictation)
        await reporter.finishSending()
        #expect(rig.sent.all.count == 1)
    }

    @Test func theBodyHoldsExactlyTheFiveFieldsAndNothingElse() async throws {
        let rig = Rig(), reporter = rig.reporter(version: "1.0.6", macOS: "26.0.1")
        reporter.used(.handoff)
        await reporter.finishSending()
        let body = try #require(rig.sent.all.first)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["install", "version", "macos", "day", "used"])
        #expect(object["version"] as? String == "1.0.6")
        #expect(object["macos"] as? String == "26.0.1")
        #expect(object["day"] as? String == "2026-11-02")
        #expect(object["used"] as? [String] == ["handoff"])
    }

    @Test func theInstallIsAHashOfARandomIDThatStaysTheSame() async throws {
        let rig = Rig(), reporter = rig.reporter()
        reporter.used(.dictation)
        rig.box.time = noon.addingTimeInterval(86_400)
        reporter.used(.dictation)
        await reporter.finishSending()
        let reports = try rig.sent.all.map { try JSONDecoder().decode(DailyReport.self, from: $0) }
        let id = try #require(rig.store.values[UsageReporter.installKey])
        #expect(reports[0].install == reports[1].install)
        #expect(reports[0].install == UsageReporter.hash(id))
        #expect(reports[0].install != id)
        #expect(reports[0].install.count == 64 && reports[0].install.allSatisfy(\.isHexDigit))
        #expect(UsageReporter.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func twoInstallsGetDifferentIDs() async throws {
        let first = Rig(), second = Rig()
        first.reporter().used(.dictation)
        second.reporter().used(.dictation)
        #expect(first.store.values[UsageReporter.installKey] != second.store.values[UsageReporter.installKey])
    }

    @Test func theSettingIsOnByDefaultAndSurvivesAnOlderSettingsFile() throws {
        #expect(Settings().sendUsageCount)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.sendUsageCount)
        var off = Settings()
        off.sendUsageCount = false
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off))
        #expect(!back.sendUsageCount)
    }

    /// Runs the real reporter and sender against a deployed Worker. `LS_LIVE_USAGE_URL` is the ping URL. An install
    /// that uses the app twice makes one report; an install with the switch off makes none.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LS_LIVE_USAGE_URL"] != nil))
    func liveReportReachesTheWorker() async throws {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["LS_LIVE_USAGE_URL"] ?? ""))
        let on = UsageReporter(store: MemoryStore(), isEnabled: { true }, version: "0.0.0-livecheck", macOS: "26.0",
                               send: UsageReporter.post(to: url))
        on.used(.dictation)
        on.used(.ghostwrite)
        await on.finishSending()
        let off = UsageReporter(store: MemoryStore(), isEnabled: { false }, version: "0.0.0-livecheck", macOS: "26.0",
                                send: UsageReporter.post(to: url))
        off.used(.dictation)
        await off.finishSending()
    }
}
