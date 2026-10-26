import Foundation
import Testing
@testable import DictationCore

@Suite("Willow import") struct WillowTests {
    static let willowEpoch: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))!
    }()

    @Test func aCompletedTranscriptKeepsWillowsIdDateDurationAndApp() throws {
        let file = #"""
            {"text": "Ship the build tonight.", "date": 783000000.5, "status": "completed", "id": "6F1C-AA",
             "audioURL": "file:///tmp/x.m4a", "dictationEventId": "e1", "isFlagged": false, "recordingDuration": 4.25,
             "appContext": {"window": {"title": "T3", "url": null}, "application": {"name": "T3 Code", "bundle_id": "com.t3tools.t3code"}}}
            """#
        guard case .dictation(let entry) = Willow.transcript(Data(file.utf8)) else {
            Issue.record("expected a dictation")
            return
        }
        #expect(entry.id == "willow:6F1C-AA")
        #expect(entry.date == Self.willowEpoch.addingTimeInterval(783_000_000.5))
        #expect(entry.text == "Ship the build tonight.")
        #expect(entry.audioSeconds == 4.25)
        #expect(entry.words == 4)
        #expect(entry.app == HistoryApp(name: "T3 Code", bundleID: "com.t3tools.t3code"))
    }

    @Test func aMissingAppContextAndANullStatusStillImport() {
        let file = #"{"text": "hello", "date": 700000000, "status": null, "id": 17}"#
        #expect(Willow.transcript(Data(file.utf8))
            == .dictation(HistoryEntry(id: "willow:17", date: Self.willowEpoch.addingTimeInterval(700_000_000),
                                       text: "hello", audioSeconds: nil, app: nil)))
    }

    @Test func cancelledEmptyAndBrokenFilesAreSkipped() {
        #expect(Willow.transcript(Data(#"{"text": "hi", "date": 1, "status": "cancelled", "id": "a"}"#.utf8)) == .cancelled)
        #expect(Willow.transcript(Data(#"{"text": "  \n", "date": 1, "status": "completed", "id": "b"}"#.utf8)) == .empty)
        #expect(Willow.transcript(Data(#"{"date": 1, "id": "c"}"#.utf8)) == .empty)
        #expect(Willow.transcript(Data(#"{"text": "no id", "date": 1}"#.utf8)) == .unreadable)
        #expect(Willow.transcript(Data("not json".utf8)) == .unreadable)
    }

    static let preferences = #"""
        {"hotkeyDataArray": [{"keyName": "Fn", "keyCode": 63}, {"keyName": "Right Control", "keyCode": 62}],
         "audioRecordingSounds": true, "hideBarWhenIdle": true, "smartTextInsertion": false,
         "selectedMicrophoneUID": "uid:AppleUSBAudioEngine:Shure Inc:Shure MV7+:2B0E000:1",
         "selectedMicrophoneModelUID": "Shure MV7+:Shure Inc:2B0E", "somethingElse": 3}
        """#

    @Test func settingsMapOntoTheAppsSettings() {
        let imported = Willow.ImportedSettings(preferences: Data(Self.preferences.utf8), barEdgePosition: "right",
                                               showMenuBarIcon: false)
        var settings = Settings()
        settings.hideBarWhenIdle = false
        settings.hotkeys = [.rightOption]
        settings.smartSpacing = true
        settings.sounds = false
        imported.apply(to: &settings)

        var expected = Settings()
        expected.hotkeys = [.fn, .rightControl]
        expected.sounds = true
        expected.hideBarWhenIdle = true
        expected.smartSpacing = false
        expected.microphone = .device(uid: "AppleUSBAudioEngine:Shure Inc:Shure MV7+:2B0E000:1", name: "Shure MV7+")
        expected.barEdge = .right
        expected.showMenuBarIcon = false
        #expect(settings == expected)
        #expect(imported.skippedHotkeys.isEmpty)
    }

    @Test func hotkeysStoredAsDataAreReadAndCombinationsAreSkipped() throws {
        let rightOption = try JSONSerialization.data(withJSONObject: ["keyName": "Right Option", "keyCode": 61])
        let pasteLast = ["keys": [["keyName": "Control"], ["keyName": "Command"], ["keyName": "V"]]]
        let preferences = try JSONSerialization.data(withJSONObject: [
            "hotkeyDataArray": [rightOption.base64EncodedString(), pasteLast] as [Any],
        ])
        let imported = Willow.ImportedSettings(preferences: preferences, barEdgePosition: nil, showMenuBarIcon: nil)
        #expect(imported.hotkeys == [.rightOption])
        #expect(imported.skippedHotkeys == ["Control+Command+V"])
    }

    @Test func whatWillowDoesNotSayIsLeftAlone() {
        let imported = Willow.ImportedSettings(preferences: Data("{}".utf8), barEdgePosition: "middle", showMenuBarIcon: nil)
        #expect(imported.isEmpty)
        var settings = Settings()
        settings.barEdge = .top
        let before = settings
        imported.apply(to: &settings)
        #expect(settings == before)
        #expect(Willow.ImportedSettings(preferences: nil, barEdgePosition: nil, showMenuBarIcon: nil).isEmpty)
    }

    @Test func aClearedMicrophoneMeansTheSystemDefault() {
        let preferences = Data(#"{"selectedMicrophoneUID": null}"#.utf8)
        #expect(Willow.ImportedSettings(preferences: preferences, barEdgePosition: nil, showMenuBarIcon: nil).microphone
            == .systemDefault)
    }
}
