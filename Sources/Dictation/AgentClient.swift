import DictationCore
import Foundation
import os

/// A session whose last turn did not stop when cancelled. Its late output must not reach a new turn, so the caller
/// starts a new session.
struct SessionRetired: LocalizedError {
    var errorDescription: String? { "The agent didn't stop its last answer, so a new session is needed." }
}

struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One agent process speaking the Agent Client Protocol over its stdin and stdout. Started through the user's login
/// shell, so an app launched by launchd sees the same PATH, npx and ssh config as a terminal. Messages are read in
/// order on one loop; each request waits for its own answer.
actor ACPClient {
    typealias UpdateHandler = @Sendable (SessionUpdate) -> Void
    typealias PermissionHandler = @Sendable (PermissionRequest) async -> String?

    nonisolated let name: String
    private let process = Process()
    private let input = Pipe()
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextID = 1
    private var updates: [String: UpdateHandler] = [:]
    private var permissions: [String: PermissionHandler] = [:]
    /// The request id of the prompt running in each session. A newer prompt cancels it and waits for it to end.
    private var prompting: [String: Int] = [:]
    /// Sessions whose turn ignored a cancel.
    private var retired: Set<String> = []
    private var lastActivity = Instant.now
    private var stderrTail: [String] = []
    private(set) var exited = false
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "agent")

    /// Starts the process. Nothing is sent until `initialize`.
    init(name: String, shellCommand: String, cwd: URL) throws {
        self.name = name
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", shellCommand]
        process.currentDirectoryURL = cwd
        let output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let (messages, sink) = AsyncStream.makeStream(of: RPCMessage?.self)
        let framer = OSAllocatedUnfairLock(initialState: LineFramer())
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.yield(nil)
                sink.finish()
                return
            }
            for line in framer.withLock({ $0.push(data) }) {
                if let message = RPCMessage.parse(line) { sink.yield(message) }
            }
        }
        let tail = OSAllocatedUnfairLock(initialState: [String]())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            tail.withLock { $0 = Array(($0 + lines).suffix(8)) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.closed(stderr: tail.withLock { $0 }) }
        }
        try process.run()
        Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                if let message { await self.receive(message) } else { await self.closed(stderr: tail.withLock { $0 }) }
            }
        }
    }

    var isAlive: Bool { !exited && process.isRunning }

    /// When the agent last had nothing to do: nil while a request waits on it.
    var idleSince: Instant? { pending.isEmpty ? lastActivity : nil }

    /// What the agent last wrote to stderr, to say why it stopped.
    var lastError: String? { stderrTail.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    func request(_ method: String, _ params: JSONValue, timeout: Double = 60) async throws -> JSONValue {
        try await request(method, params, timeout: timeout, id: claimID())
    }

    private func claimID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func request(_ method: String, _ params: JSONValue, timeout: Double, id: Int) async throws -> JSONValue {
        guard isAlive else { throw AgentError("\(name) isn't running.") }
        lastActivity = .now
        let name = self.name
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await self?.fail(id, AgentError("\(name) took more than \(Int(timeout)) seconds to answer."))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(RPCMessage.request(id: id, method: method, params: params))
        }
    }

    func notify(_ method: String, _ params: JSONValue) { write(RPCMessage.notification(method: method, params: params)) }

    func initialize() async throws {
        _ = try await request("initialize", ACP.initialize(version: Self.version), timeout: 45)
    }

    func newSession(cwd: String) async throws -> SessionInfo {
        let result = try await request("session/new", ACP.newSession(cwd: cwd), timeout: 45)
        guard let info = SessionInfo.parse(result) else { throw AgentError("\(name) didn't open a session.") }
        return info
    }

    func set(_ choice: ConfigChoice, session: String) async throws {
        let call = ACP.set(choice, session: session)
        _ = try await request(call.method, call.params, timeout: 30)
    }

    /// Streams the reply into `onUpdate` and returns the stop reason. `onPermission` answers the agent's questions. A
    /// prompt still running in the session is cancelled first, and its last updates still go to its own handlers.
    func prompt(_ text: String, session: String, timeout: Double, onUpdate: @escaping UpdateHandler,
                onPermission: @escaping PermissionHandler) async throws -> String {
        await supersede(session)
        if retired.contains(session) { throw SessionRetired() }
        let id = claimID()
        prompting[session] = id
        updates[session] = onUpdate
        permissions[session] = onPermission
        defer {
            if prompting[session] == id {
                prompting[session] = nil
                updates[session] = nil
                permissions[session] = nil
            }
        }
        let result = try await request("session/prompt", ACP.prompt(text, session: session), timeout: timeout, id: id)
        return result["stopReason"]?.string ?? "end_turn"
    }

    /// Asks the agent to stop the prompt running in the session, if one is, and gives it 3 s to answer that prompt.
    func cancel(session: String) async {
        guard let running = prompting[session] else { return }
        notify("session/cancel", ACP.cancel(session: session))
        for _ in 0..<150 where prompting[session] == running { try? await Task.sleep(for: .milliseconds(20)) }
        guard prompting[session] == running else { return }
        retired.insert(session)
        prompting[session] = nil
        updates[session] = nil
        permissions[session] = nil
        fail(running, CancellationError())
    }

    private func supersede(_ session: String) async {
        while prompting[session] != nil { await cancel(session: session) }
    }

    func terminate() { process.stop() }

    private func write(_ message: JSONValue) {
        guard isAlive else { return }
        do { try input.fileHandleForWriting.write(contentsOf: LineFramer.frame(message)) } catch { exited = true }
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive(_ message: RPCMessage) async {
        lastActivity = .now
        switch message {
        case .response(let id, let result):
            guard let number = id.number, let continuation = pending.removeValue(forKey: Int(number)) else { return }
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        case .notification("session/update", let params):
            guard let (session, update) = SessionUpdate.parse(params) else { return }
            updates[session]?(update)
        case .notification:
            break
        case .request(let id, "session/request_permission", let params):
            guard let request = PermissionRequest.parse(id: id, params: params) else {
                return write(RPCMessage.error(id: id, code: -32602, message: "unreadable permission request"))
            }
            guard let ask = permissions[request.session] else {
                return write(RPCMessage.result(id: id, ACP.permissionAnswer(optionID: request.rejection?.id)))
            }
            Task {
                let choice = await ask(request)
                self.write(RPCMessage.result(id: id, ACP.permissionAnswer(optionID: choice)))
            }
        case .request(let id, let method, _):
            write(RPCMessage.error(id: id, code: RPCError.methodNotFound, message: "Lip Service doesn't offer \(method)"))
        }
    }

    /// Called when stdout closes and when the process exits, whichever comes first; the second call finds nothing to do.
    private func closed(stderr: [String]) {
        guard !exited || !pending.isEmpty else { return }
        exited = true
        stderrTail = stderr
        let reason = stderr.last.map { ": \($0)" } ?? ""
        Self.log.info("\(self.name, privacy: .public) stopped\(reason, privacy: .public)")
        for continuation in pending.values { continuation.resume(throwing: AgentError("\(name) stopped\(reason)")) }
        pending = [:]
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

/// Keeps each agent the user has used running, with one spare session already open and set to the draft options,
/// so a draft costs only its prompt. Every request still gets a fresh session; the spare is replaced after each use.
/// An agent with no request for 30 minutes is stopped, never one still answering; a dead one is started again on the
/// next request.
@MainActor final class AgentPool {
    let idleLimit: Double

    struct Warm {
        var client: ACPClient
        /// Resolves to a session id with the draft options set.
        var spare: Task<String, any Error>?
        var command: String
        var draftOptions: [ConfigChoice]
    }

    /// The agent's own settings and models as its last session reported them, for the settings page's menus.
    private(set) var catalogs: [String: SessionInfo] = [:]
    var onCatalog: ((String) -> Void)?
    private var warm: [String: Warm] = [:]
    private var starting: [String: Task<ACPClient, any Error>] = [:]
    /// Which start is current for each agent. A start that finishes after it was stopped or replaced is not.
    private var startTokens: [String: UUID] = [:]
    private var reaper: Task<Void, Never>?
    let workingDirectory: URL
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "agent")

    init(idleLimit: Double = 30 * 60) {
        self.idleLimit = idleLimit
        workingDirectory = FileManager.default.temporaryDirectory.appending(path: "LipService-agent", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    /// At Ghostwrite key-down, while the user is still talking: start the agent if needed and open a spare session.
    func prepare(_ agent: AgentConnection) {
        Task { _ = try? await spareSession(agent, refill: false) }
    }

    /// A fresh session with the draft options already set, and the client it belongs to. Opens the next spare at once.
    func draftSession(_ agent: AgentConnection) async throws -> (ACPClient, String) {
        try await spareSession(agent, refill: true)
    }

    /// A fresh session with the task options, for a hand-off or voice notes, which use the full model.
    func taskSession(_ agent: AgentConnection) async throws -> (ACPClient, String) {
        let client = try await client(for: agent)
        let info = try await client.newSession(cwd: agent.sessionDirectory(local: workingDirectory.path))
        remember(info, for: agent.id)
        for choice in agent.taskOptions { try await client.set(choice, session: info.id) }
        return (client, info.id)
    }

    /// Stops an agent, for a changed command or a Test that should start it fresh.
    func stop(_ agentID: String) {
        starting[agentID]?.cancel()
        starting[agentID] = nil
        startTokens[agentID] = nil
        guard let entry = warm.removeValue(forKey: agentID) else { return }
        entry.spare?.cancel()
        Task { await entry.client.terminate() }
    }

    func stopAll() { for id in Array(warm.keys) { stop(id) } }

    private func spareSession(_ agent: AgentConnection, refill: Bool) async throws -> (ACPClient, String) {
        let client = try await client(for: agent)
        guard var entry = warm[agent.id] else { throw AgentError("\(agent.name) stopped.") }
        if entry.draftOptions != agent.draftOptions {
            entry.spare?.cancel()
            entry.spare = nil
            entry.draftOptions = agent.draftOptions
        }
        let spare = entry.spare ?? openSpare(agent, client: client)
        entry.spare = refill ? nil : spare
        warm[agent.id] = entry
        do {
            let session = try await spare.value
            // Refilled only while this client and these options are still current: a late answer for a draft made
            // before a model change must not put back a spare with the old model.
            if refill, let now = warm[agent.id], now.client === client, now.draftOptions == agent.draftOptions, now.spare == nil {
                warm[agent.id]?.spare = openSpare(agent, client: client)
            }
            return (client, session)
        } catch {
            if warm[agent.id]?.spare == spare { warm[agent.id]?.spare = nil }
            throw error
        }
    }

    private func openSpare(_ agent: AgentConnection, client: ACPClient) -> Task<String, any Error> {
        let cwd = agent.sessionDirectory(local: workingDirectory.path), options = agent.draftOptions, id = agent.id
        return Task { [weak self] in
            let info = try await client.newSession(cwd: cwd)
            await self?.remember(info, for: id)
            for choice in options { try await client.set(choice, session: info.id) }
            return info.id
        }
    }

    private func remember(_ info: SessionInfo, for id: String) {
        guard catalogs[id] != info else { return }
        catalogs[id] = info
        onCatalog?(id)
    }

    /// The running client, or a new one when there is none, it died, or its command changed.
    private func client(for agent: AgentConnection) async throws -> ACPClient {
        let command = agent.shellCommand
        if let entry = warm[agent.id] {
            if entry.command == command, await entry.client.isAlive { return entry.client }
            stop(agent.id)
        }
        if let task = starting[agent.id] { return try await task.value }
        let cwd = workingDirectory, started = Instant.now, token = UUID()
        // Every caller waiting on this start finds the agent in `warm` once it resolves, so the entry is made here.
        let task = Task { () throws -> ACPClient in
            defer {
                if startTokens[agent.id] == token {
                    starting[agent.id] = nil
                    startTokens[agent.id] = nil
                }
            }
            let client = try ACPClient(name: agent.name, shellCommand: command, cwd: cwd)
            do {
                try await client.initialize()
            } catch {
                let detail = await client.lastError
                await client.terminate()
                throw AgentError(Self.explain(agent: agent.name, error: error, stderr: detail))
            }
            guard startTokens[agent.id] == token else {
                await client.terminate()
                throw AgentError("\(agent.name) was stopped while it started.")
            }
            log.info("\(agent.name, privacy: .public) started in \(Instant.now - started, format: .fixed(precision: 2)) s")
            warm[agent.id] = Warm(client: client, spare: nil, command: command, draftOptions: agent.draftOptions)
            scheduleReaper()
            return client
        }
        starting[agent.id] = task
        startTokens[agent.id] = token
        return try await task.value
    }

    private static func explain(agent: String, error: any Error, stderr: String?) -> String {
        if let stderr, stderr.contains("command not found") || stderr.contains("not found") {
            return "\(agent) isn't installed, or isn't on your shell's PATH."
        }
        return "\(agent) didn't start: \(stderr ?? error.localizedDescription)"
    }

    /// A check every minute, or every half limit when that is shorter, only while some agent is running, so an idle
    /// app with no agents does no work.
    private func scheduleReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while true {
                guard let limit = self?.idleLimit else { return }
                try? await Task.sleep(for: .seconds(min(60, limit / 2)))
                guard let self, await self.reap() else { return }
            }
        }
    }

    /// Stops each agent with no request for `idleLimit`. False once none is left running.
    private func reap() async -> Bool {
        for (id, entry) in warm {
            guard let idle = await entry.client.idleSince, Instant.now - idle > idleLimit, warm[id]?.client === entry.client else { continue }
            log.info("\(entry.client.name, privacy: .public) stopped after \(Int(self.idleLimit)) s with no request")
            stop(id)
        }
        guard warm.isEmpty else { return true }
        reaper = nil
        return false
    }
}
