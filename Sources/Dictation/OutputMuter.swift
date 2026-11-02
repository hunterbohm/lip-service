import AppKit
import DictationCore
import os

/// Mutes the Mac's default output while you talk, for the Mute other audio setting. CoreAudio calls run in order on
/// their own queue. A marker file lists every output muted and not yet unmuted, so an output that was gone when its
/// sound should have come back, or a crash, is unmuted later: at the next launch, on wake, or when the device list
/// changes. SIGTERM and quitting unmute before the app exits, waiting at most `quitWait` for CoreAudio.
@MainActor final class OutputMuter {
    private static let quitWait = 1.0
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "dictation")
    private var state = OutputMute()
    private let queue = DispatchQueue(label: "com.hunterbohm.dictation.output-mute")
    private let marker: Marker
    private var terminationSignal: DispatchSourceSignal?

    init(marker: URL = SupportFolder.url.appending(path: "muted-output.txt")) {
        self.marker = Marker(url: marker)
        restoreListed()
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopNow() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreListed() }
        }
        AudioDevices.onDeviceListChange(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.restoreListed() }
        }
    }

    /// Listening began. The output is muted once the start cue, `cue` seconds long, has played.
    func listen(afterCue cue: Double) {
        restoreListed()
        let serial = state.listen()
        Task { [weak self, queue] in
            try? await Task.sleep(for: .seconds(cue))
            let output = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: AudioDevices.defaultOutputMute()) }
            }
            guard let self, let action = state.cueEnded(serial, output: output) else { return }
            apply(action, then: nil)
        }
    }

    /// Listening ended or the setting went off. `then` runs once the sound is back, or at once if nothing was muted,
    /// so a stop cue passed here is heard.
    func stop(then: (@MainActor @Sendable () -> Void)? = nil) {
        guard let action = state.stop() else {
            then?()
            return
        }
        apply(action, then: then)
    }

    private func apply(_ action: OutputMute.Action, then: (@MainActor @Sendable () -> Void)?) {
        switch action {
        case .mute(let device):
            watchTermination(true)
            queue.async { [marker] in
                marker.change { $0.add(device) }
                if !AudioDevices.setOutputMute(true, uid: device) { marker.change { $0.remove(device) } }
            }
        case .unmute(let device):
            watchTermination(false)
            queue.async { [marker] in
                let unmuted = marker.unmute(device)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.log.info("output unmuted: \(unmuted, privacy: .public)")
                        then?()
                    }
                }
            }
        }
    }

    /// Unmutes every listed output but the one held muted for the capture in progress.
    private func restoreListed() {
        let held: String? = if case .muted(let device) = state.phase { device } else { nil }
        queue.async { [marker] in
            for device in marker.listed().devices where device != held { _ = marker.unmute(device) }
        }
    }

    /// For quitting and SIGTERM, which must not exit before the sound is back, nor hang on a stuck CoreAudio call. It
    /// also waits for an unmute already queued. An output still muted at the deadline stays listed for the next launch.
    private func stopNow() {
        if case .unmute(let device) = state.stop() {
            watchTermination(false)
            queue.async { [marker] in _ = marker.unmute(device) }
        }
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        if done.wait(timeout: .now() + Self.quitWait) == .timedOut { Self.log.error("quit before the output was unmuted") }
    }

    /// SIGTERM ends the app without running anything, so while the output is muted it unmutes first and then exits.
    private func watchTermination(_ on: Bool) {
        terminationSignal?.cancel()
        terminationSignal = nil
        signal(SIGTERM, on ? SIG_IGN : SIG_DFL)
        guard on else { return }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.stopNow() }
            exit(0)
        }
        source.resume()
        terminationSignal = source
    }

    /// The marker file. Used only on `queue`.
    private struct Marker: Sendable {
        let url: URL

        func listed() -> MutedOutputs { MutedOutputs(text: try? String(contentsOf: url, encoding: .utf8)) }

        func change(_ edit: (inout MutedOutputs) -> Void) {
            var outputs = listed()
            edit(&outputs)
            if let text = outputs.text { try? text.write(to: url, atomically: true, encoding: .utf8) } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        /// True when the output is unmuted and no longer listed.
        func unmute(_ device: String) -> Bool {
            guard AudioDevices.setOutputMute(false, uid: device) else { return false }
            change { $0.remove(device) }
            return true
        }
    }
}
