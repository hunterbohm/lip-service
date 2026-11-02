import Foundation
import os

extension Process {
    struct Finished {
        var status: Int32
        var output: Data
        var errors: Data
        var timedOut: Bool
    }

    /// Runs a program to its end off the main thread: writes `input` to it, collects what it prints, and stops it if it
    /// runs past `timeout`.
    static func runToEnd(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, input: Data,
                         timeout: Double) async throws -> Finished {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let output = Collected(), errors = Collected(), timedOut = OSAllocatedUnfairLock(initialState: false)
        let drained = DispatchGroup()
        for (pipe, sink) in [(stdout, output), (stderr, errors)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    sink.append(data)
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                // A child of the program may hold its output open; what arrived by now is enough.
                _ = drained.wait(timeout: .now() + 1)
                continuation.resume(returning: Finished(status: process.terminationStatus, output: output.data, errors: errors.data,
                                                        timedOut: timedOut.withLock { $0 }))
            }
            do {
                try process.run()
            } catch {
                return continuation.resume(throwing: error)
            }
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.withLock { $0 = true }
                process.stop(grace: 1)
            }
        }
    }

    /// SIGTERM, which Process sends to the process group it started the child in, then SIGKILL to that group after
    /// `grace` if the child is still running. The Process object knows whether its child has exited, so a pid the
    /// system has since handed to another program is never signalled.
    func stop(grace: Double = 2) {
        guard isRunning else { return }
        let group = processIdentifier
        terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if isRunning { kill(-group, SIGKILL) }
        }
    }

    private final class Collected: Sendable {
        private let buffer = OSAllocatedUnfairLock(initialState: Data())
        func append(_ data: Data) { buffer.withLock { $0.append(data) } }
        var data: Data { buffer.withLock { $0 } }
    }
}
