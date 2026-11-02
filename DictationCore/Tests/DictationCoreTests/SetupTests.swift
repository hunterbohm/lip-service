import Foundation
import Testing
@testable import DictationCore

private func plan(_ json: JSONValue, from settings: Settings = Settings()) -> Result<SetupPlan, SetupInvalid> {
    SetupSpec.plan(json.data(), from: settings)
}

private func applied(_ json: JSONValue, from settings: Settings = Settings()) throws -> SetupPlan {
    switch plan(json, from: settings) {
    case .success(let plan): return plan
    case .failure(let invalid): throw invalid
    }
}

private func problems(_ json: JSONValue, from settings: Settings = Settings()) -> [String] {
    if case .failure(let invalid) = plan(json, from: settings) { invalid.problems } else { [] }
}

private let hermesInput: JSONValue = [
    "agents": [["preset": "hermes", "name": "Hermes", "host": "mini", "spokenNames": ["Hermes", "Herm"],
                "destination": ["kind": "iMessage", "handle": "+1 415 555 0182"]]],
    "defaultAgent": "hermes",
    "voiceNotes": "Short and direct. Lowercase in chats.",
    "profiles": ["messages": ["style": "veryCasual", "pressReturn": true], "workChat": ["style": "veryCasual"], "email": ["style": "formal"]],
]

@Suite("Setup by the user's agent") struct SetupApplyTests {
    @Test func aFullSetupIsAppliedAndDescribedInPlainWords() throws {
        let result = try applied(hermesInput)
        let agent = try #require(result.settings.agents.current)
        #expect(agent.id == "hermes" && agent.presetID == "hermes" && agent.remoteHost == "mini")
        #expect(agent.spokenNames == ["Hermes", "Herm"])
        #expect(agent.destination == .iMessage(handle: "+1 415 555 0182"))
        #expect(result.settings.agents.voiceNotes == "Short and direct. Lowercase in chats.")
        #expect(result.settings.profiles.rules[.messages] == ProfileRules(style: .veryCasual, pressReturn: true))
        #expect(result.settings.profiles.rules[.workChat] == ProfileRules(style: .veryCasual))
        #expect(result.changes == [
            "Ghostwrite writes with Hermes on mini",
            "Hand offs go to Hermes in iMessage",
            "Your voice: “Short and direct. Lowercase in chats.”",
            "Messages: very casual, and Return is pressed for you",
            "Work chat: very casual",
        ])
    }

    @Test func aFieldLeftOutStaysAsItIs() throws {
        var start = try applied(hermesInput).settings
        start.agents.includeWindowText = true
        let result = try applied(["reviewFirst": false], from: start)
        #expect(result.changes == ["Drafts are typed straight away"])
        var expected = start
        expected.agents.reviewFirst = false
        #expect(result.settings == expected)
    }

    @Test func partialAgentFieldsKeepTheRest() throws {
        let start = try applied(hermesInput).settings
        let result = try applied(["agents": [["id": "hermes", "host": .null]]], from: start)
        let agent = try #require(result.settings.agents.agent(id: "hermes"))
        #expect(agent.remoteHost == nil && agent.destination == .iMessage(handle: "+1 415 555 0182") && agent.spokenNames == ["Hermes", "Herm"])
        #expect(result.changes == ["Hermes runs on this Mac"])
    }

    @Test func aSecondAgentIsAddedWithoutTakingOverTheDefault() throws {
        let start = try applied(hermesInput).settings
        let result = try applied(["agents": [["preset": "claude"]]], from: start)
        #expect(result.settings.agents.agents.map(\.id) == ["hermes", "claude"] && result.settings.agents.current?.id == "hermes")
        #expect(result.changes == ["Added Claude Code", "Claude Code hand offs go to a new T3 Code thread"])
    }

    @Test func aNewAgentWhenNoneIsSetUpBecomesTheDefault() throws {
        let result = try applied(["agents": [["preset": "codex"]]])
        #expect(result.settings.agents.defaultAgent == "codex")
        #expect(result.changes.first == "Ghostwrite writes with Codex")
    }

    @Test func aCustomAgentNeedsAnIdOrGetsOne() throws {
        let result = try applied(["agents": [["preset": "custom", "id": "mine", "name": "Mine", "command": ["mine", "acp"]]]])
        #expect(result.settings.agents.agent(id: "mine")?.command == ["mine", "acp"])
        #expect(problems(["agents": [["preset": "custom", "id": "mine"]]]).contains { $0.contains("no command") })
    }

    @Test func settingTheSameThingAgainChangesNothing() throws {
        let start = try applied(hermesInput).settings
        let again = try applied(hermesInput, from: start)
        #expect(again.changes.isEmpty && again.settings == start)
    }

    @Test func whatShowPrintsCanBeSentBackWithoutAChange() throws {
        var start = try applied(hermesInput).settings
        start.profiles.set(ProfileRules(style: .casual, pressReturn: false), for: .everythingElse)
        let shown = SetupSpec.show(start, found: ["hermes", "claude"])
        let again = try applied(shown, from: start)
        #expect(again.changes.isEmpty && again.settings == start)
    }

    @Test func theKeysAreWrittenTheWayTheyAreShown() throws {
        let result = try applied(["keys": ["ghostwrite": "Right Option", "handOff": .null]])
        #expect(result.settings.ghostwriteKey == Shortcut.parse("Right Option") && result.settings.handOffKey == nil)
        #expect(result.changes == ["Ghostwrite key: Right Option", "Hand off key: off"])
        let defaults = Settings()
        #expect(Shortcut.parse(try #require(defaults.ghostwriteKey).title) == defaults.ghostwriteKey)
        #expect(Shortcut.parse("option+fn") == defaults.handOffKey && Shortcut.parse("ctrl fn") == defaults.ghostwriteKey)
        #expect(Shortcut.parse("⌃⌘V") == Shortcut.pasteLast && Shortcut.parse("nonsense") == nil)
    }
}

