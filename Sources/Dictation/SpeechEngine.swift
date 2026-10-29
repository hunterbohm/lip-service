import DictationCore
import FluidAudio
import Foundation
import Synchronization

/// Audio still being captured. It only grows while one capture lasts. The engine reads it on its worker.
protocol LiveAudio: Sendable {
    var count: Int { get }
    /// The samples of `range` that exist, so fewer when the capture ended or restarted meanwhile.
    func samples(_ range: Range<Int>) -> [Float]
}

/// The single owner of FluidAudio: download, compile, residency, vocabulary boosting, and the text finishing
/// that depends on the vocabulary. One worker task drains one job stream, and the FluidAudio objects exist only
/// as that task's locals. A warmup or preview never overlaps a transcription and a vocabulary rebuild never lands
/// mid-dictation, even though AsrManager is reentrant at its awaits.
final class SpeechEngine: Sendable {
    struct Options: Sendable {
        /// Key-down warms the model only after this much idle time.
        var warmAfterIdle = 2.0
        var models = ModelStore(directory: ModelStore.defaultDirectory)
    }

    /// Measured on the M4 mini over the bench clips: with a preview every 0.3 s, release to text stayed at
    /// p50 0.24 s, the same as without previews, because they keep the model warm.
    static let previewInterval = Duration.milliseconds(300)

    fileprivate enum Job: Sendable {
        case warm
        case configure(Vocabulary?)
        case preview(any LiveAudio, CheckedContinuation<String?, Never>)
        case dictate(Recording, CheckedContinuation<Dictation, any Error>)
    }

    /// For one consumer. Keeps only the newest value.
    let statuses: AsyncStream<EngineStatus>
    private let jobs: AsyncStream<Job>.Continuation
    private let retries: AsyncStream<Void>.Continuation
    private let queuedDictations: DictationCount

    /// Starts loading at once.
    init(vocabulary: Vocabulary?, options: Options = Options()) {
        let (jobStream, jobs) = AsyncStream.makeStream(of: Job.self)
        let (retryStream, retries) = AsyncStream.makeStream(of: Void.self)
        let (statuses, status) = AsyncStream.makeStream(of: EngineStatus.self, bufferingPolicy: .bufferingNewest(1))
        let queued = DictationCount()
        (self.jobs, self.retries, self.statuses, self.queuedDictations) = (jobs, retries, statuses, queued)
        Task.detached(priority: .userInitiated) {
            await Worker.run(jobs: jobStream, retries: retryStream, vocabulary: vocabulary, options: options,
                             queued: queued, onStatus: { status.yield($0) })
        }
    }

    /// Key-down. Never blocks.
    func prepare() { jobs.yield(.warm) }

    /// The words so far, without boosting, from the newest 15 s of a capture, so the cost stays flat however long
    /// it runs. Nil, without decoding, when a dictation is queued. After answering, the worker computes any
    /// boosting window the capture has completed, so release pays only for the last one.
    func preview(_ audio: any LiveAudio) async -> String? {
        await withCheckedContinuation { jobs.yield(.preview(audio, $0)) }
    }

    /// Previews every `previewInterval` until the consuming task is cancelled. A preview in flight then still
    /// finishes on the worker, and its text is dropped.
    func previews(of audio: any LiveAudio) -> AsyncStream<String> {
        AsyncStream { continuation in
            let producer = Task { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.previewInterval)
                    if !Task.isCancelled, let text = await preview(audio) { continuation.yield(text) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Release. Runs after any load or warmup ahead of it. A dictation made before the model is ready waits here
    /// with its audio in memory. After a load failure it waits for `retry()`.
    func dictate(_ recording: Recording) async throws -> Dictation {
        queuedDictations.add(1)
        return try await withCheckedThrowingContinuation { jobs.yield(.dictate(recording, $0)) }
    }

    /// Vocabulary saved or toggled. Applied between jobs, so each dictation sees one vocabulary.
    func configure(vocabulary: Vocabulary?) { jobs.yield(.configure(vocabulary)) }

    func retry() { retries.yield() }
}

/// Dictations yielded but not yet started, so a queued warmup or preview can tell that a dictation waits behind it.
private final class DictationCount: Sendable {
    private let value = Atomic<Int>(0)
    func add(_ n: Int) { value.wrappingAdd(n, ordering: .relaxed) }
    var isZero: Bool { value.load(ordering: .relaxed) == 0 }
}

private struct LogProbs: Sendable {
    var frames: [[Float]]
    var frameDuration: Double
}

/// A boosting window computed while the key was held, with the audio it came from, so release reuses it only
/// for the same audio.
private struct CachedWindow: Sendable {
    var range: Range<Int>
    var audio: [Float]
    var logProbs: LogProbs
}

/// Vocabulary boosting in two halves, which together do what `VocabularyBoostingSession.rescore` does in one call.
/// The CTC model's log-probabilities depend only on audio, so they can be computed before release. Rescoring
/// needs the final transcript.
private struct Booster: Sendable {
    private static let noTerms = CustomVocabularyContext(terms: [])

    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let thresholds: ContextBiasingConstants.VocabSizeConfig

    /// The session is built only to tokenize the terms, which FluidAudio does not expose on its own.
    init(vocabulary: Vocabulary, ctc: CtcModels, directory: URL) async throws {
        let context = CustomVocabularyContext(terms: vocabulary.terms.map { CustomVocabularyTerm(text: $0.text) },
                                              minSimilarity: Float(vocabulary.minSimilarity))
        let tokenized = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc).vocabulary
        self.vocabulary = tokenized
        spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: tokenized, config: .default,
                                                       ctcModelDirectory: directory)
        thresholds = ContextBiasingConstants.rescorerConfig(forVocabSize: tokenized.terms.count)
    }

    /// One model run over at most 15 s.
    func logProbs(_ samples: [Float]) async throws -> LogProbs {
        let result = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: Self.noTerms)
        return LogProbs(frames: result.logProbs, frameDuration: result.frameDuration)
    }

