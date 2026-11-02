import Foundation
import Testing
@testable import DictationCore

@Suite("App profiles") struct ProfilesTests {
    private static let terms = ["ProfitPilot", "T3 Code", "Siobhan"]

    @Test func formalKeepsTheCleanedText() {
        let text = "Sounds good. Ask Siobhan on Friday."
        #expect(WritingStyle.formal.apply(text, keeping: Self.terms) == text)
    }

    @Test func casualDropsOnlyTheFinalPeriod() {
        #expect(WritingStyle.casual.apply("Sounds good. See you soon.", keeping: []) == "Sounds good. See you soon")
        #expect(WritingStyle.casual.apply("Can we move dinner to seven?", keeping: []) == "Can we move dinner to seven?")
        #expect(WritingStyle.casual.apply("That was close!", keeping: []) == "That was close!")
        #expect(WritingStyle.casual.apply("Well...", keeping: []) == "Well...")
    }

    @Test func aFinalAbbreviationKeepsItsPeriod() {
        #expect(WritingStyle.casual.apply("We met in the U.S.", keeping: []) == "We met in the U.S.")
        #expect(WritingStyle.casual.apply("Bring snacks, drinks, etc.", keeping: []) == "Bring snacks, drinks, etc.")
        #expect(WritingStyle.casual.apply("Use a short one, e.g.", keeping: []) == "Use a short one, e.g.")
        #expect(WritingStyle.casual.apply("Call me at 5 p.m.", keeping: []) == "Call me at 5 p.m.")
        #expect(WritingStyle.casual.apply("That is it.", keeping: []) == "That is it")
        #expect(WritingStyle.veryCasual.apply("Pick the cheap one, i.e. the first.", keeping: []) == "pick the cheap one, i.e. the first")
        #expect(WritingStyle.veryCasual.apply("Pick the cheap one, i.e.", keeping: []) == "pick the cheap one, i.e.")
    }

    @Test func veryCasualKeepsOnlyExactDictionarySpellings() {
        #expect(WritingStyle.veryCasual.apply("I have a vague notion.", keeping: ["Notion"]) == "I have a vague notion")
        #expect(WritingStyle.veryCasual.apply("Open Notion.", keeping: ["Notion"]) == "open Notion")
    }

    @Test func pasteLastPutsASnippetInExactlyAsSaved() {
        let snippet = Insertion(text: "  Best,\nHunter", pressReturn: true, source: .snippet)
        #expect(snippet.again == Insertion(text: "  Best,\nHunter", source: .snippet))
        #expect(Insertion(text: "Hi there", pressReturn: true, source: .dictation).again == Insertion(text: "Hi there", source: .pasteLast))
    }

