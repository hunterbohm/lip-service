import DictationCore
import Foundation
import os

/// Which session each agent's last talk ended in, kept in a small file so the next talk, after a restart too, goes on
/// in it. Without a file the memory lasts only as long as the process, which is what a test run wants.
@MainActor final class TalkThreadStore {
    private(set) var threads: TalkThreads
    private let url: URL?
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "agent")

    init(url: URL? = nil) {
        self.url = url
        threads = url.flatMap { try? Data(contentsOf: $0) }.map(TalkThreads.decode) ?? TalkThreads()
    }

    /// The default place: next to the settings, under Application Support.
    static let defaultURL = SupportFolder.url.appending(path: "talk-threads.json")

    func session(for agent: AgentConnection) -> String? { threads.session(for: agent.id, launch: agent.shellCommand) }

    func remember(_ session: String, for agent: AgentConnection) {
        if threads.remember(session, for: agent.id, launch: agent.shellCommand) { save() }
    }

    func forget(_ agent: String) {
        if threads.forget(agent: agent) { save() }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try threads.encoded().write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("couldn't save the talk conversation: \(error.localizedDescription, privacy: .public)")
        }
    }
}
