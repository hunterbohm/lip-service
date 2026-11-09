import Foundation
import Testing
@testable import DictationCore

@Suite("Talk thread") struct TalkThreadTests {
    private func initialize(_ capabilities: JSONValue) -> JSONValue { ["protocolVersion": 1, "agentCapabilities": capabilities] }

    @Test func anAgentSaysAtStartWhetherItCanOpenASessionAgain() {
        // Hermes and Claude Code both say both.
        let both = AgentAbilities.parse(initialize(["loadSession": true, "sessionCapabilities": ["fork": [:], "list": [:], "resume": [:]]]))
        #expect(both == AgentAbilities(resumes: true, loads: true))
        #expect(both.reopenMethod == "session/resume")
        let loadOnly = AgentAbilities.parse(initialize(["loadSession": true]))
        #expect(loadOnly == AgentAbilities(resumes: false, loads: true))
        #expect(loadOnly.reopenMethod == "session/load")
        let neither = AgentAbilities.parse(initialize([:]))
        #expect(!neither.continues && neither.reopenMethod == nil)
        #expect(!AgentAbilities.parse(initialize(["loadSession": false, "sessionCapabilities": ["resume": .null]])).continues)
        #expect(!AgentAbilities.parse(.null).continues)
    }

    @Test func theRequestCarriesTheIdTheFolderAndTheServers() {
        let server = ACP.stdioServer(name: "t3", command: "/bin/x", args: [])
        #expect(ACP.reopenSession("s-1", cwd: "/tmp", mcpServers: [server])
            == ["sessionId": "s-1", "cwd": "/tmp", "mcpServers": [server]])
        #expect(ACP.reopenSession("s-1", cwd: "/tmp")["mcpServers"] == [])
    }

    @Test func theAnswerSaysWhichSessionTheTalkIsIn() {
        let settings: [String: JSONValue] = ["configOptions": [["id": "model", "name": "Model", "currentValue": "fast", "options": []]],
                                             "models": ["currentModelId": "fast", "availableModels": [["modelId": "fast", "name": "Fast"]]]]
        // No id in the answer: the session asked for, with the settings it reports.
        let first = ReopenAnswer.read(.object(settings), method: "session/resume", asked: "old")
        guard case .same(let same) = first else { Issue.record("not the same session"); return }
        #expect(same.id == "old" && same.options.first?.id == "model" && same.currentModel == "fast")
        // Hermes names the session it opened for an id it doesn't know, in its own metadata.
        var replaced = settings
        replaced["_meta"] = ["hermes": ["sessionProvenance": ["acpSessionId": "new", "currentHermesSessionId": "inner"]]]
        let moved = ReopenAnswer.read(.object(replaced), method: "session/resume", asked: "old")
        guard case .replaced(let other) = moved else { Issue.record("not a replaced session"); return }
        #expect(other.id == "new")
        // The same id in its metadata is the same session, as after a compression moved Hermes's inner session.
        replaced["_meta"] = ["hermes": ["sessionProvenance": ["acpSessionId": "old", "currentHermesSessionId": "inner"]]]
        #expect(ReopenAnswer.read(.object(replaced), method: "session/resume", asked: "old") == .same(same))
        // Another agent names it in sessionId.
        let elsewhere = ReopenAnswer.read(["sessionId": "else"], method: "session/resume", asked: "old")
        guard case .replaced(let named) = elsewhere else { Issue.record("not a replaced session"); return }
        #expect(named.id == "else")
        // Hermes's load says null for a session it lost.
        #expect(ReopenAnswer.read(.null, method: "session/load", asked: "old") == .missing)
        #expect(ReopenAnswer.read([:], method: "session/load", asked: "old") == .same(SessionInfo(id: "old", options: [], models: [], currentModel: nil)))
    }

    @Test func aTalkGoesOnOnlyWhenEverythingAllowsIt() {
        let can = AgentAbilities(resumes: true, loads: true)
        #expect(TalkOpen.plan(continues: true, abilities: can, remembered: "s") == .resume("s"))
        #expect(TalkOpen.plan(continues: true, abilities: AgentAbilities(loads: true), remembered: "s") == .resume("s"))
        // The agent isn't set to carry on, or can't, or there is nothing to go on in: a new session, as every talk was.
        #expect(TalkOpen.plan(continues: false, abilities: can, remembered: "s") == .new)
        #expect(TalkOpen.plan(continues: true, abilities: AgentAbilities(), remembered: "s") == .new)
        #expect(TalkOpen.plan(continues: true, abilities: can, remembered: nil) == .new)
        #expect(TalkOpen.plan(continues: true, abilities: can, remembered: "") == .new)
    }

    @Test func aSessionIsRememberedPerAgentAndOnlyForTheCommandThatMadeIt() {
        var threads = TalkThreads()
        #expect(threads.session(for: "hermes", launch: "exec hermes acp") == nil)
        let added = threads.remember("s-1", for: "hermes", launch: "exec hermes acp")
        let again = threads.remember("s-1", for: "hermes", launch: "exec hermes acp")
        #expect(added)
        #expect(!again, "nothing changed, nothing to save")
        #expect(threads.session(for: "hermes", launch: "exec hermes acp") == "s-1")
        #expect(threads.session(for: "claude", launch: "exec hermes acp") == nil)
        // Another machine or command made a different set of ids.
        #expect(threads.session(for: "hermes", launch: "exec ssh mini hermes acp") == nil)
        let replaced = threads.remember("s-2", for: "hermes", launch: "exec hermes acp")
        #expect(replaced)
        #expect(threads.session(for: "hermes", launch: "exec hermes acp") == "s-2")
        let forgot = threads.forget(agent: "hermes")
        let forgotTwice = threads.forget(agent: "hermes")
        #expect(forgot)
        #expect(!forgotTwice)
        #expect(threads.session(for: "hermes", launch: "exec hermes acp") == nil)
    }

    /// Hermes's iMessage chat has no timer, and neither does this: the file holds nothing that could age out.
    @Test func theThreadHasNoClockSoItNeverExpires() throws {
        var threads = TalkThreads()
        threads.remember("s-1", for: "hermes", launch: "exec hermes acp")
        let object = try #require(JSONSerialization.jsonObject(with: threads.encoded()) as? [String: Any])
        let entry = try #require((object["entries"] as? [String: Any])?["hermes"] as? [String: Any])
        #expect(Set(entry.keys) == ["session", "launch"])
        #expect(TalkThreads.decode(threads.encoded()).session(for: "hermes", launch: "exec hermes acp") == "s-1")
    }

    @Test func aFileThatIsNotReadableIsNoMemory() {
        #expect(TalkThreads.decode(Data()) == TalkThreads())
        #expect(TalkThreads.decode(Data("not json".utf8)) == TalkThreads())
        #expect(TalkThreads.decode(Data(#"{"entries":{"a":{"session":"s","launch":"l"},"b":{"session":5}}}"#.utf8)).entries.keys.sorted() == ["a"])
    }

    @Test func onlyHermesCarriesOnByDefaultAndAnOldSaveGetsTheDefault() throws {
        #expect(AgentPreset.with(id: "hermes")!.connection().continuesTalks)
        for preset in AgentPreset.all where preset.id != "hermes" { #expect(!preset.connection().continuesTalks, "\(preset.id)") }
        let old = #"{"id":"hermes","name":"Hermes","presetID":"hermes","command":["hermes","acp"],"spokenNames":["Hermes"],"draftOptions":[],"#
            + #""taskOptions":[],"destination":{"agentReply":{}}}"#
        var agent = try JSONDecoder().decode(AgentConnection.self, from: Data(old.utf8))
        #expect(agent.continuesTalks)
        agent.continuesTalks = false
        #expect(try JSONDecoder().decode(AgentConnection.self, from: JSONEncoder().encode(agent)).continuesTalks == false)
    }
}
