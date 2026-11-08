import AVFoundation
import DictationCore
import FluidAudio
import Foundation
import os
import Synchronization

/// A line of speech: mono samples at their own rate.
struct VoiceClip: Sendable {
    var samples: [Float]
    var sampleRate: Double
    var seconds: Double { Double(samples.count) / sampleRate }
}

/// Turns a line into speech. A talk asks for one line at a time, in order, and plays each while it asks for the next.
/// A hosted voice can be added as another provider.
protocol VoiceProvider: Sendable {
    /// Loads or downloads what the voice needs, so the first line is quick.
    func prepare() async throws
    func speak(_ text: String) async throws -> VoiceClip
}

enum Voices {
    static func provider(for choice: TalkVoiceChoice) -> any VoiceProvider {
        switch choice {
        case .onMac(let voice): OnMacVoiceProvider(voice: voice)
        case .server(let url, let voice): ServerVoiceProvider(base: url, voice: voice)
        }
    }
}

/// A voice made on this Mac with FluidAudio. The model stays loaded for a while after a talk, so the next one starts at
/// once, and is let go after `keepLoaded` seconds with no talk.
struct OnMacVoiceProvider: VoiceProvider {
    let voice: OnMacVoice

    func prepare() async throws { _ = try await OnMacVoices.shared.kokoro(for: voice) }

    func speak(_ text: String) async throws -> VoiceClip {
        let manager = try await OnMacVoices.shared.kokoro(for: voice)
        let result = try await manager.synthesizeDetailed(text: text, voice: voice.voice)
        return VoiceClip(samples: result.samples, sampleRate: Double(result.sampleRate))
    }
}

actor OnMacVoices {
    static let shared = OnMacVoices()
    static let keepLoaded = 10.0 * 60
    private var loaded: (voice: OnMacVoice, manager: KokoroAneManager)?
    private var loading: (voice: OnMacVoice, task: Task<KokoroAneManager, any Error>)?
    private var release: Task<Void, Never>?
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "talk")

    func kokoro(for voice: OnMacVoice) async throws -> KokoroAneManager {
        release?.cancel()
        release = nil
        guard voice.model == .kokoro else {
            throw DictationError("The \(voice.voice) voice needs a newer FluidAudio than this build has. Pick a Kokoro voice in Settings.")
        }
        if let loaded, loaded.voice == voice { return loaded.manager }
        if let loading, loading.voice == voice { return try await loading.task.value }
        let task = Task { () throws -> KokoroAneManager in
            let started = Instant.now
            let manager = KokoroAneManager(variant: .english, defaultVoice: voice.voice)
            try await manager.initialize(preloadVoices: [voice.voice])
            // The first line through a freshly loaded chain is slow, so a short one goes through it now.
            _ = try await manager.synthesizeDetailed(text: "Hello, I'm ready when you are.", voice: voice.voice)
            Logger(subsystem: "com.hunterbohm.dictation", category: "talk")
                .info("voice \(voice.id, privacy: .public) ready in \(Instant.now - started, format: .fixed(precision: 2)) s")
            return manager
        }
        loading = (voice, task)
        do {
            let manager = try await task.value
            if loading?.voice == voice { loading = nil }
            if let old = loaded, old.voice != voice { await old.manager.cleanup() }
            loaded = (voice, manager)
            return manager
        } catch {
            if loading?.voice == voice { loading = nil }
            throw DictationError("The voice didn't load: \(error.localizedDescription)")
        }
    }

    /// A talk ended. The model goes after `keepLoaded` seconds unless another talk starts.
    func idle() {
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keepLoaded))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() async {
        release = nil
        guard let loaded else { return }
        self.loaded = nil
        await loaded.manager.cleanup()
        log.info("voice \(loaded.voice.id, privacy: .public) unloaded")
    }
}

/// A voice server, such as one on a PC with a GPU: `POST /speak` with `{text, voice, format: "wav"}` answers with a WAV.
struct ServerVoiceProvider: VoiceProvider {
    let base: String
    let voice: String

    private var url: URL {
        get throws {
            guard let url = TalkVoiceChoice.speakURL(base) else { throw DictationError("The voice server's address isn't a web address: \(base)") }
            return url
        }
    }

    /// Asks for a short line, which also tells whether the server is up.
    func prepare() async throws { _ = try await speak("Okay.") }

