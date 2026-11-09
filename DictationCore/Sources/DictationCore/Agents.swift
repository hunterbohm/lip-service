import Foundation

/// One setting sent to an agent's session before a prompt: a config option set to a value, or, for agents that only
/// support it, a model picked with `session/set_model`. Applied in order, since switching some agents' model resets
/// their effort.
public enum ConfigChoice: Equatable, Hashable, Codable, Sendable {
    case option(id: String, value: String)
    case model(String)

    /// `options` without any that would change a setting `required` sets, so a saved choice can never undo one the
    /// session needs, such as the mode that makes starting a T3 Code thread ask first.
    public static func sparing(_ required: [ConfigChoice], from options: [ConfigChoice]) -> [ConfigChoice] {
        options.filter { option in !required.contains { $0.sets(sameSettingAs: option) } }
    }

    private func sets(sameSettingAs other: ConfigChoice) -> Bool {
        switch (self, other) {
        case (.option(let a, _), .option(let b, _)): a == b
        case (.model, .model): true
        default: false
        }
    }
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
    /// Set on each live talk's session: a strong model that still answers quickly.
    public var talkOptions: [ConfigChoice] = []
    /// Added to the voice note on every turn of a talk, for what only this agent can do.
    public var talkNote = ""
    /// A talk gives the agent T3 Code's tools for listing projects and starting threads, when T3 Code is running and
    /// connected on this Mac. For an agent that has no way to start a T3 thread of its own.
    public var talkT3 = false
    public var spokenNames: [String]
    public var destination: Destination

    public static let all: [AgentPreset] = [
        AgentPreset(id: "hermes", name: "Hermes", program: "hermes", command: ["hermes", "acp"], remoteCommand: ["hermes", "acp"],
                    draftOptions: [.option(id: "model", value: "anthropic:claude-haiku-5-5"), .option(id: "reasoning_effort", value: "low")],
                    taskOptions: [],
                    talkOptions: [.option(id: "model", value: "anthropic:claude-opus-5-5"), .option(id: "reasoning_effort", value: "low")],
                    talkNote: #"If I ask you to send me something, send it in the terminal through a quoted heredoc, so nothing in the text runs: hermes send -t photon <<'EOF', then the text, then EOF."#,
                    spokenNames: ["Hermes"], destination: .iMessage(handle: "")),
        AgentPreset(id: "claude", name: "Claude Code", program: "npx", command: ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
                    draftOptions: [.option(id: "model", value: "haiku"), .option(id: "effort", value: "low")],
                    taskOptions: [], talkOptions: [.option(id: "effort", value: "low")],
                    talkNote: "Keep every spoken answer to one or two short sentences.", talkT3: true,
                    spokenNames: ["Claude"], destination: .t3Code(T3Destination())),
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
                        talkOptions: talkOptions, talkNote: talkNote, talkT3: talkT3, destination: destination)
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
    /// Set on each live talk's session, after the agent's own defaults.
    public var talkOptions: [ConfigChoice]
    /// Added to the voice note on every turn of a talk, such as how Hermes sends a message.
    public var talkNote: String
    /// A talk gives the agent T3 Code's tools for listing projects and starting threads, when T3 Code is running and
    /// connected on this Mac and the agent runs here too.
    public var talkT3: Bool
    public var destination: Destination

    public init(id: String, name: String, presetID: String, command: [String], remoteHost: String? = nil, spokenNames: [String],
                draftOptions: [ConfigChoice], taskOptions: [ConfigChoice], talkOptions: [ConfigChoice] = [], talkNote: String = "",
                talkT3: Bool = false, destination: Destination) {
        (self.id, self.name, self.presetID, self.command, self.remoteHost) = (id, name, presetID, command, remoteHost)
        (self.spokenNames, self.draftOptions, self.taskOptions, self.destination) = (spokenNames, draftOptions, taskOptions, destination)
        (self.talkOptions, self.talkNote, self.talkT3) = (talkOptions, talkNote, talkT3)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, presetID, command, remoteHost, spokenNames, draftOptions, taskOptions, talkOptions, talkNote, talkT3, destination
    }

    /// An agent saved before live talk existed, or before a talk setting did, gets its preset's talk settings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        presetID = try container.decode(String.self, forKey: .presetID)
        command = try container.decode([String].self, forKey: .command)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
        spokenNames = try container.decode([String].self, forKey: .spokenNames)
        draftOptions = try container.decode([ConfigChoice].self, forKey: .draftOptions)
        taskOptions = try container.decode([ConfigChoice].self, forKey: .taskOptions)
        destination = try container.decode(Destination.self, forKey: .destination)
        let preset = AgentPreset.with(id: presetID)
        talkOptions = (try? container.decodeIfPresent([ConfigChoice].self, forKey: .talkOptions)) ?? preset?.talkOptions ?? []
        talkNote = (try? container.decodeIfPresent(String.self, forKey: .talkNote)) ?? preset?.talkNote ?? ""
        talkT3 = (try? container.decodeIfPresent(Bool.self, forKey: .talkT3)) ?? preset?.talkT3 ?? false
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
        // Through the far side's login shell, as here, so a program on its .zprofile PATH, such as Homebrew's, is found.
        let remote = #"exec "${SHELL:-/bin/sh}" -lc "# + ShellQuote.quote(ShellWords.join(words))
        return "exec ssh -T -o BatchMode=yes " + ShellQuote.quote(host) + " " + ShellQuote.quote(remote)
    }
}

/// A typed command line split into words the way a shell splits it: spaces separate words, single quotes keep
/// everything inside, double quotes keep spaces, and a backslash keeps the next character. The inverse of quoting
/// each word with `ShellQuote`.
public enum ShellWords {
    public static func split(_ line: String) -> [String] {
        var words: [String] = [], word = "", inWord = false, escaped = false
        var quote: Character?
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true } else { word.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                escaped = true
                inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(word) }
                word = ""
                inWord = false
            default:
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// Words joined so `split` gives them back, for showing a command in a text field.
    public static func join(_ words: [String]) -> String { words.map(ShellQuote.quote).joined(separator: " ") }
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
    /// A hand-off message carries a short block of the window's text after the words. Off until the user turns it on,
    /// since that text is untrusted and goes to an agent that may have tools.
    public var includeWindowText = false

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
