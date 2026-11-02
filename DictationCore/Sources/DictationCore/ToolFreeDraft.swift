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
