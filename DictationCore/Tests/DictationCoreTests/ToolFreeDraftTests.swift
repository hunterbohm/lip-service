import Foundation
import Testing
@testable import DictationCore

@Suite("Tool-free drafts") struct ToolFreeDraftTests {
    @Test func claudeStartsDraftsWithNoToolsAndNoOutsideMCPServers() throws {
        let draft = ToolFreeDraft.forPreset("claude")
        let params = ACP.newSession(cwd: "/tmp/x", meta: draft.sessionMeta)
        let sent = String(decoding: params.data(), as: UTF8.self)
        #expect(sent == #"{"_meta":{"claudeCode":{"options":{"strictMcpConfig":true,"tools":[]}}},"cwd":"/tmp/x","mcpServers":[]}"#)
        #expect(draft.choices.isEmpty)
    }

    @Test func codexStartsDraftsInItsReadOnlyMode() {
        let draft = ToolFreeDraft.forPreset("codex")
        #expect(draft.sessionMeta == nil)
        #expect(draft.choices == [.option(id: "mode", value: "read-only")])
        let call = ACP.set(draft.choices[0], session: "s1")
        #expect(call.method == "session/set_config_option")
        #expect(call.params == ["sessionId": "s1", "configId": "mode", "value": "read-only"])
    }

    @Test func aSessionWithoutMetaSendsNoMetaKey() {
        #expect(ACP.newSession(cwd: "/tmp/x") == ["cwd": "/tmp/x", "mcpServers": []])
        #expect(ACP.newSession(cwd: "/tmp/x").data() == ACP.newSession(cwd: "/tmp/x", meta: ToolFreeDraft.forPreset("hermes").sessionMeta).data())
    }

    @Test func agentsWithNoSwitchAskForNothing() {
        for id in ["hermes", "opencode", "gemini", "custom", "no-such-preset"] {
            #expect(ToolFreeDraft.forPreset(id) == .none, "\(id)")
        }
    }

    @Test func everyKeyIsAPreset() {
        let ids = Set(AgentPreset.all.map(\.id))
        #expect(Set(ToolFreeDraft.byPreset.keys).isSubset(of: ids))
    }

    @Test func aConnectionSavedByAnEarlierVersionStillGetsItFromItsPreset() throws {
        var saved = AgentPreset.with(id: "codex")!.connection()
        saved.draftOptions = [.model("gpt-6-luna[low]")]
        let stored = try JSONDecoder().decode(AgentConnection.self, from: JSONEncoder().encode(saved))
        #expect(stored.toolFreeDraft == ToolFreeDraft.forPreset("codex"))
        #expect(AgentPreset.with(id: "claude")!.connection().toolFreeDraft.sessionMeta != nil)
        #expect(AgentPreset.with(id: "hermes")!.connection().toolFreeDraft == .none)
    }

    @Test func theSavedDraftOptionsAreLeftAlone() {
        for preset in AgentPreset.all {
            #expect(preset.connection().draftOptions == preset.draftOptions, "\(preset.id)")
        }
    }

    @Test func aDraftStopsAtTheFirstToolAndCountsTheRest() {
        var stop = ToolStop()
        let beforeTools = [stop.see(.message("Tuesday works.")), stop.see(.thought("hm")), stop.see(.other("plan"))]
        #expect(beforeTools == [false, false, false] && !stop.stopped)
        let first = stop.see(.tool(title: "Read ~/.ssh/id_ed25519", status: "pending"))
        #expect(first && stop.stopped)
        let second = stop.see(.tool(title: "Read ~/.ssh/id_ed25519", status: "completed"))
        #expect(!second && stop.tools == 2)
    }

    @Test func aToolCallAndItsUpdateBothReachTheStop() throws {
        func update(_ kind: String) throws -> SessionUpdate {
            try #require(SessionUpdate.parse(["sessionId": "s", "update": ["sessionUpdate": .string(kind), "title": "Run touch /tmp/x", "status": "pending"]])).update
        }
        var call = ToolStop(), later = ToolStop()
        let (first, second) = try (call.see(update("tool_call")), later.see(update("tool_call_update")))
        #expect(first && second)
    }

    @Test func theStopSaysWhichAgentAndWhy() {
        #expect(ToolStop.message(agent: "Hermes") == "Hermes tried to use a tool, so Lip Service stopped the draft. Drafts don't need tools.")
    }
}
