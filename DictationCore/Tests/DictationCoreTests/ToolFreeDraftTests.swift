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
}