    @Test func oneBadStoredEntryDropsOnlyItself() throws {
        let json = #"{"rules": {"email": {"style": "loud", "pressReturn": true}, "messages": {"style": "veryCasual"}}, "apps": [{"bundleID": "a.b", "name": "AB", "group": "email"}, {"bundleID": 7}, {"bundleID": "c.d", "name": "CD", "group": "nowhere"}]}"#
        let profiles = try JSONDecoder().decode(AppProfiles.self, from: Data(json.utf8))
        #expect(profiles.rules[.email] == ProfileRules(style: .formal))
        #expect(profiles.rules[.messages] == ProfileRules(style: .veryCasual, pressReturn: false))
        #expect(profiles.apps == [ProfileApp(bundleID: "a.b", name: "AB", group: .email)])
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"snippets": [{"id": "x"}, {"id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF", "cue": "sig", "text": "Best"}], "hotkeys": ["fn", "bogus"]}"#.utf8))
        #expect(settings.snippets.map(\.cue) == ["sig"])
        #expect(settings.hotkeys.count == 1)
    }

    @Test func veryCasualLowercasesAllButDictionaryWordsAndI() {
        #expect(WritingStyle.veryCasual.apply("Ask Siobhan whether I can open ProfitPilot in T3 Code on Friday.", keeping: Self.terms)
            == "ask Siobhan whether I can open ProfitPilot in T3 Code on friday")
        #expect(WritingStyle.veryCasual.apply("I'm in. Are you?", keeping: Self.terms) == "I'm in. are you?")
        #expect(WritingStyle.veryCasual.apply("OK, that works!", keeping: Self.terms) == "ok, that works!")
    }

    @Test func listedUnlistedAndWildcardAppsFindTheirGroup() {
        let profiles = AppProfiles.defaults
        #expect(profiles.group(for: "com.apple.MobileSMS") == .messages)
        #expect(profiles.group(for: "com.tinyspeck.slackmacgap") == .workChat)
        #expect(profiles.group(for: "com.apple.mail") == .email)
        #expect(profiles.group(for: "com.t3tools.t3code") == .aiAndCode)
        #expect(profiles.group(for: "com.t3tools.t3code.nightly") == .aiAndCode)
        #expect(profiles.group(for: "com.anysphere.cursor") == .aiAndCode)
        #expect(profiles.group(for: "md.obsidian") == .everythingElse)
        #expect(profiles.group(for: nil) == .everythingElse)
        #expect(profiles.rules(for: "md.obsidian") == ProfileRules(style: .formal, pressReturn: false))
        #expect(profiles.rules(for: "com.apple.MobileSMS") == ProfileRules(style: .casual, pressReturn: false))
    }

    @Test func anExactIDWinsOverAWildcard() {
        var profiles = AppProfiles.defaults
        profiles.add(ProfileApp(bundleID: "com.t3tools.t3code.nightly", name: "T3 Code Nightly", group: .messages))
        #expect(profiles.group(for: "com.t3tools.t3code.nightly") == .messages)
        #expect(profiles.group(for: "com.t3tools.t3code") == .aiAndCode)
    }

    @Test func anAppSitsInOneGroupOnly() {
        var profiles = AppProfiles.defaults
        profiles.add(ProfileApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", group: .messages))
        #expect(profiles.apps(in: .workChat).map(\.bundleID) == ["com.microsoft.teams2", "com.microsoft.teams"])
        #expect(profiles.group(for: "com.tinyspeck.slackmacgap") == .messages)
        profiles.add(ProfileApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", group: .everythingElse))
        #expect(profiles.group(for: "com.tinyspeck.slackmacgap") == .everythingElse)
        #expect(profiles.apps(in: .everythingElse).isEmpty)
        profiles.remove("com.apple.mail")
        #expect(profiles.group(for: "com.apple.mail") == .everythingElse)
    }

    @Test func oldSettingsGetTheDefaultProfiles() throws {
        let stored = try JSONDecoder().decode(Settings.self, from: Data(#"{"sounds": false, "smartSpacing": true}"#.utf8))
        #expect(stored.profiles == .defaults)
    }

    @Test func profilesSurviveAStoreAndARead() throws {
        var settings = Settings()
        settings.profiles.set(ProfileRules(style: .veryCasual, pressReturn: true), for: .messages)
        settings.profiles.add(ProfileApp(bundleID: "md.obsidian", name: "Obsidian", group: .email))
        let read = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(read.profiles == settings.profiles)
        #expect(read.profiles.rules(for: "com.hnc.Discord") == ProfileRules(style: .veryCasual, pressReturn: true))
    }

    @Test func aStoredValueMissingAGroupTakesThatGroupsDefault() throws {
        let json = #"{"rules": {"email": {"style": "casual", "pressReturn": true}}, "apps": [{"bundleID": "a.b", "name": "AB", "group": "email"}, {"bundleID": "A.B", "name": "Again", "group": "messages"}]}"#
        let profiles = try JSONDecoder().decode(AppProfiles.self, from: Data(json.utf8))
        #expect(profiles.rules[.email] == ProfileRules(style: .casual, pressReturn: true))
        #expect(profiles.rules[.messages] == ProfileRules(style: .casual))
        #expect(profiles.apps == [ProfileApp(bundleID: "A.B", name: "Again", group: .messages)])
    }

    @Test func anInsertionTakesItsAppsStyleAndReturn() {
        var settings = Settings()
        settings.profiles.set(ProfileRules(style: .veryCasual, pressReturn: true), for: .messages)
        let configuration = Configuration(settings: settings, vocabulary: Vocabulary(terms: [.init(text: "Siobhan")]), issues: [])
        #expect(Insertion.make("Tell Siobhan I said hi.", app: "com.apple.MobileSMS", configuration: configuration)
            == Insertion(text: "tell Siobhan I said hi", pressReturn: true, source: .dictation))
        #expect(Insertion.make("Tell Siobhan I said hi.", app: "md.obsidian", configuration: configuration)
            == Insertion(text: "Tell Siobhan I said hi.", pressReturn: false, source: .dictation))
    }
}

@Suite("Term casing") struct TermCasingTests {
    private static let vocabulary = Vocabulary(terms: [.init(text: "Notion"), .init(text: "Hermes")])

    @Test func anEverydayWordKeepsItsCaseUnlessBoostingPutTheTermIn() {
        let finisher = TextFinisher(vocabulary: Self.vocabulary, everydayWords: ["notion"])
        #expect(finisher.finish(raw: "I have a vague notion about hermes", boosted: nil) == "I have a vague notion about Hermes.")
        #expect(finisher.finish(raw: "Put it in note on", boosted: "Put it in Notion") == "Put it in Notion.")
    }
}
