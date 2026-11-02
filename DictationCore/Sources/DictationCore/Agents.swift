import Foundation

/// One setting sent to an agent's session before a prompt: a config option set to a value, or, for agents that only
/// support it, a model picked with `session/set_model`. Applied in order, since switching some agents' model resets
/// their effort.
public enum ConfigChoice: Equatable, Hashable, Codable, Sendable {
    case option(id: String, value: String)
    case model(String)
}

/// The agents Lip Service knows how to start. A table, so adding one is a row.
public struct AgentPreset: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The program the command runs, checked on the login shell's PATH to tell whether the agent is installed.
    public var program: String
    public var command: [String]
    /// Without a host, `command` runs here; with one, `ssh HOST` runs `remoteCommand`.
    public var remoteCommand: [String]?
    public var draftOptions: [ConfigChoice]
    public var taskOptions: [ConfigChoice]
    public var spokenNames: [String]
    public var destination: Destination

    public static let all: [AgentPreset] = [
        AgentPreset(id: "hermes", name: "Hermes", program: "hermes", command: ["hermes", "acp"], remoteCommand: ["hermes", "acp"],
                    draftOptions: [.option(id: "model", value: "anthropic:claude-haiku-5-5"), .option(id: "reasoning_effort", value: "low")],
                    taskOptions: [], spokenNames: ["Hermes"], destination: .iMessage(handle: "")),
        AgentPreset(id: "claude", name: "Claude Code", program: "npx", command: ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
                    draftOptions: [.option(id: "model", value: "haiku"), .option(id: "effort", value: "low")],
                    taskOptions: [], spokenNames: ["Claude"], destination: .t3Code(T3Destination())),
        AgentPreset(id: "codex", name: "Codex", program: "npx", command: ["npx", "-y", "@agentclientprotocol/codex-acp"],
                    draftOptions: [.model("gpt-6-luna[low]")], taskOptions: [], spokenNames: ["Codex"], destination: .t3Code(T3Destination())),
        AgentPreset(id: "opencode", name: "OpenCode", program: "opencode", command: ["opencode", "acp"],
                    draftOptions: [.option(id: "model", value: "openai/gpt-6-luna")], taskOptions: [], spokenNames: ["OpenCode"],
                    destination: .agentReply),
        AgentPreset(id: "gemini", name: "Gemini", program: "gemini", command: ["gemini", "--acp"], draftOptions: [], taskOptions: [],
                    spokenNames: ["Gemini"], destination: .agentReply),
        AgentPreset(id: "custom", name: "Custom", program: "", command: [], draftOptions: [], taskOptions: [], spokenNames: [],
                    destination: .agentReply),
    ]

    public static func with(id: String) -> AgentPreset? { all.first { $0.id == id } }

    /// A new connection to this agent, with its defaults.
    public func connection() -> AgentConnection {
        AgentConnection(id: id == "custom" ? "custom-\(UUID().uuidString.prefix(8))" : id, name: id == "custom" ? "My agent" : name,
                        presetID: id, command: command, spokenNames: spokenNames, draftOptions: draftOptions, taskOptions: taskOptions,
                        destination: destination)
    }
}

/// One agent the user set up. Stored in Settings; secrets its destination needs live in the Keychain.
public struct AgentConnection: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var presetID: String
    /// Run through the user's login shell, so PATH, npx and ~/.ssh/config work from an app started by launchd.
    public var command: [String]
    /// Set to run the agent on another Mac over ssh, such as Hermes on a Mac mini reached through Tailscale.
    public var remoteHost: String?
    /// The names that, said first, send a request to this agent instead of the default one.
    public var spokenNames: [String]
    public var draftOptions: [ConfigChoice]
    public var taskOptions: [ConfigChoice]
    public var destination: Destination

    public init(id: String, name: String, presetID: String, command: [String], remoteHost: String? = nil, spokenNames: [String],
                draftOptions: [ConfigChoice], taskOptions: [ConfigChoice], destination: Destination) {
        (self.id, self.name, self.presetID, self.command, self.remoteHost) = (id, name, presetID, command, remoteHost)
        (self.spokenNames, self.draftOptions, self.taskOptions, self.destination) = (spokenNames, draftOptions, taskOptions, destination)
    }

    /// The first letter, for the round avatar on the bar and the card.
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    public var isRemote: Bool { hostName != nil }

    /// The ssh host with its spaces trimmed, or nil to run on this Mac.
    /// A plain next step for an error this agent gave, when the error is one people commonly hit while setting up.
    public func hint(forTrouble reason: String) -> String? {
        let said = reason.lowercased()
        if ["authentication required", "not logged in", "please run /login", "please log in"].contains(where: said.contains) {
            return "Sign in to \(name) first: run it once in Terminal and log in."
        }
        guard let host = hostName else { return nil }
        if said.contains("could not resolve hostname") {
            return "This Mac can't find \(host). Use the name from ~/.ssh/config, or the Mac's address."
        }
        if said.contains("permission denied (publickey") || said.contains("host key verification failed") {
            return "This Mac has to sign in to \(host) without a password. Run ssh \(host) once in Terminal to set that up."
        }
        if ["timed out", "no route to host", "connection refused"].contains(where: said.contains) {
            return "Check that \(host) is awake and Remote Login is on, in System Settings > General > Sharing."
        }
        if said.contains("command not found") {
            return "\(name) isn't installed on \(host), or isn't on its login PATH."
        }
        return nil
    }

    public var hostName: String? {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return host
    }

    /// The folder sent with each new session. A remote agent rejects a local path that does not exist on its machine.
    public func sessionDirectory(local: String) -> String { isRemote ? "/tmp" : local }

    /// The argument vector for `$SHELL -lc`, with each word quoted for the shell. A remote host wraps it in ssh, which
    /// passes the remote command to the far side's shell as one string.
    public var shellCommand: String {
        let local = command.map(ShellQuote.quote).joined(separator: " ")
        guard let host = remoteHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return "exec " + local }
        let preset = AgentPreset.with(id: presetID)
        let words = (preset?.command == command ? preset?.remoteCommand : nil) ?? command
        let remote = words.map(ShellQuote.quote).joined(separator: " ")
        return "exec ssh -T -o BatchMode=yes " + ShellQuote.quote(host) + " " + ShellQuote.quote(remote)
    }
}

