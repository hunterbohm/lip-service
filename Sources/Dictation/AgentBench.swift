import DictationCore
import Foundation

/// `--agent-bench`: times drafts through the app's own AgentPool against a real agent, warm the way Ghostwrite runs it
/// (the agent started and a spare session ready at key-down) or cold (a new process for every run). One JSON line per run.
/// A run is set up and ended as Ghostwrite sets up and ends one: the preset's tool-free settings, every permission
/// refused, and a stop at the first tool.
@MainActor enum AgentBench {
    struct Options {
        var command: [String] = []
        var remoteHost: String?
        var name = "Agent"
        /// The preset whose tool-free draft settings apply, as for an agent set up from it.
        var preset = "custom"
        var draftOptions: [ConfigChoice] = []
        var runs = 10
        var cold = false
        var speech = 2.0
        /// Speak a change this many seconds into the draft, in the same session, as holding the key over a streaming draft does.
        var supersede: Double?
        var idleLimit = 30.0 * 60
        var prompt = GhostwriteRequest(words: "reply saying Tuesday at 3 works and I'll bring the latest cut",
                                       context: WindowContext(app: HistoryApp(name: "Mail", bundleID: "com.apple.mail"), windowTitle: "Dana Park",
                                                              nearby: ["Hey Hunter, are you free to go over the launch video this week? Tuesday at 3 or Wednesday morning both work on my end."])).prompt
    }

    static func run(_ options: Options) async -> Int32 {
        var agent = AgentPreset.with(id: "custom")!.connection()
        agent.name = options.name
        agent.presetID = options.preset
        agent.command = options.command
        agent.remoteHost = options.remoteHost
        agent.draftOptions = options.draftOptions
        let pool = AgentPool(idleLimit: options.idleLimit)
        var failures = 0
        for run in 1...options.runs {
            if options.cold || run == 1 { pool.stop(agent.id) }
            let keyDown = Instant.now
            pool.prepare(agent)
            try? await Task.sleep(for: .seconds(options.speech))
            let released = Instant.now
            var row: [String: JSONValue] = ["run": .number(Double(run)), "cold": .bool(options.cold || run == 1), "speech_s": .number(options.speech)]
            let first = Clock()
            do {
                let (client, session) = try await pool.draftSession(agent)
                let prompted = Instant.now
                func onUpdate(keepingText: Bool) -> ACPClient.UpdateHandler {
                    { update in
                        if first.see(update, keepingText: keepingText) { Task { await client.cancel(session: session, retiring: true) } }
                    }
                }
                let onPermission: ACPClient.PermissionHandler = { request in
                    first.asked(request.title)
                    return request.rejection?.id
                }
                var superseded: Task<String, any Error>?
                if let after = options.supersede {
                    superseded = Task { try await client.prompt(options.prompt, session: session, timeout: 60, onUpdate: onUpdate(keepingText: false), onPermission: onPermission) }
                    try? await Task.sleep(for: .seconds(after))
                }
                let text = superseded == nil ? options.prompt : GhostwriteRequest.change("make it shorter")
                let stop = try await client.prompt(text, session: session, timeout: 60, onUpdate: onUpdate(keepingText: true), onPermission: onPermission)
                let done = Instant.now
                try? await Task.sleep(for: .milliseconds(20))
                row["session_wait_s"] = .number(prompted - released)
                row["release_to_first_s"] = first.at.map { .number($0 - released) } ?? .null
                row["prompt_to_first_s"] = first.at.map { .number($0 - prompted) } ?? .null
                row["release_to_done_s"] = .number(done - released)
                row["keydown_to_ready_s"] = .number(prompted - keyDown)
                row["stop"] = .string(stop)
                if let superseded { row["first_stop"] = .string((try? await superseded.value) ?? "failed") }
                row["text"] = .string(ReplyCleanup.clean(first.text))
                if let question = first.question { row["asked"] = .string(question) }
            } catch {
                row["error"] = .string(error.localizedDescription)
            }
            row["tools"] = .number(Double(first.tools))
            if first.tools > 0 {
                row["error"] = .string(ToolStop.message(agent: agent.name))
                row["text"] = nil
            }
            if row["error"] != nil || first.at == nil { failures += 1 }
            print(String(decoding: JSONValue.object(row).data(), as: UTF8.self))
            fflush(stdout)
        }
        pool.stopAll()
        try? await Task.sleep(for: .milliseconds(300))
        return failures == 0 ? 0 : 1
    }