    /// The whole recording's log-probabilities, run window by window the way FluidAudio runs them, reusing the
    /// windows computed while the key was held. Nil on a model failure, which turns boosting off for this
    /// dictation and nothing else.
    func logProbs(_ samples: [Float], reusing cached: [CachedWindow]) async -> LogProbs? {
        var windows: [LogProbs] = []
        for (index, range) in CtcWindows.ranges(count: samples.count).enumerated() {
            if index < cached.count, cached[index].range == range, cached[index].audio.elementsEqual(samples[range]) {
                windows.append(cached[index].logProbs)
            } else {
                guard let computed = try? await logProbs(Array(samples[range])) else { return nil }
                windows.append(computed)
            }
        }
        guard let first = windows.first else { return nil }
        return LogProbs(frames: CtcWindows.merge(windows.map(\.frames), frameDuration: first.frameDuration,
                                                 sampleRate: Recording.sampleRate),
                        frameDuration: first.frameDuration)
    }

    /// The rescored text, when the rescorer replaced anything.
    func rescore(_ result: ASRResult, with logProbs: LogProbs) -> String? {
        guard let timings = result.tokenTimings, !timings.isEmpty, !logProbs.frames.isEmpty else { return nil }
        let output = rescorer.ctcTokenRescore(transcript: result.text, tokenTimings: timings, logProbs: logProbs.frames,
                                              frameDuration: logProbs.frameDuration, cbw: thresholds.cbw,
                                              marginSeconds: 0.5,
                                              minSimilarity: max(thresholds.minSimilarity, vocabulary.minSimilarity))
        return output.wasModified ? output.text : nil
    }
}

/// Exists only inside the worker task.
private struct Worker {
    /// FluidAudio rejects audio under 0.3 s. Padding to 1 s costs nothing, since it pads to 15 s internally.
    static let minimumSamples = 16_000
    static let previewSamples = 15 * 16_000

    let asr: AsrManager
    let store: ModelStore
    var ctc: CtcModels?
    var booster: Booster?
    var finisher: TextFinisher
    /// Nil until the first model run after loading, which counts as idle.
    var lastRun: Instant?
    /// Boosting windows of the capture in progress, in order from the first.
    var windows: [CachedWindow] = []