    func speak(_ text: String) async throws -> VoiceClip {
        var request = URLRequest(url: try url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["text": text, "format": "wav"]
        if !voice.isEmpty { body["voice"] = voice }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw DictationError("The voice server didn't answer: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DictationError("The voice server answered with error \(http.statusCode).")
        }
        guard let wav = WAVFile.decode(data), !wav.samples.isEmpty else { throw DictationError("The voice server sent back audio Lip Service can't read.") }
        return VoiceClip(samples: wav.samples, sampleRate: Double(wav.sampleRate))
    }
}

/// Where a talk's speech goes: the speakers, or, for the end-to-end test, nowhere at the speed it would play.
@MainActor protocol TalkSpeaker: AnyObject {
    /// A clip started playing, with the words it says.
    var onStarted: ((String) -> Void)? { get set }
    /// Everything queued has played.
    var onIdle: (() -> Void)? { get set }
    /// The level of what is playing, 0 to 1 on the microphone's RMS scale, for the bar.
    var level: Float { get }
    var isPlaying: Bool { get }
    func start() throws
    func play(_ clip: VoiceClip, caption: String)
    /// Stops at once and drops what is queued.
    func stop()
    func close()
}

/// The speakers, on an audio engine of its own. The microphone keeps its own engine, because picking an input device on
/// an engine that also plays breaks its output. The engine runs only during a talk.
@MainActor final class SpeakerOut: TalkSpeaker {
    var onStarted: ((String) -> Void)?
    var onIdle: (() -> Void)?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var queue: [String] = []
    private var generation = 0
    private var observer: (any NSObjectProtocol)?
    private let meter = PlayingLevel()
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "talk")

    var level: Float { isPlaying ? meter.value : 0 }
    var isPlaying: Bool { !queue.isEmpty }

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: meter.tapBlock())
        engine.prepare()
        try engine.start()
        player.play()
        (self.engine, self.player) = (engine, player)
        // A new output, such as headphones plugged in, stops the engine. It starts again on the new one; what was
        // queued is lost, and the talk goes on.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func restart() {
        guard let engine, let player else { return }
        log.info("speaker output changed, restarting")
        dropQueue()
        do {
            try engine.start()
            player.play()
        } catch {
            log.error("speaker did not restart: \(error.localizedDescription, privacy: .public)")
        }
    }

    func play(_ clip: VoiceClip, caption: String) {
        guard let player, let buffer = buffer(for: clip) else { return }
        queue.append(caption)
        if queue.count == 1 { onStarted?(caption) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.whenPlayed(generation, by: self))
    }

    /// Formed outside the main actor, as `PlayingLevel.tapBlock` is, because AVFAudio calls it on its own thread and a
    /// closure formed in a main-actor method traps there.
    nonisolated private static func whenPlayed(_ current: Int, by speaker: SpeakerOut) -> AVAudioPlayerNodeCompletionHandler {
        { [weak speaker] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { speaker?.played(current) } }
        }
    }

    private func played(_ played: Int) {
        guard played == generation, !queue.isEmpty else { return }
        queue.removeFirst()
        if let next = queue.first { onStarted?(next) } else { onIdle?() }
    }

    func stop() {
        dropQueue()
        player?.stop()
        player?.play()
    }

    private func dropQueue() {
        generation += 1
        let wasPlaying = !queue.isEmpty
        queue = []
        meter.value = 0
        if wasPlaying { onIdle?() }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        generation += 1
        queue = []
        player?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        (engine, player) = (nil, nil)
    }

    private func buffer(for clip: VoiceClip) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
              let raw = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { return nil }
        raw.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { raw.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        if clip.sampleRate == format.sampleRate { return raw }
        guard let converter = AVAudioConverter(from: source, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(clip.samples.count) * format.sampleRate / clip.sampleRate) + 64)
        else { return nil }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = raw
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? out : nil
    }
}

/// The level of what plays, written on the audio thread and read on main.
private final class PlayingLevel: Sendable {
    private let level = Mutex<Float>(0)
    var value: Float {
        get { level.withLock { $0 } }
        set { level.withLock { $0 = newValue } }
    }

    /// Formed here rather than in SpeakerOut, because a closure formed inside a main-actor method is inferred main-actor
    /// and traps when the audio thread calls it.
    func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            value = (sum / Float(buffer.frameLength)).squareRoot()
        }
    }
}

/// Plays nothing, but takes each clip's real length, so the end-to-end test's turns time like a real talk. Keeps what
/// it was given, to write out as a WAV.
@MainActor final class SilentSpeaker: TalkSpeaker {
    var onStarted: ((String) -> Void)?
    var onIdle: (() -> Void)?
    private var queue: [(clip: VoiceClip, caption: String)] = []
    private var generation = 0
    private(set) var recorded: [Float] = []
    private(set) var recordedRate = 24_000.0

    var level: Float { isPlaying ? 0.1 : 0 }
    var isPlaying: Bool { !queue.isEmpty }

    func start() throws {}

    func play(_ clip: VoiceClip, caption: String) {
        queue.append((clip, caption))
        recordedRate = clip.sampleRate
        recorded += clip.samples + [Float](repeating: 0, count: Int(clip.sampleRate * 0.15))
        if queue.count == 1 { begin() }
    }

    private func begin() {
        guard let first = queue.first else {
            onIdle?()
            return
        }
        onStarted?(first.caption)
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(first.clip.seconds))
            guard let self, current == generation else { return }
            queue.removeFirst()
            begin()
        }
    }

    func stop() {
        generation += 1
        let wasPlaying = !queue.isEmpty
        queue = []
        if wasPlaying { onIdle?() }
    }

    func close() { stop() }
}