public enum ShellQuote {
    /// Single quotes, with any single quote inside closed, escaped and reopened. Plain words stay bare.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:@=+,%".contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a handed-off task goes, so the agent keeps going in its own app. Secrets are Keychain item names, never values.
public enum Destination: Equatable, Codable, Sendable {
    /// Messages, sent as the user to the agent's handle.
    case iMessage(handle: String)
    case t3Code(T3Destination)
    /// A chat with the bot, filled in for the user to send.
    case telegram(botUsername: String)
    /// A direct message to the bot, posted as the user with their own Slack token.
    case slack(team: String, botUserID: String, tokenKey: String)
    /// A channel webhook that mentions the bot.
    case discord(webhookKey: String, botID: String)
    case webhook(url: String, secretKey: String?)
    /// A program run without a shell, with the hand-off as JSON on stdin.
    case command(executable: String, arguments: [String])
    /// The agent does the task over ACP and its reply shows in the card.
    case agentReply

    /// What the card calls it while confirming, and what the settings say: "Hermes in iMessage", "a new T3 Code thread".
    public func title(agent: String) -> String {
        switch self {
        case .iMessage: "\(agent) in iMessage"
        case .t3Code: "a new T3 Code thread"
        case .telegram: "Telegram"
        case .slack: "Slack"
        case .discord: "Discord"
        case .webhook(let url, _): URL(string: url)?.host ?? "your web address"
        case .command(let executable, _): URL(fileURLWithPath: executable).lastPathComponent
        case .agentReply: agent
        }
    }

    public var kind: DestinationKind {
        switch self {
        case .iMessage: .iMessage
        case .t3Code: .t3Code
        case .telegram: .telegram
        case .slack: .slack
        case .discord: .discord
        case .webhook: .webhook
        case .command: .command
        case .agentReply: .agentReply
        }
    }
}

public enum DestinationKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case agentReply, iMessage, t3Code, telegram, slack, discord, webhook, command

    public var id: Self { self }

    public var title: String {
        switch self {
        case .agentReply: "Show the reply here"
        case .iMessage: "iMessage"
        case .t3Code: "T3 Code"
        case .telegram: "Telegram"
        case .slack: "Slack"
        case .discord: "Discord"
        case .webhook: "Web address"
        case .command: "Command"
        }
    }

    /// The destination with empty fields, for the menu that switches kinds.
    public var blank: Destination {
        switch self {
        case .agentReply: .agentReply
        case .iMessage: .iMessage(handle: "")
        case .t3Code: .t3Code(T3Destination())
        case .telegram: .telegram(botUsername: "")
        case .slack: .slack(team: "", botUserID: "", tokenKey: "slack-\(UUID().uuidString.prefix(8))")
        case .discord: .discord(webhookKey: "discord-\(UUID().uuidString.prefix(8))", botID: "")
        case .webhook: .webhook(url: "", secretKey: "webhook-\(UUID().uuidString.prefix(8))")
        case .command: .command(executable: "", arguments: [])
        }
    }
}

public struct T3Destination: Equatable, Codable, Sendable {
    /// T3 Code's home folder. Nil looks in $T3CODE_HOME, then ~/.t3, then ~/.t3-v2.
    public var home: String?
    /// The provider and model the new thread runs, or nil for T3's own default.
    public var provider: String?
    public var model: String?

    public init(home: String? = nil, provider: String? = nil, model: String? = nil) {
        (self.home, self.provider, self.model) = (home, provider, model)
    }
}

/// Ghostwrite and Hand off, apart from their keys.
public struct AgentSettings: Equatable, Codable, Sendable {
    public var agents: [AgentConnection] = []
    public var defaultAgent: String?
    /// The draft shows in a card for Return, a spoken change, or Esc. Off pastes it once it is finished.
    public var reviewFirst = true
    /// Recent dictations in the same kind of app go with each draft request as examples of the user's voice.
    public var voiceExamples = true
    /// The user's voice written down once, sent with each draft.
    public var voiceNotes = ""
    /// A hand-off message carries a short block of the window's text after the words.
    public var includeWindowText = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        agents = (try? container.decodeIfPresent(LossyArray<AgentConnection>.self, forKey: .agents))?.elements ?? defaults.agents
        defaultAgent = value(.defaultAgent, defaults.defaultAgent)
        reviewFirst = value(.reviewFirst, defaults.reviewFirst)
        voiceExamples = value(.voiceExamples, defaults.voiceExamples)
        voiceNotes = value(.voiceNotes, defaults.voiceNotes)
        includeWindowText = value(.includeWindowText, defaults.includeWindowText)
    }

    public var current: AgentConnection? { agents.first { $0.id == defaultAgent } ?? agents.first }

    public func agent(id: String?) -> AgentConnection? { agents.first { $0.id == id } }
}