    static func run(jobs: AsyncStream<SpeechEngine.Job>, retries: AsyncStream<Void>, vocabulary: Vocabulary?,
                    options: SpeechEngine.Options, queued: DictationCount,
                    onStatus: @escaping @Sendable (EngineStatus) -> Void) async {
        var retryRequests = retries.makeAsyncIterator()
        var worker: Worker
        while true {
            do {
                worker = try await load(vocabulary, options.models, onStatus)
                break
            } catch {
                onStatus(.failed(error.localizedDescription))
                _ = await retryRequests.next()
            }
        }
        for await job in jobs {
            switch job {
            case .warm:
                let idle = worker.lastRun.map { Instant.now - $0 } ?? .infinity
                if queued.isZero, idle >= options.warmAfterIdle { await worker.warm() }
            case .configure(let vocabulary):
                await worker.reconfigure(vocabulary, onStatus)
            case .preview(let audio, let continuation):
                guard queued.isZero else {
                    continuation.resume(returning: nil)
                    break
                }
                continuation.resume(returning: await worker.preview(audio))
                if queued.isZero { await worker.computeCompletedWindow(of: audio) }
            case .dictate(let recording, let continuation):
                queued.add(-1)
                do { continuation.resume(returning: try await worker.transcribe(recording)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func load(_ vocabulary: Vocabulary?, _ store: ModelStore,
                     _ onStatus: @escaping @Sendable (EngineStatus) -> Void) async throws -> Worker {
        onStatus(.loading(.compiling))
        // Fractions run 0 to 0.5 while downloading and 0.5 to 1 while compiling. A cached model reports 0.5.
        let models = try await store.speechModels(progress: { progress in
            let fraction = progress.fractionCompleted
            onStatus(.loading(fraction < 0.5 ? .downloading(fraction: fraction / 0.5) : .compiling))
        })
        let asr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: AsrModelVersion.v2.blankId),
                                               encoderHiddenSize: AsrModelVersion.v2.encoderHiddenSize))
        try await asr.loadModels(models)
        var worker = Worker(asr: asr, store: store, finisher: TextFinisher(vocabulary: vocabulary))
        await worker.reconfigure(vocabulary, onStatus)
        return worker
    }

    /// Only canonical terms go to FluidAudio. Aliases stay deterministic, in TextFinisher, because the bakeoff
    /// measured boosting without them. A CTC failure turns boosting off and nothing else.
    mutating func reconfigure(_ vocabulary: Vocabulary?, _ onStatus: @Sendable (EngineStatus) -> Void) async {
        finisher = TextFinisher(vocabulary: vocabulary)
        booster = nil
        windows = []
        guard let vocabulary, !vocabulary.terms.isEmpty else {
            onStatus(.ready(boosting: .off))
            return
        }
        do {
            let ctc: CtcModels
            if let loaded = self.ctc {
                ctc = loaded
            } else {
                onStatus(.loading(.preparingVocabulary))
                ctc = try await store.boostingModels()
                self.ctc = ctc
            }
            booster = try await Booster(vocabulary: vocabulary, ctc: ctc,
                                        directory: store.folder(for: PinnedModels.parakeetCTC))
            onStatus(.ready(boosting: .on(terms: vocabulary.terms.count)))
        } catch {
            onStatus(.ready(boosting: .unavailable(error.localizedDescription)))
        }
    }

    /// One second of silence through both models, so the next dictation finds them awake.
    mutating func warm() async {
        let silence = [Float](repeating: 0, count: Self.minimumSamples)
        _ = try? await decode(silence)
        if let booster { _ = try? await booster.logProbs(silence) }
        lastRun = .now
    }

    mutating func preview(_ audio: any LiveAudio) async -> String? {
        let end = audio.count
        guard end > 0 else { return nil }
        defer { lastRun = .now }
        guard let result = try? await decode(Self.padded(audio.samples(max(0, end - Self.previewSamples)..<end))) else {
            return nil
        }
        return finisher.finish(raw: result.text, boosted: nil)
    }

    /// At most one window per call, so a release waits on at most one. Windows of an earlier capture are dropped
    /// once a new capture no longer matches them. A closed capture reads as empty, and its windows stay for the
    /// dictation queued behind this preview.
    mutating func computeCompletedWindow(of audio: any LiveAudio) async {
        guard let booster else { return }
        let count = audio.count
        guard count > 0 else { return }
        if let last = windows.last, count < last.range.upperBound { windows = [] }
        guard CtcWindows.window(windows.count).upperBound <= count else { return }
        if let last = windows.last, !audio.samples(last.range).elementsEqual(last.audio) { windows = [] }
        let range = CtcWindows.window(windows.count)
        let samples = audio.samples(range)
        guard samples.count == range.count, let logProbs = try? await booster.logProbs(samples) else { return }
        windows.append(CachedWindow(range: range, audio: samples, logProbs: logProbs))
    }

    /// The boosting model runs alongside the decode, since it needs only the audio and the two models share no
    /// state. Rescoring waits for both.
    mutating func transcribe(_ recording: Recording) async throws -> Dictation {
        let started = Instant.now
        defer {
            lastRun = .now
            windows = []
        }
        let samples = Self.padded(recording.samples)
        let booster = booster, cached = windows
        async let logProbs = booster?.logProbs(samples, reusing: cached)
        let result: ASRResult
        do { result = try await decode(samples) } catch { result = try await decode(samples) }
        let decoded = Instant.now
        var boosted: String?
        if let booster, let logProbs = await logProbs { boosted = booster.rescore(result, with: logProbs) }
        let rescored = Instant.now
        let text = finisher.finish(raw: result.text, boosted: boosted)
        let finished = Instant.now
        return Dictation(text: text, raw: result.text, boosted: boosted, waited: started - recording.releasedAt,
                         decode: decoded - started, rescore: rescored - decoded, finish: finished - rescored)
    }

    private static func padded(_ samples: [Float]) -> [Float] {
        samples.count < minimumSamples ? samples + [Float](repeating: 0, count: minimumSamples - samples.count) : samples
    }

    private func decode(_ samples: [Float]) async throws -> ASRResult {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state)
    }
}
