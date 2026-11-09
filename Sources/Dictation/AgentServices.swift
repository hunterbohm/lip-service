import AppKit
import DictationCore
import SwiftUI

/// What the Ghostwrite page needs beyond settings: whether each agent answers, which are installed, their model menus,
/// building voice notes, and T3 Code's sign-in.
@MainActor @Observable final class AgentServices {
    enum Status: Equatable { case unknown, testing, ready(seconds: Double, model: String?), failed(String) }
    enum T3State: Equatable { case unknown, connected(expires: Date), notConnected, connecting, failed(String) }

    private(set) var statuses: [String: Status] = [:]
    private(set) var installed: Set<String>?
    private(set) var catalogs: [String: SessionInfo] = [:]
    private(set) var building = false
    private(set) var buildProblem: String?
    private(set) var t3: [String: T3State] = [:]

    @ObservationIgnored let pool: AgentPool
    /// The window render has no agents to ask, so it shows the statuses it is given.
    @ObservationIgnored var isStatic = false
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let history: HistoryStore

    init(pool: AgentPool, preferences: Preferences, history: HistoryStore) {
        (self.pool, self.preferences, self.history) = (pool, preferences, history)
        catalogs = pool.catalogs
        pool.onCatalog = { [weak self] id in self?.catalogs[id] = self?.pool.catalogs[id] }
    }

    /// Asks the login shell once which agent programs are on its PATH.
    func detect() {
        guard installed == nil, !isStatic else { return }
        Task.detached {
            let found = AgentDetection.found()
            await MainActor.run { self.installed = found }
        }
    }

    /// Starts the agent fresh, opens a draft session and asks for one word, so the user sees it answer and how fast.
    func test(_ agent: AgentConnection) {
        guard !isStatic else { return }
        statuses[agent.id] = .testing
        Task {
            if let problem = await AgentBench.checkDestination(agent) {
                statuses[agent.id] = .failed(problem)
                return
            }
            switch await AgentBench.check(agent, pool: pool) {
            case .success(let check): statuses[agent.id] = .ready(seconds: check.seconds, model: check.model)
            case .failure(let error): statuses[agent.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Checks an agent the first time it is looked at, unless it is missing from this Mac.
    func checkIfNeeded(_ agent: AgentConnection) {
        guard statuses[agent.id] == nil || statuses[agent.id] == .unknown, state(of: agent) != .notInstalled else { return }
        test(agent)
    }

    enum State: Equatable { case unchecked, checking, ready(seconds: Double), unreachable(String), notInstalled }

    func state(of agent: AgentConnection) -> State {
        if !agent.isRemote, agent.presetID != "custom", let installed, !installed.contains(agent.presetID) { return .notInstalled }
        switch statuses[agent.id] ?? .unknown {
        case .unknown: return .unchecked
        case .testing: return .checking
        case .ready(let seconds, _): return .ready(seconds: seconds)
        case .failed(let reason): return .unreachable(reason)
        }
    }

    /// For the window render, which has no agents to ask.
    func show(status: Status, for agent: String) { statuses[agent] = status }
    func show(installed: Set<String>) { self.installed = installed }
    func show(t3: T3State, for agent: String) { self.t3[agent] = t3 }

    /// Asks the agent, on its full model, to describe how the user writes, and saves the answer as voice notes.
    func buildVoiceNotes(with agent: AgentConnection) {
        building = true
        buildProblem = nil
        let examples = Array(history.entries.reversed().filter { $0.isDictation && $0.words >= 6 }.prefix(30).map(\.text))
        Task {
            defer { building = false }
            do {
                let (client, session) = try await pool.taskSession(agent)
                let collected = Collected()
                _ = try await client.prompt(VoiceNotes.buildPrompt(examples: examples), session: session, timeout: 300,
                                            onUpdate: { if case .message(let text) = $0 { collected.append(text) } },
                                            onPermission: { VoiceNotes.answer($0) })
                let notes = ReplyCleanup.clean(collected.text)
                guard !notes.isEmpty else { throw AgentError("\(agent.name) sent back nothing.") }
                preferences.change { $0.agents.voiceNotes = notes }
            } catch {
                buildProblem = error.localizedDescription
            }
        }
    }

    /// Where this agent's T3 Code is: its hand-off destination, or the default one for an agent that only starts threads
    /// during a live talk. Nil for an agent with neither.
    private func t3Destination(for agent: AgentConnection) -> T3Destination? {
        if case .t3Code(let destination) = agent.destination { return destination }
        return agent.talkT3 ? T3Destination() : nil
    }

    func refreshT3(_ agent: AgentConnection) {
        guard !isStatic, let destination = t3Destination(for: agent) else { return }
        guard let client = try? T3Client(destination: destination, secrets: Keychain()) else { return t3[agent.id] = .failed("T3 Code isn't running.") }
        t3[agent.id] = client.token.map { .connected(expires: $0.expires) } ?? .notConnected
    }

    func connectT3(_ agent: AgentConnection, code: String) {
        guard let destination = t3Destination(for: agent) else { return }
        t3[agent.id] = .connecting
        Task {
            do {
                let client = try T3Client(destination: destination, secrets: Keychain())
                try await client.signIn(pairingCode: code)
                refreshT3(agent)
            } catch {
                t3[agent.id] = .failed(error.localizedDescription)
            }
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ text: String) { lock.withLock { value += text } }
        var text: String { lock.withLock { value } }
    }
}
