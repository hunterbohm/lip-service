import Foundation

/// What to send an agent so a draft session starts with no tools. A draft only turns words and window text into text,
/// and the window text is untrusted, so an agent that can switch its tools off is asked to. Looked up by the
/// connection's preset id each time a draft session opens, so agents set up in earlier versions get it too.
public struct ToolFreeDraft: Equatable, Sendable {
    /// Sent as `_meta` in `session/new`, for an agent that reads its tool switch from there.
    public var sessionMeta: JSONValue?
    /// Set after the session opens and after the draft options, so nothing the user chose can undo them.
    public var choices: [ConfigChoice]

    public init(sessionMeta: JSONValue? = nil, choices: [ConfigChoice] = []) {
        (self.sessionMeta, self.choices) = (sessionMeta, choices)
    }

    public static let none = ToolFreeDraft()

    /// Hermes, OpenCode, Gemini and custom agents have no switch (OpenCode's modes depend on each user's plugins), so
    /// a draft there relies on refusing every permission and stopping at the first tool.
    public static let byPreset: [String: ToolFreeDraft] = [
        // `tools: []` turns off every built-in tool; `strictMcpConfig` keeps the user's own MCP servers out.
        "claude": ToolFreeDraft(sessionMeta: ["claudeCode": ["options": ["tools": [], "strictMcpConfig": true]]]),
        // The read-only sandbox has the network off and asks before anything else.
        "codex": ToolFreeDraft(choices: [.option(id: "mode", value: "read-only")]),
    ]

    public static func forPreset(_ id: String) -> ToolFreeDraft { byPreset[id] ?? .none }
}

extension AgentConnection {
    public var toolFreeDraft: ToolFreeDraft { ToolFreeDraft.forPreset(presetID) }
}

/// A draft needs no tools, so the first one an agent starts ends the draft. Not every agent can switch its tools off,
/// and one that runs tools without asking has already started by the time Lip Service hears of it.
public struct ToolStop: Equatable, Sendable {
    /// Tool updates seen so far, counting an agent's later updates for the same call.
    public private(set) var tools = 0

    public init() {}

    public var stopped: Bool { tools > 0 }

    /// Takes in one update from the agent. True for the first tool, the one that stops the draft.
    public mutating func see(_ update: SessionUpdate) -> Bool {
        guard case .tool = update else { return false }
        tools += 1
        return tools == 1
    }

    public static func message(agent: String) -> String {
        "\(agent) tried to use a tool, so Lip Service stopped the draft. Drafts don't need tools."
    }
}
