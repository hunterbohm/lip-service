import DictationCore
import Foundation
import os
import ServiceManagement

/// The launch agent that starts Lip Service at login and starts it again after a crash. It is a plist in the app
/// bundle that tells launchd to restart the app after a crash and never after an exit or a kill, so Quit, a
/// logout and Force Quit leave it quit.
///
/// launchd restarts only a copy it started, and turning the agent off ends that copy. So when the user opens the app
/// by hand while the agent is on, the new copy asks launchd for its own copy and ends, and when the user turns the
/// agent off in launchd's copy, a new copy starts first. A lock lets one copy run at a time, whoever started it.
enum LaunchAgent {
    static let label = "com.hunterbohm.dictation.agent"
    static var service: SMAppService { .agent(plistName: "\(label).plist") }

    /// launchd puts a job's label in its environment. LaunchServices, a shell and an ssh session do not.
    static let startedByLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label

    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "login")

    /// How long a copy waits for the copy that is ending to let go of the lock.
    private static let handOverWait = 3.0
    private static let lockFile = SupportFolder.url.appending(path: "running.lock")
    private static let handOverFile = SupportFolder.url.appending(path: "hand-over")

    nonisolated(unsafe) static private(set) var handedOver: HandOver?

    /// Called first when the app starts. False means this copy ends now. A test run never claims, so it can run
    /// beside the real app. Starting the agent's job does nothing when it runs already, as it does after the agent has
    /// just been registered, and that copy takes over when this one ends.
    static func claim() -> Bool {
        guard SettingsStore.isReal else { return true }
        SupportFolder.makePrivate()
        let locked = takeLock(waiting: handOverWait)
        if locked { handedOver = takeHandOver() }
        if locked, !startedByLaunchd { moveOldLoginItem() }
        switch Launch.decide(startedByLaunchd: startedByLaunchd, otherCopyRuns: !locked, agentOn: service.status == .enabled) {
        case .yield: return false
        case .run: return true
        case .handToAgent:
            leaveHandOver(handedOver ?? .opened)
            if run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"]) { return false }
            try? FileManager.default.removeItem(at: handOverFile)
            return true
        }
    }

    static func isOn(_ status: SMAppService.Status) -> Bool { status == .enabled || status == .requiresApproval }

    /// Takes the agent and the old login item to `on`, and does nothing for one that is there already. Turning on, the
    /// agent comes first, so when it cannot be registered the old item keeps starting the app. Turning off, the agent
    /// comes last, because it ends the copy that launchd started.
    static func set(_ on: Bool) throws {
        let oldItem = SMAppService.mainApp
        if on {
            if !isOn(service.status) { try service.register() }
            if isOn(oldItem.status) { try oldItem.unregister() }
        } else {
            if isOn(oldItem.status) { try oldItem.unregister() }
            if isOn(service.status) {
                if startedByLaunchd { try startCopyToTakeOver() }
                try service.unregister()
            }
        }
    }

    /// `Dictation --login-status`: what macOS holds to start the app at login, for a script to read.
    static func report() -> Int32 {
        func name(_ status: SMAppService.Status) -> String {
            switch status {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notFound: "notFound"
            @unknown default: "unknown"
            }
        }
        print("launch agent: \(name(service.status))")
        print("old login item: \(name(SMAppService.mainApp.status))")
        return 0
    }

    /// Earlier versions made the app itself the login item, which nothing restarts after a crash. A user who has that
    /// gets the agent instead, at the first launch, so the same launch can hand over to it.
    private static func moveOldLoginItem() {
        guard isOn(SMAppService.mainApp.status) else { return }
        do { try set(true) } catch { log.error("could not move the login item to the launch agent: \(error.localizedDescription)") }
    }

    /// Turning the agent off ends launchd's copy, so a copy that nobody restarts takes over first. It waits for the
    /// lock this copy holds.
    private static func startCopyToTakeOver() throws {
        leaveHandOver(.window)
        guard run("/usr/bin/open", ["-n", Bundle.main.bundleURL.path]) else {
            try? FileManager.default.removeItem(at: handOverFile)
            throw DictationError("Lip Service could not start a copy to take over, so the setting is still on.")
        }
    }

    /// Holds the lock until the process ends, and closes it on exec so nothing the app starts keeps it. A lock that
    /// cannot be made lets the app run, rather than never start.
    private static func takeLock(waiting seconds: Double) -> Bool {
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        let deadline = Date.now.addingTimeInterval(seconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { return true }
            if Date.now >= deadline {
                close(descriptor)
                return false
            }
            usleep(50_000)
        }
        return true
    }

    private static func leaveHandOver(_ reason: HandOver) {
        try? reason.rawValue.write(to: handOverFile, atomically: true, encoding: .utf8)
    }

    private static func takeHandOver() -> HandOver? {
        defer { try? FileManager.default.removeItem(at: handOverFile) }
        guard let note = try? String(contentsOf: handOverFile, encoding: .utf8),
              let written = (try? handOverFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return HandOver(note: note, age: Date.now.timeIntervalSince(written))
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
