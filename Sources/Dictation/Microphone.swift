import AudioToolbox
import AVFoundation
import CoreAudio
import DictationCore
import Synchronization

/// The single owner of the input device. Audio lives in memory only. The engine starts and stops on its own
/// queue, because a start can block for hundreds of milliseconds and the key tap shares the main thread.
@MainActor final class Microphone {
    private let device = InputDevice()
    private let sink = SampleSink()
    private var capturing = false
    private var generation = 0
    /// A start that failed after `start(from:)` returned.
    var onFailure: ((any Error) -> Void)?
    /// Where this capture records from, when it starts and again when a device change restarts it.
    var onSource: ((MicrophoneSource) -> Void)?

    /// RMS of the latest converted buffer, for the bar's meter.
    var level: Float { sink.level }

    /// The capture in progress, for previews while the key is held.
    var audio: any LiveAudio { sink }

    static var accessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Asks at launch, so the first dictation is not spent on the permission prompt.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    /// Throws without permission. A missing input device or an engine error arrives later, through `onFailure`.
    func start(from choice: MicrophoneChoice) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Self.requestAccessIfNeeded()
            throw DictationError("Allow microphone access, then dictate again.")
        default:
            throw DictationError("Microphone access is off. Turn on Lip Service in System Settings > Privacy & Security > Microphone.")
        }
        if capturing { cancel() }
        generation += 1
        let current = generation
        capturing = true
        sink.open()
        device.start(feeding: sink, from: choice, failed: { error in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.startFailed(error, generation: current) }
            }
        }, selected: { source in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.selected(source, generation: current) }
            }
        })
    }

    /// Nil when not capturing or nothing arrived.
    func stop(releasedAt: Instant) -> Recording? {
        guard capturing else { return nil }
        capturing = false
        let samples = sink.close()
        device.stop()
        return samples.isEmpty ? nil : Recording(samples: samples, releasedAt: releasedAt)
    }

    func cancel() {
        guard capturing else { return }
        capturing = false
        _ = sink.close()
        device.stop()
    }

    private func startFailed(_ error: any Error, generation failed: Int) {
        guard capturing, failed == generation else { return }
        cancel()
        onFailure?(error)
    }

    private func selected(_ source: MicrophoneSource, generation reported: Int) {
        guard capturing, reported == generation else { return }
        onSource?(source)
    }
}

/// AVAudioEngine, touched only on `queue`. A fresh engine follows the system default input. A chosen device is set
/// on a fresh engine before its first use, so any change of device replaces the engine.
private final class InputDevice: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hunterbohm.dictation.microphone", qos: .userInteractive)
    private var engine = AVAudioEngine()
    /// The device set on `engine`, nil while it follows the default.
    private var pinned: AudioDeviceID?
    private var sink: SampleSink?
    private var choice = MicrophoneChoice.systemDefault
    private var selected: (@Sendable (MicrophoneSource) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init() { observe(engine) }

    func start(feeding sink: SampleSink, from choice: MicrophoneChoice, failed: @escaping @Sendable (any Error) -> Void,
               selected: @escaping @Sendable (MicrophoneSource) -> Void) {
        queue.async { [self] in
            (self.choice, self.selected) = (choice, selected)
            do { try begin(sink) } catch { failed(error) }
        }
    }

    func stop() { queue.async { [self] in end() } }

    private func observe(_ engine: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restartAfterDeviceChange() }
        }
    }

    /// Runs before every start and restart, so a device plugged in or out since is seen.
    private func selectDevice() {
        let inputs = AudioDevices.inputs()
        let source = choice.source(connected: inputs.map(\.uid))
        selected?(source)
        let chosen: AudioDevices.Input?
        switch source {
        case .systemDefault, .fallback:
            chosen = nil
        case .device(let uid):
            chosen = inputs.first { $0.uid == uid }
        }
        guard pinned != chosen?.deviceID else { return }
        engine = AVAudioEngine()
        observe(engine)
        pinned = nil
        guard let chosen else { return }
        if AudioDevices.select(chosen.deviceID, for: engine) {
            pinned = chosen.deviceID
        } else {
            selected?(.fallback(missing: chosen.name))
        }
    }

    private func begin(_ sink: SampleSink) throws {
        end()
        selectDevice()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError("No microphone is available.") }
        // No fixed format, so the tap always matches the hardware. SampleSink converts from each buffer's format.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: sink.tapBlock())
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.sink = sink
    }

    private func end() {
        guard sink != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink = nil
    }

    /// A headset connected mid-capture stops the engine. Restart on the new device and keep appending to the
    /// same samples. If the restart fails, `stop` still returns what was captured.
    private func restartAfterDeviceChange() {
        guard let sink else { return }
        end()
        try? begin(sink)
    }
}

/// The one piece of state shared across threads. The audio thread converts and appends, main takes, and the
/// engine's worker reads the capture in progress.
final class SampleSink: LiveAudio {
    private struct State {
        var open = false
        var converter: SampleConverter?
        var samples: [Float] = []
        var level: Float = 0
    }

    private let state = Mutex(State())

    var level: Float { state.withLock { $0.level } }

    var count: Int { state.withLock { $0.samples.count } }

    func samples(_ range: Range<Int>) -> [Float] {
        state.withLock { Array($0.samples[range.clamped(to: 0..<$0.samples.count)]) }
    }

    func open() { state.withLock { $0 = State(open: true) } }

    /// Returns the samples and drops anything that arrives afterward.
    func close() -> [Float] {
        state.withLock { state in
            defer { state = State() }
            return state.samples
        }
    }

    /// Formed here rather than in Microphone, because a closure formed inside a @MainActor method is inferred
    /// main-actor and traps when the audio thread calls it.
    func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in append(buffer) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        state.withLock { state in
            guard state.open else { return }
            if state.converter?.inputFormat != buffer.format {
                state.converter = try? SampleConverter(from: buffer.format)
            }
            guard let chunk = try? state.converter?.convert(buffer), !chunk.isEmpty else { return }
            state.samples += chunk
            state.level = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }
    }
}