@Suite("Setup that is refused") struct SetupInvalidTests {
    @Test func everythingWrongIsReportedAndNothingChanges() {
        let start = Settings()
        let bad: JSONValue = [
            "agents": [["preset": "nope"], ["preset": "hermes", "destination": ["kind": "carrierPigeon"]], ["name": "No preset"]],
            "defaultAgent": "ghost", "reviewFirst": "yes",
            "profiles": ["messages": ["style": "shouty"], "lounge": ["style": "formal"], "everythingElse": ["pressReturn": true]],
            "keys": ["ghostwrite": "banana", "dictation": ["Right Option"]],
            "colour": "red",
        ]
        guard case .failure(let invalid) = plan(bad, from: start) else { Issue.record("accepted"); return }
        let text = invalid.problems.joined(separator: "\n")
        for fragment in ["agents[0].preset \"nope\"", "agents[1].destination.kind \"carrierPigeon\"", "agents[2] is a new agent", "defaultAgent \"ghost\"",
                         "reviewFirst must be true or false", "profiles.messages.style \"shouty\"", "Unknown field \"profiles.lounge\"",
                         "profiles.everythingElse.pressReturn", "keys.ghostwrite \"banana\"", "keys.dictation can't be changed",
                         "Unknown field \"colour\""] {
            #expect(text.contains(fragment), "\(fragment)")
        }
    }

    @Test func aGoodFieldNextToABadOneIsNotApplied() {
        let result = plan(["reviewFirst": false, "profiles": ["messages": ["style": "shouty"]]])
        guard case .failure = result else { Issue.record("accepted"); return }
    }

    @Test func notJSONIsRefused() {
        guard case .failure(let invalid) = SetupSpec.plan(Data("not json".utf8), from: Settings()) else { Issue.record("accepted"); return }
        #expect(invalid.problems.count == 1)
        guard case .failure = SetupSpec.plan(Data("[1]".utf8), from: Settings()) else { Issue.record("accepted an array"); return }
    }

    @Test func aKeyThatClashesWithADictationKeyIsRefused() {
        #expect(problems(["keys": ["ghostwrite": "fn"]]).contains { $0.contains("already a dictation key") })
    }

    @Test func destinationsWithSecretsAreNeverMadeHere() {
        #expect(problems(["agents": [["preset": "hermes", "destination": ["kind": "slack"]]]]).contains { $0.contains("holds a secret") })
        #expect(problems(["agents": [["preset": "hermes", "destination": ["kind": "webhook", "url": "https://x.example"]]]]).contains { $0.contains("holds a secret") })
    }
}

@Suite("Setup never touches secrets") struct SetupSecretsTests {
    private func withSecrets() -> Settings {
        var settings = Settings()
        var slack = AgentPreset.with(id: "hermes")!.connection()
        slack.destination = .slack(team: "acme", botUserID: "U0123", tokenKey: "slack-TOKENKEY123")
        var discord = AgentPreset.with(id: "claude")!.connection()
        discord.destination = .discord(webhookKey: "discord-WEBHOOKKEY456", botID: "B9")
        var hook = AgentPreset.with(id: "codex")!.connection()
        hook.destination = .webhook(url: "https://hooks.example.com/services/T000/B000/SECRETPATH", secretKey: "webhook-SIGNKEY789")
        settings.agents.agents = [slack, discord, hook]
        return settings
    }

    @Test func showPrintsNoSecretAndNoKeychainName() {
        let printed = String(decoding: SetupSpec.show(withSecrets(), found: []).data(), as: UTF8.self)
        for secret in ["TOKENKEY123", "WEBHOOKKEY456", "SIGNKEY789", "SECRETPATH", "hooks.example.com", "xoxp"] {
            #expect(!printed.contains(secret), "\(secret)")
        }
        #expect(printed.contains("\"kind\":\"slack\"") && printed.contains("\"kind\":\"webhook\""))
    }

