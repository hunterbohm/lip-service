import AudioToolbox
import AVFoundation
import CatchException
import CoreAudio
import DictationCore
import os
import Synchronization

/// The single owner of the input device. Audio lives in memory only. The engine starts and stops on its own
/// queue, because a start can block for hundreds of milliseconds and the key tap shares the main thread.
@MainActor final class Microphone {
    private let sink = SampleSink()
    private let device: InputDevice
    private var capturing = false
    private var generation = 0
    private var startedAt = Instant.now
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "microphone")
    /// A start that failed after `start(from:)` returned.
    var onFailure: ((any Error) -> Void)?
    /// Where this capture records from, when it starts and again when a device change restarts it.
    var onSource: ((MicrophoneSource) -> Void)?

    /// RMS of the latest converted buffer, for the bar's meter.
    var level: Float { sink.level }

    /// The capture in progress, for previews while the key is held.
    var audio: any LiveAudio { sink }

    /// When the first sample of the capture in progress was recorded.
    var firstAudio: Instant? { sink.firstAudio }

    init() { device = InputDevice(feeding: sink) }

    static var accessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Asks at launch, so the first dictation is not spent on the permission prompt.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    /// Readies the device `choice` records from, so the next start only starts it. Each stop readies it again.
    func prepare(_ choice: MicrophoneChoice) { device.prepare(choice) }

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
        startedAt = .now
        sink.open()
        device.start(from: choice, failed: { error in
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
        if let ready = sink.firstAudio { log.info("microphone ready \(ready - self.startedAt, format: .fixed(precision: 3)) s after key-down") }
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

/// AVAudioEngine, touched only on `queue`. An engine serves one device: a stopped engine keeps the input format it first
/// read, and its next start fails once that device changes rate or is replaced. So the engine for the next capture is
/// built while idle, pointed at the device it will record from, with its tap installed and prepared, and a key-down only
/// starts it, which takes about 40 ms on the Mac's microphone and 60 ms on a USB one. Building it at key-down took 75 ms
/// more. A Bluetooth microphone is built at key-down, because a prepared one holds the headset in call quality. A capture
/// stays on the device it started on until that device is gone.
private final class InputDevice: @unchecked Sendable {
    /// The device an engine points at and the format its tap takes. A device plugged back in has a new ID, so a ready
    /// engine is kept only for an equal input.
    private struct Binding {
        let input: AudioDevices.Input
        let format: AVAudioFormat
    }

    private enum Phase {
        case idle
        /// Prepared with the tap installed, not started.
        case ready(Binding)
        case running(Binding)

        var binding: (binding: Binding, running: Bool)? {
            switch self {
            case .idle: nil
            case .ready(let binding): (binding, false)
            case .running(let binding): (binding, true)
            }
        }
    }

    private let queue = DispatchQueue(label: "com.hunterbohm.dictation.microphone", qos: .userInteractive)
    private let sink: SampleSink
    private var engine = AVAudioEngine()
    private var phase = Phase.idle
    /// What the next start records from. Nil until the first prepare or start.
    private var choice: MicrophoneChoice?
    private var selected: (@Sendable (MicrophoneSource) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init(feeding sink: SampleSink) {
        self.sink = sink
        AudioDevices.onDeviceListChange(queue: queue) { [weak self] in self?.prepareIfIdle() }
        AudioDevices.onDefaultInputChange(queue: queue) { [weak self] in self?.prepareIfIdle() }
    }

    func prepare(_ choice: MicrophoneChoice) {
        queue.async { [self] in
            self.choice = choice
            prepareIfIdle()
        }
    }

    func start(from choice: MicrophoneChoice, failed: @escaping @Sendable (any Error) -> Void,
               selected: @escaping @Sendable (MicrophoneSource) -> Void) {
        queue.async { [self] in
            (self.choice, self.selected) = (choice, selected)
            do { try begin() } catch { failed(error) }
        }
    }

    /// Stops recording and readies the engine for the next start.
    func stop() {
        queue.async { [self] in
            end()
            prepareIfIdle()
        }
    }

    private func observe(_ engine: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.configurationChanged() }
        }
    }

    /// Reads the devices again, so one plugged in or out since is seen.
    private func begin() throws {
        let inputs = AudioDevices.inputs()
        let source = choice.map { AudioDevices.source(for: $0, among: inputs) } ?? .systemDefault
        selected?(source)
        let target = Self.target(of: source, among: inputs)
        if case .ready(let binding) = phase, binding.input == target, isCurrent(binding), (try? engine.start()) != nil {
            phase = .running(binding)
            return
        }
        end()
        let (binding, bound) = try point(at: target, among: inputs)
        if !bound, case .device = source, let target { selected?(.fallback(missing: target.name)) }
        try arm(binding, start: true)
    }

    /// Readies an engine for the next start when nothing records, the app may record, and the choice resolves to a wired
    /// or built-in microphone. Every device change calls it again, and a ready engine that still fits is kept.
    private func prepareIfIdle() {
        guard let choice, phase.binding?.running != true, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        else { return }
        let inputs = AudioDevices.inputs()
        let target = Self.target(of: AudioDevices.source(for: choice, among: inputs), among: inputs)
        if case .ready(let binding) = phase, binding.input == target, isCurrent(binding) { return }
        end()
        guard let target, target.kind != .bluetooth, case let (binding, bound)? = try? point(at: target, among: inputs), bound
        else { return }
        try? arm(binding, start: false)
    }

    /// The input a source records from: the chosen one, or the system default.
    private static func target(of source: MicrophoneSource, among inputs: [AudioDevices.Input]) -> AudioDevices.Input? {
        if case .device(let uid) = source { inputs.first { $0.uid == uid } } else { AudioDevices.defaultInput(among: inputs) }
    }

    /// A fresh engine pointed at `target`, or left on the system default when CoreAudio refuses it. True when it points at
    /// `target`.
    private func point(at target: AudioDevices.Input?, among inputs: [AudioDevices.Input]) throws -> (Binding, Bool) {
        engine = AVAudioEngine()
        let bound = target.map { AudioDevices.select($0.deviceID, for: engine) } ?? false
        if bound { settleAfterPicking() }
        observe(engine)
        let device = bound ? target : AudioDevices.current(of: engine).flatMap { id in inputs.first { $0.deviceID == id } }
        // The hardware format, because a chosen device leaves the node's output format at the rate of the device the
        // engine opened with, and a tap in that format fails to start. SampleSink converts from each buffer's format.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard let device, format.sampleRate > 0, format.channelCount > 0 else { throw DictationError("No microphone is available.") }
        return (Binding(input: device, format: format), bound)
    }

    /// Installs the tap and prepares the engine, then starts it or leaves it ready.
    private func arm(_ binding: Binding, start: Bool) throws {
        let input = engine.inputNode
        try input.installTapOrThrow(bufferSize: 1024, format: binding.format, block: sink.tapBlock())
        engine.prepare()
        if start {
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        }
        phase = start ? .running(binding) : .ready(binding)
    }

    /// The engine still points at the binding's device, in the format its tap takes.
    private func isCurrent(_ binding: Binding) -> Bool {
        AudioDevices.current(of: engine) == binding.input.deviceID && engine.inputNode.inputFormat(forBus: 0) == binding.format
    }

    /// The longest a start waits for the change that picking a device posts.
    private static let settleLimit = 0.15

    /// Pointing a fresh engine at a device whose rate differs from the one it opened with posts a configuration change
    /// once the engine is prepared, and that change stops a started engine. Waiting for it here lets the engine start
    /// once. Restarting after it instead lost the first ~0.14 s after key-down. Any later change still restarts.
    private func settleAfterPicking() {
        let input = engine.inputNode
        guard input.inputFormat(forBus: 0).sampleRate != input.outputFormat(forBus: 0).sampleRate else { return }
        let changed = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { _ in changed.signal() }
        engine.prepare()
        _ = changed.wait(timeout: .now() + Self.settleLimit)
        NotificationCenter.default.removeObserver(observer)
    }

    /// Stops the engine, ready or running, and removes its tap.
    private func end() {
        guard phase.binding != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        phase = .idle
    }

    /// A configuration change stops the engine, and a headset connecting posts one even to an engine on another device.
    /// A capture restarts on the device it started on and keeps appending to the same samples. It moves only when that
    /// device is gone, and if the restart fails, `stop` still returns what was captured. A change that leaves the device
    /// and its format as they were, such as the one picking a device posts when it comes after `settleAfterPicking` gave
    /// up, rearms the same engine. A fresh engine would select the device again, post another change, and never settle.
    private func configurationChanged() {
        guard case let (binding, running)? = phase.binding else { return }
        let unchanged = isCurrent(binding)
        end()
        if unchanged, (try? arm(binding, start: running)) != nil { return }
        guard running else { return prepareIfIdle() }
        let inputs = AudioDevices.inputs()
        if let same = inputs.first(where: { $0.uid == binding.input.uid }), case let (moved, bound)? = try? point(at: same, among: inputs),
           bound, (try? arm(moved, start: true)) != nil { return }
        try? begin()
    }
}

extension AVAudioNode {
    /// AVAudioEngine raises an Objective-C exception when the tap's format no longer matches the hardware. A Bluetooth
    /// headset switching its microphone between 48 and 24 kHz does that between reading the format and this call.
    func installTapOrThrow(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) throws {
        guard LSCatchException({ installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block) }) == nil else {
            throw DictationError("The microphone changed while starting. Dictate again.")
        }
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
        var firstAudio: Instant?
    }

    private let state = Mutex(State())

    var level: Float { state.withLock { $0.level } }

    var firstAudio: Instant? { state.withLock { $0.firstAudio } }

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
        { [self] buffer, when in append(buffer, at: when) }
    }

    private func append(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        state.withLock { state in
            guard state.open else { return }
            if state.converter?.inputFormat != buffer.format {
                state.converter = try? SampleConverter(from: buffer.format)
            }
            guard let chunk = try? state.converter?.convert(buffer), !chunk.isEmpty else { return }
            if state.firstAudio == nil {
                state.firstAudio = when.isHostTimeValid ? Instant(seconds: AVAudioTime.seconds(forHostTime: when.hostTime)) : .now
            }
            state.samples += chunk
            state.level = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }
    }
}
