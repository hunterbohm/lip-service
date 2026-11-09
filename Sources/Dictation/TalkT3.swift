import DictationCore
import Foundation
import os

/// What a talk adds to an agent's session besides its own settings: MCP servers, session options, and a line for the
/// note that goes with each turn.
struct TalkExtras: Sendable {
    var servers: [JSONValue] = []
    /// Set on the session first. If the agent turns one down, the talk starts without these extras.
    var options: [ConfigChoice] = []
    var note = ""
    /// The name of a T3 Code project, for the question asked before a thread starts there.
    var projectName: (@Sendable (String) async -> String?)?
}

/// Gives a talk with Claude Code the tools to start threads in T3 Code, through `T3Bridge`: an MCP server that is Lip
/// Service's own binary, started by the agent, which reads the token Lip Service already holds for hand-offs. The token
/// is never handed to the agent: not in its MCP settings, command line, environment, prompt, or any log.
enum TalkT3 {
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "talk")

    /// The T3 Code tools for this agent's talk, or nil to talk without them: the agent has none to take, it runs on another
    /// Mac, or T3 Code isn't running or isn't connected. Each reason is logged, since a talk that starts without the tools
    /// says nothing about it.
    static func extras(for agent: AgentConnection, secrets: any SecretStore) async -> TalkExtras? {
        guard agent.talkT3, !agent.isRemote, let executable = Bundle.main.executablePath else { return nil }
        let destination: T3Destination = if case .t3Code(let t3) = agent.destination { t3 } else { T3Destination() }
        // Off the main actor: the Keychain may stop to ask for the Mac password after an update.
        return await Task.detached { () -> TalkExtras? in
            guard let client = try? T3Client(destination: destination, secrets: secrets) else {
                log.info("talk without T3 Code's tools: it isn't running")
                return nil
            }
            guard client.isSignedIn else {
                log.info("talk without T3 Code's tools: not connected")
                return nil
            }
            // A test run reads the token from a file instead of the Keychain; the path is no secret.
            let environment = ProcessInfo.processInfo.environment["LS_SECRETS"].map { ["LS_SECRETS": $0] } ?? [:]
            let server = ACP.stdioServer(name: T3Talk.serverName, command: executable,
                                         args: ["--t3-mcp"] + (destination.home.map { [$0] } ?? []), env: environment)
            return TalkExtras(servers: [server], options: T3Talk.sessionOptions, note: T3Talk.note, projectName: { id in
                (try? await client.projects())?.first { $0.id == id }?.name
            })
        }.value
    }
}
