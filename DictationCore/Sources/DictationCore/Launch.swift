import Foundation

/// What a copy of the app does the moment it starts, given who started it and what else runs. launchd restarts a
/// launch agent's copy after a crash, so every copy that stays should be that copy.
public enum Launch: Equatable, Sendable {
    /// Another copy still runs after the wait, so this one ends and leaves it alone.
    case yield
    /// LaunchServices started this copy, and the agent is on. Ask launchd for its own copy and end, because launchd
    /// restarts only the copy it started.
    case handToAgent
    case run

    public static func decide(startedByLaunchd: Bool, otherCopyRuns: Bool, agentOn: Bool) -> Launch {
        if otherCopyRuns { return .yield }
        return agentOn && !startedByLaunchd ? .handToAgent : .run
    }
}

/// Why the copy before this one handed over, which tells this copy how to start. The copy that hands over leaves a
/// note, and the next copy that starts reads it once.
public enum HandOver: String, Equatable, Sendable {
    /// The user opened the app by hand. It starts as that does, without the quiet start of a login or a crash.
    case opened
    /// The user was in the window, so this copy opens it.
    case window

    /// A note older than this belongs to a hand-over that never finished.
    public static let life: TimeInterval = 30

    public init?(note: String, age: TimeInterval) {
        guard age >= 0, age < Self.life, let reason = Self(rawValue: note) else { return nil }
        self = reason
    }
}