    @Test func sendingShowBackLeavesTheSecretDestinationsAlone() throws {
        let start = withSecrets()
        let again = try applied(SetupSpec.show(start, found: []), from: start)
        #expect(again.settings == start && again.changes.isEmpty)
    }

    @Test func aSecretDestinationCannotBeEditedFromHere() {
        #expect(problems(["agents": [["id": "hermes", "destination": ["kind": "slack", "team": "other"]]]], from: withSecrets()).contains { $0.contains("holds a secret") })
    }
}

@Suite("Setup undo") struct SetupUndoTests {
    @Test func undoPutsBackWhatTheAgentChangedAndNothingElse() throws {
        var start = Settings()
        start.agents.voiceNotes = "old notes"
        start.profiles.set(ProfileRules(style: .formal), for: .messages)
        let result = try applied(hermesInput, from: start)
        let record = SetupRecord(by: "Claude Code", changes: result.changes, previous: start.setupFields)
        var later = result.settings
        later.microphone = .device(uid: "u", name: "Shure")
        let restored = record.undo(later)
        #expect(restored.setupFields == start.setupFields)
        #expect(restored.microphone == later.microphone)
        #expect(restored.agents == start.agents && restored.agents.agents.isEmpty)
    }

    @Test func undoNeverGivesBackAKeyThatPasteLastTookSince() throws {
        var start = Settings()
        let freed = Shortcut(key: 5, modifiers: [.control, .command])
        #expect(start.setAgentKey(.ghostwrite, freed) == nil)
        var after = start
        #expect(after.setAgentKey(.ghostwrite, Shortcut(key: 38, modifiers: [.control, .command])) == nil)
        let record = SetupRecord(by: "Hermes", changes: ["Ghostwrite key"], previous: start.setupFields)
        #expect(after.setPasteLast(freed) == nil, "the setup freed it")
        let restored = record.undo(after)
        #expect(restored.pasteLast == freed)
        #expect(restored.ghostwriteKey != freed && restored.ghostwriteKey == after.ghostwriteKey)
    }

    @Test func aRecordSurvivesBeingStored() throws {
        let start = Settings()
        let result = try applied(hermesInput, from: start)
        let record = SetupRecord(by: "Hermes", changes: result.changes, previous: start.setupFields)
        let read = try JSONDecoder().decode(SetupRecord.self, from: JSONEncoder().encode(record))
        #expect(read == record && read.title == "Hermes set up Lip Service")
        #expect(read.undo(result.settings).setupFields == start.setupFields)
    }

    @Test func withoutAnAgentNameItIsYourAgent() {
        #expect(SetupRecord(by: nil, changes: [], previous: Settings().setupFields).title == "Your agent set up Lip Service")
        #expect(SetupRecord(by: "  ", changes: [], previous: Settings().setupFields).by == "Your agent")
    }
}

@Suite("Old settings still load") struct SettingsWithoutDisclosureTests {
    @Test func aStoredValueFromBeforeTheCardWasRemovedStillReads() throws {
        let stored = """
            {"agents":{"agents":[{"id":"hermes","name":"Hermes","presetID":"hermes","command":["hermes","acp"],"spokenNames":["Hermes"],
            "draftOptions":[],"taskOptions":[],"destination":{"agentReply":{}}}],"defaultAgent":"hermes","reviewFirst":false,
            "voiceNotes":"short","disclosed":["hermes"]},"sounds":false}
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(stored.utf8))
        #expect(settings.agents.current?.id == "hermes" && settings.agents.reviewFirst == false && settings.agents.voiceNotes == "short")
        #expect(settings.sounds == false)
        #expect(!String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("disclosed"))
    }
}

@Suite("Setup prompt") struct SetupPromptTests {
    @Test func theSameStringCarriesThePathIntoEveryCommand() {
        let path = "/Applications/Lip Service.app/Contents/MacOS/Dictation"
        let prompt = SetupPrompt.text(executable: path)
        #expect(prompt.hasPrefix("Set up Lip Service for me. It's the dictation app on this Mac."))
        #expect(prompt.contains("1. Run: \"\(path)\" setup show"))
        #expect(prompt.contains("setup apply --by \"<your name>\", with the JSON on stdin."))
        #expect(prompt.contains("5. Run \"\(path)\" setup test, and tell me what it says."))
        #expect(prompt.components(separatedBy: "\"\(path)\"").count == 4)
    }
}

@Suite("Setup notice on the bar") struct SetupNoticeTests {
    @Test func theBarNamesTheAgentAndOffersUndo() {
        let notice = BarNotice.setupApplied(by: "Claude Code", changes: 4)
        #expect(notice.title == "Claude Code set up Lip Service" && notice.detail == "4 changes. Open Lip Service to see them.")
        #expect(notice.action == .undoSetup && BarToastAction.undoSetup.title == "Undo" && notice.tone == .info)
        #expect(BarNotice.setupApplied(by: "Your agent", changes: 1).detail == "1 change. Open Lip Service to see it.")
    }
}
