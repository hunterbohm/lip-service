import Foundation
import Testing
@testable import DictationCore

private func version(_ text: String) -> Version { Version(text)! }

private func json(tag: String = "v1.0.9", page: String = "https://github.com/hunterbohm/lip-service/releases/tag/v1.0.9") -> Data {
    Data(#"{"id":1,"tag_name":"\#(tag)","name":"Lip Service","html_url":"\#(page)","assets":[]}"#.utf8)
}

@Suite("Version") struct VersionTests {
    @Test func readsDottedNumbersWithAnOptionalV() {
        #expect(Version("1.0.9")?.parts == [1, 0, 9])
        #expect(Version("v1.0.9")?.parts == [1, 0, 9])
        #expect(Version("v2")?.parts == [2])
        #expect(version("v1.0.9").description == "1.0.9")
    }

    @Test(arguments: ["", "v", "1.", ".1", "1..2", "1.0.9-beta", "1.0.9+3", "V1.0.9", "vv1.0", "latest", "1.0 .9", "１.０", "1.0.99999999999999999999"])
    func ignoresATagThatIsNotAVersion(_ tag: String) {
        #expect(Version(tag) == nil)
    }

    @Test func comparesFieldsAsNumbers() {
        #expect(version("1.0.10") > version("1.0.9"))
        #expect(version("1.10.0") > version("1.9.9"))
        #expect(version("2.0") > version("1.99.99"))
        #expect(version("1.0.8") < version("v1.0.9"))
    }

    @Test func aMissingFieldCountsAsZero() {
        #expect(version("1.1") == version("1.1.0"))
        #expect(version("1.0.0.1") > version("1.0"))
        #expect(!(version("1.0") < version("1.0.0")))
    }
}

@Suite("Release") struct ReleaseTests {
    @Test func readsTheTagAndThePageFromGitHubsJSON() throws {
        let release = try #require(Release(json: json()))
        #expect(release.version == version("1.0.9"))
        #expect(release.page.absoluteString == "https://github.com/hunterbohm/lip-service/releases/tag/v1.0.9")
    }

    @Test func aMissingFieldIsNoRelease() {
        #expect(Release(json: Data(#"{"html_url":"https://github.com/hunterbohm/lip-service/releases/tag/v1.0.9"}"#.utf8)) == nil)
        #expect(Release(json: Data(#"{"tag_name":"v1.0.9"}"#.utf8)) == nil)
        #expect(Release(json: Data(#"{"tag_name":null,"html_url":null}"#.utf8)) == nil)
        #expect(Release(json: Data("{}".utf8)) == nil)
    }

    @Test func aTagThatIsNotAVersionIsNoRelease() {
        #expect(Release(json: json(tag: "nightly")) == nil)
        #expect(Release(json: json(tag: "v1.0.9-rc1")) == nil)
    }

    @Test func aBodyThatIsNotJSONIsNoRelease() {
        #expect(Release(json: Data("<html>rate limited</html>".utf8)) == nil)
        #expect(Release(json: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
        #expect(Release(json: Data()) == nil)
    }

    @Test func onlyAnHTTPSPageOnGitHubIsOpened() {
        #expect(Release(json: json(page: "http://github.com/hunterbohm/lip-service/releases/tag/v1.0.9")) == nil)
        #expect(Release(json: json(page: "file:///Applications/Utilities/Terminal.app")) == nil)
        #expect(Release(json: json(page: "https://github.com.evil.example/releases")) == nil)
        #expect(Release(json: json(page: "https://evil.example/github.com")) == nil)
        #expect(Release(json: json(page: "")) == nil)
    }
}

private final class MemoryStore: UpdateCheckStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var body: Data?
    var total: Int { lock.withLock { count } }
    func hit() -> Data? { lock.withLock { count += 1; return body } }
}

private let noon = Date(timeIntervalSince1970: 1_793_620_800)

@MainActor private struct Rig {
    let store = MemoryStore()
    let requests = Requests()
    let box = Box()

    final class Box { var enabled = true; var time = noon }

    init(answer: Data? = json()) { requests.body = answer }

    func checker(running: String? = "1.0.7") -> UpdateChecker {
        let box = box, requests = requests
        return UpdateChecker(store: store, isEnabled: { box.enabled }, now: { box.time }, running: running.flatMap(Version.init),
                             fetch: { requests.hit() })
    }
}

