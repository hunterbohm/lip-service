import Foundation

/// What an agent said it can do when it started, beyond the basics: whether it can open an earlier session again.
public struct AgentAbilities: Equatable, Sendable {
    /// `sessionCapabilities.resume`: `session/resume` opens a stored session again and does not need it replayed.
    public var resumes: Bool
    /// `loadSession`: `session/load` opens a stored session again.
    public var loads: Bool

    public init(resumes: Bool = false, loads: Bool = false) { (self.resumes, self.loads) = (resumes, loads) }

    public static func parse(_ initializeResult: JSONValue) -> AgentAbilities {
        let capabilities = initializeResult["agentCapabilities"]
        let resume = capabilities?["sessionCapabilities"]?["resume"]
        return AgentAbilities(resumes: resume != nil && resume != .null && resume != .bool(false),
                              loads: capabilities?["loadSession"]?.bool == true)
    }

    /// The agent can open an earlier session again, one way or the other.
    public var continues: Bool { resumes || loads }

    /// The request that does it: `session/resume` when offered, since it asks for no replay, else `session/load`.
    public var reopenMethod: String? { resumes ? "session/resume" : loads ? "session/load" : nil }
}

/// What an agent answered when asked to open an earlier session.
public enum ReopenAnswer: Equatable, Sendable {
    /// The same session, carried on.
    case same(SessionInfo)
    /// The agent had no such session and opened another one instead, as Hermes's `session/resume` does for an id it
    /// doesn't know. The talk goes on in that one.
    case replaced(SessionInfo)
    /// The agent said it has no such session, as Hermes's `session/load` does with a null answer.
    case missing

    /// `result` is what the agent answered to `method` for the session `asked`. The agent names the session it opened
    /// in `sessionId`, or, for Hermes, in `_meta.hermes.sessionProvenance.acpSessionId`; with neither, it is the one asked.
    public static func read(_ result: JSONValue, method: String, asked: String) -> ReopenAnswer {
        if result == .null, method == "session/load" { return .missing }
        let named = result["sessionId"]?.string ?? result["_meta"]?["hermes"]?["sessionProvenance"]?["acpSessionId"]?.string
        let id = named.flatMap { $0.isEmpty ? nil : $0 } ?? asked
        let info = SessionInfo.parse(result, id: id) ?? SessionInfo(id: id, options: [], models: [], currentModel: nil)
        return id == asked ? .same(info) : .replaced(info)
    }
}

/// How a talk's session is opened: the one the last talk ended in, or a new one.
public enum TalkOpen: Equatable, Sendable {
    case resume(String)
    case new

    /// A talk picks up the last talk's session only when the agent is set to carry on, can open an earlier session, and
    /// there is one remembered. Anything else opens a new session, as every talk did before.
    public static func plan(continues: Bool, abilities: AgentAbilities, remembered: String?) -> TalkOpen {
        guard continues, abilities.continues, let remembered, !remembered.isEmpty else { return .new }
        return .resume(remembered)
    }
}

/// The session each agent's last talk ended in, so the next talk goes on in it, as one chat that never ends, like a
/// thread of messages with the agent.
///
/// There is no timer. Hermes's own iMessage chat starts a new conversation only on `/new` or `/reset`: its gateway
/// stopped rotating conversations on idle or daily timers (hermes-agent commit 1d5d059410, "stop time-triggered
/// conversation rotation"), and nothing under `session_reset` is read. A talk is the same: a day or a month later it
/// still opens the same session, until the user starts a new conversation.
public struct TalkThreads: Equatable, Codable, Sendable {
    public struct Entry: Equatable, Codable, Sendable {
        public var session: String
        /// The command that started the agent, with its host. A session id means something only to the agent that
        /// made it, so a changed command or machine starts a new conversation.
        public var launch: String
        public init(session: String, launch: String) { (self.session, self.launch) = (session, launch) }
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public func session(for agent: String, launch: String) -> String? {
        guard let entry = entries[agent], entry.launch == launch else { return nil }
        return entry.session
    }

    /// True when something changed, so the caller knows to save.
    @discardableResult public mutating func remember(_ session: String, for agent: String, launch: String) -> Bool {
        let entry = Entry(session: session, launch: launch)
        guard entries[agent] != entry else { return false }
        entries[agent] = entry
        return true
    }

    /// The next talk with this agent starts a new conversation. True when there was one to forget.
    @discardableResult public mutating func forget(agent: String) -> Bool { entries.removeValue(forKey: agent) != nil }

    /// A file that can't be read, or that holds something else, is no memory at all.
    public static func decode(_ data: Data) -> TalkThreads {
        (try? JSONDecoder().decode(LossyThreads.self, from: data))?.threads ?? TalkThreads()
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    private struct LossyThreads: Decodable {
        var threads: TalkThreads
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let raw = try container.decodeIfPresent([String: LossyEntry].self, forKey: .entries) ?? [:]
            threads = TalkThreads(entries: raw.compactMapValues(\.entry))
        }
        enum Key: String, CodingKey { case entries }
    }

    private struct LossyEntry: Decodable {
        var entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }
}