    /// The first time something happened, written from the agent's reader and read after the prompt returns.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Instant?
        private var chunks = ""
        private var stop = ToolStop()
        /// Takes in an update. True for the first tool, where the run ends. Text after it is dropped, as Ghostwrite drops it.
        func see(_ update: SessionUpdate, keepingText: Bool) -> Bool {
            lock.withLock {
                if keepingText, case .message(let chunk) = update, !stop.stopped {
                    if first == nil { first = .now }
                    chunks += chunk
                }
                return stop.see(update)
            }
        }
        var tools: Int { lock.withLock { stop.tools } }
        private var asked: String?
        func asked(_ title: String) { lock.withLock { asked = title } }
        var question: String? { lock.withLock { asked } }
        var at: Instant? { lock.withLock { first } }
        var text: String { lock.withLock { chunks } }
    }
}

/// Whether an agent answers, and how fast: the Test button, the first run's Check step and `setup test` all run this.
extension AgentBench {
    struct Check: Equatable {
        var seconds: Double
        var model: String?
    }

    /// Starts the agent fresh, opens a draft session and asks for one word.
    /// Asks for what the agent's hand-off needs from macOS, so no system prompt comes up later in the middle of one.
    /// Returns why it can't be used, or nil.
    static func checkDestination(_ agent: AgentConnection) async -> String? {
        guard case .iMessage = agent.destination else { return nil }
        switch await MessagesPermission.check(asking: true) {
        case .granted: return nil
        case .denied, .notAsked:
            return "Lip Service isn't allowed to use Messages. Turn it on in System Settings, Privacy & Security, Automation."
        }
    }

    static func check(_ agent: AgentConnection, pool: AgentPool) async -> Result<Check, any Error> {
        pool.stop(agent.id)
        let started = Instant.now
        do {
            let (client, session) = try await pool.draftSession(agent)
            _ = try await client.prompt("Reply with the single word: ready", session: session, timeout: 60,
                                        onUpdate: { _ in }, onPermission: { $0.rejection?.id })
            let catalog = pool.catalogs[agent.id]
            // The catalog is read at session/new, before the draft options switch the model, so a chosen one wins.
            let chosen = agent.draftOptions.compactMap { choice -> String? in
                switch choice {
                case .option(let id, let value) where id == "model": value
                case .model(let value): value
                default: nil
                }
            }.last
            return .success(Check(seconds: Instant.now - started,
                                  model: chosen ?? catalog?.options.first { $0.id == "model" }?.current ?? catalog?.currentModel))
        } catch {
            return .failure(error)
        }
    }
}

/// Which agent programs this Mac has, asked of the login shell so PATH is the one a terminal sees.
enum AgentDetection {
    /// The ids of the presets whose program is on the PATH. Custom is not a preset anyone installs.
    static func found() -> Set<String> {
        let programs = Set(AgentPreset.all.map(\.program).filter { !$0.isEmpty })
        let onPath = Self.onPath(programs)
        return Set(AgentPreset.all.filter { onPath.contains($0.program) }.map(\.id))
    }

    static func onPath(_ programs: Set<String>) -> Set<String> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", programs.map { "command -v \(ShellQuote.quote($0)) >/dev/null && echo \(ShellQuote.quote($0))" }.joined(separator: "; ")]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
    }
}