@Suite("Update check") @MainActor struct UpdateCheckTests {
    @Test func asksOnceADayAndShowsANewerRelease() async {
        let rig = Rig(), checker = rig.checker()
        #expect(checker.available == nil)
        await checker.checkIfDue()
        await checker.checkIfDue()
        rig.box.time = noon.addingTimeInterval(3600)
        await checker.checkIfDue()
        #expect(rig.requests.total == 1)
        #expect(checker.available?.version == version("1.0.9"))
    }

    @Test func asksAgainOnTheNextUTCDay() async {
        let rig = Rig(), checker = rig.checker()
        await checker.checkIfDue()
        rig.box.time = noon.addingTimeInterval(86_400)
        await checker.checkIfDue()
        #expect(rig.requests.total == 2)
    }

    @Test func theDayIsTheUTCDayNotTheLocalOne() async {
        let rig = Rig(), checker = rig.checker()
        rig.box.time = Date(timeIntervalSince1970: 1_793_663_999)
        await checker.checkIfDue()
        #expect(rig.store.values[UpdateChecker.dayKey] == "2026-11-02")
        rig.box.time = Date(timeIntervalSince1970: 1_793_664_000)
        await checker.checkIfDue()
        #expect(rig.requests.total == 2)
    }

    @Test func withTheSettingOffNothingIsSentOrSaved() async {
        let rig = Rig()
        rig.box.enabled = false
        let checker = rig.checker()
        await checker.checkIfDue()
        #expect(rig.requests.total == 0)
        #expect(rig.store.values.isEmpty)
    }

    @Test func turningTheSettingOffHidesTheNoticeAndBackOnShowsItAgain() async {
        let rig = Rig(), checker = rig.checker()
        await checker.checkIfDue()
        rig.box.enabled = false
        #expect(checker.available == nil)
        rig.box.enabled = true
        #expect(checker.available != nil)
    }

    @Test func aFailedRequestIsSilentAndWaitsUntilTomorrow() async {
        let rig = Rig(answer: nil), checker = rig.checker()
        await checker.checkIfDue()
        await checker.checkIfDue()
        #expect(rig.requests.total == 1)
        #expect(checker.available == nil)
        rig.requests.body = json()
        rig.box.time = noon.addingTimeInterval(86_400)
        await checker.checkIfDue()
        #expect(rig.requests.total == 2)
        #expect(checker.available != nil)
    }

    @Test func aFailedRequestKeepsWhatWasSeenBefore() async {
        let rig = Rig(), checker = rig.checker()
        await checker.checkIfDue()
        rig.requests.body = Data("not json".utf8)
        rig.box.time = noon.addingTimeInterval(86_400)
        await checker.checkIfDue()
        #expect(checker.available?.version == version("1.0.9"))
    }

    @Test func aNewerSavedReleaseStillShowsAfterARelaunchWithoutAnotherRequest() async {
        let rig = Rig()
        await rig.checker().checkIfDue()
        let relaunched = rig.checker()
        #expect(relaunched.available?.version == version("1.0.9"))
        await relaunched.checkIfDue()
        #expect(rig.requests.total == 1)
    }

    @Test func anOlderOrEqualReleaseDoesNotShow() async {
        let older = Rig(answer: json(tag: "v1.0.6")), equal = Rig(answer: json(tag: "v1.0.7"))
        for rig in [older, equal] {
            let checker = rig.checker()
            await checker.checkIfDue()
            #expect(checker.available == nil)
            #expect(rig.checker().available == nil)
        }
    }

    @Test func updatingTheAppHidesTheSavedNotice() async {
        let rig = Rig()
        await rig.checker().checkIfDue()
        #expect(rig.checker(running: "1.0.9").available == nil)
        #expect(rig.checker(running: "1.0.10").available == nil)
        #expect(rig.checker(running: "1.0.8").available != nil)
    }

    @Test func aRunningVersionThatIsNotANumberNeverAsksOrShows() async {
        let rig = Rig(), checker = rig.checker(running: "unknown")
        await checker.checkIfDue()
        #expect(rig.requests.total == 0)
        #expect(checker.available == nil)
    }

    @Test func aTamperedSavedPageIsNotShown() {
        let rig = Rig()
        rig.store.set("1.0.9", forKey: UpdateChecker.versionKey)
        rig.store.set("file:///System/Applications/Calculator.app", forKey: UpdateChecker.pageKey)
        #expect(rig.checker().available == nil)
    }
}
