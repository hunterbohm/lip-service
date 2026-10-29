import DictationCore
import FluidAudio
import Foundation
import Synchronization

enum Mode {
    case app
    case selfTest(Headless.SelfTestOptions)
    case bench(Headless.BenchOptions)
    case listInputs
    case renderBar(URL)
    case renderWindow(URL)
    case importWillowDryRun(URL)
    case usage(String)

    static let usage = """
        usage: Dictation
                   Runs the menu bar app.
               Dictation --self-test [--clip PATH] [--models DIR] [--allow-download]
                   Transcribes the bundled clip through the app's pipeline and exits 1 on failure.
                   --clip locates the clip when the binary runs outside the app bundle.
                   --models reads the models from DIR instead of FluidAudio's folder.
               Dictation --bench [--rounds N] [--hold-cap S] [--gap S] [--warm on|off] [--preview on|off]
                         [--vocabulary PATH] [--models DIR] CLIP.wav...
                   Prints one JSON line per clip and round. Round 0 warms up on the first clip.
               Dictation --list-inputs
                   Prints the audio inputs and the system default.
               Dictation --render-bar DIR
                   Writes a PNG of every bar state into DIR. Needs a logged-in GUI session.
               Dictation --render-window DIR
                   Draws each page of the window, light and dark, with sample data to PNG files in DIR.
               Dictation --import-willow-dry-run WILLOW_FOLDER
                   Prints what Import from Willow would add and change. Writes nothing.
        """

    /// Anything that is not a headless flag runs the app, since LaunchServices can pass its own arguments.
    init(arguments: [String]) {
        var rest = arguments[...]
        do {
            switch rest.popFirst() {
            case "--self-test":
                var options = Headless.SelfTestOptions()
                while let flag = rest.popFirst() {
                    switch flag {
                    case "--clip": options.clip = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--models": options.models = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--allow-download": options.allowDownload = true
                    default: throw DictationError("unknown option \(flag)")
                    }
                }
                self = .selfTest(options)
            case "--bench":
                var options = Headless.BenchOptions()
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--rounds": options.rounds = try Self.number(of: argument, from: &rest, Int.init, in: 1...1000)
                    case "--hold-cap": options.holdCap = try Self.number(of: argument, from: &rest, Double.init, in: 0...600)
                    case "--gap": options.gap = try Self.number(of: argument, from: &rest, Double.init, in: 0...600)
                    case "--warm": options.warm = try Self.switchValue(of: argument, from: &rest)
                    case "--preview": options.preview = try Self.switchValue(of: argument, from: &rest)
                    case "--vocabulary": options.vocabulary = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--models": options.models = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case let flag where flag.hasPrefix("--"): throw DictationError("unknown option \(flag)")
                    default: options.clips.append(URL(fileURLWithPath: argument))
                    }
                }
                if options.clips.isEmpty { throw DictationError("--bench needs at least one clip") }
                self = .bench(options)
            case "--list-inputs":
                self = .listInputs
            case "--render-bar":
                self = .renderBar(URL(fileURLWithPath: try Self.value(of: "--render-bar", from: &rest)))
            case "--render-window":
                self = .renderWindow(URL(fileURLWithPath: try Self.value(of: "--render-window", from: &rest)))
            case "--import-willow-dry-run":
                self = .importWillowDryRun(URL(fileURLWithPath: try Self.value(of: "--import-willow-dry-run", from: &rest)))
            case "--help", "-h":
                self = .usage(Self.usage)
            default:
                self = .app
            }
        } catch {
            self = .usage("\(error.localizedDescription)\n\(Self.usage)")
        }
    }

    private static func value(of flag: String, from rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else { throw DictationError("\(flag) needs a value") }
        return value
    }

    private static func switchValue(of flag: String, from rest: inout ArraySlice<String>) throws -> Bool {
        switch try value(of: flag, from: &rest) {
        case "on": true
        case "off": false
        default: throw DictationError("\(flag) takes on or off")
        }
    }

    private static func number<N: Comparable>(of flag: String, from rest: inout ArraySlice<String>,
                                              _ parse: (String) -> N?, in range: ClosedRange<N>) throws -> N {
        guard let number = parse(try value(of: flag, from: &rest)), range.contains(number) else {
            throw DictationError("\(flag) takes a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }
}

/// Non-GUI modes. Both build the app's SpeechEngine and call the same prepare() and dictate() that the hotkey
/// does. There is no other path from audio to text.
enum Headless {
    struct SelfTestOptions {
        var clip: URL?
        var models: URL?
        var allowDownload = false
    }

    struct BenchOptions {
        var clips: [URL] = []
        var rounds = 1
        /// Simulated hold, capped per clip like the bakeoff's BATCH_HOLD.
        var holdCap = 0.0
        /// Idle time before each simulated key-down, so the warm policy sees dictations spaced apart.
        var gap = 0.0
        var warm = true
        /// Previews while the simulated key is held, as the app runs them.
        var preview = true
        /// The bakeoff's unless given.
        var vocabulary: URL?
        /// FluidAudio's folder unless given.
        var models: URL?
    }

    /// The bundled clip says "Profit Pilot" and "Bee hive" the way the engine mishears them, so boosting or an
    /// alias must fire for the text to pass.
    static let selfTestExpectedWords = ["ProfitPilot", "Beehiiv", "Friday"]

    static func selfTest(_ options: SelfTestOptions) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = ModelStore(directory: options.models ?? ModelStore.defaultDirectory)
        guard options.allowDownload || modelsAreCached(in: store) else { return 1 }
        guard let clip = options.clip ?? Bundle.main.url(forResource: "selftest", withExtension: "wav") else {
            log("selftest.wav is not in the app bundle. Pass --clip PATH.")
            return 1
        }
        let samples: [Float]
        do { samples = try Recording.load(wav: clip).samples } catch {
            log("cannot read \(clip.path): \(error.localizedDescription)")
            return 1
        }

        let loadStarted = Instant.now
        let engine = SpeechEngine(vocabulary: .bakeoff, options: .init(models: store))
        guard let boosting = await waitUntilReady(engine, printProgress: true) else { return 1 }
        print(String(format: "model: ready in %.1f s, boosting %@", Instant.now - loadStarted, describe(boosting)))

        let seconds = Double(samples.count) / Recording.sampleRate
        engine.prepare()
        try? await Task.sleep(for: .seconds(min(seconds, 15)))
        let released = Instant.now
        let dictation: Dictation
        do { dictation = try await engine.dictate(Recording(samples: samples, releasedAt: released)) } catch {
            log("transcription failed: \(error.localizedDescription)")
            return 1
        }
        let releaseToText = Instant.now - released

        print("raw:     \(dictation.raw)")
        print("boosted: \(dictation.boosted ?? "(no change)")")
        print("text:    \(dictation.text)")
        print(String(format: "stages:  waited %.3f s, decode %.3f s, rescore %.3f s, finish %.6f s",
                     dictation.waited, dictation.decode, dictation.rescore, dictation.finish))
        print(String(format: "release to text: %.3f s (clip %.1f s)", releaseToText, seconds))
        let missing = selfTestExpectedWords.filter { !dictation.text.contains($0) }
        guard missing.isEmpty else {
            print("FAIL: missing \(missing.joined(separator: ", "))")
            return 1
        }
        print("PASS: found \(selfTestExpectedWords.joined(separator: ", "))")
        return 0
    }

    static func bench(_ options: BenchOptions) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = ModelStore(directory: options.models ?? ModelStore.defaultDirectory)
        guard modelsAreCached(in: store) else { return 1 }
        var vocabulary = Vocabulary.bakeoff
        if let file = options.vocabulary {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                log("cannot read \(file.path)")
                return 1
            }
            let parsed = Vocabulary.parse(text)
            for issue in parsed.issues { log("\(file.lastPathComponent) line \(issue.line): \(issue.message)") }
            vocabulary = parsed.vocabulary
        }
        let clips: [(id: String, samples: [Float])]
        do {
            clips = try options.clips.map { ($0.deletingPathExtension().lastPathComponent, try Recording.load(wav: $0).samples) }
        } catch {
            log("cannot read clips: \(error.localizedDescription)")
            return 1
        }

        let engine = SpeechEngine(vocabulary: vocabulary, options: .init(models: store))
        guard let boosting = await waitUntilReady(engine, printProgress: false) else { return 1 }
        log("bench: model ready, boosting \(describe(boosting)), \(clips.count) clips, \(options.rounds) rounds, "
            + "hold cap \(options.holdCap) s, gap \(options.gap) s, warm \(options.warm ? "on" : "off"), "
            + "preview \(options.preview ? "on" : "off")")

        var failures = 0
        for round in 0...options.rounds {
            for clip in round == 0 ? Array(clips.prefix(1)) : clips {
                let seconds = Double(clip.samples.count) / Recording.sampleRate
                if options.gap > 0 { try? await Task.sleep(for: .seconds(options.gap)) }
                if options.warm { engine.prepare() }
                let hold = min(options.holdCap, seconds)
                let playback = ClipPlayback(clip: clip.samples, pressed: .now, head: seconds - hold)
                let previews = Task { [preview = options.preview] in
                    var (count, last) = (0, "")
                    guard preview else { return (count, last) }
                    for await text in engine.previews(of: playback) { (count, last) = (count + 1, text) }
                    return (count, last)
                }
                try? await Task.sleep(for: .seconds(hold))
                previews.cancel()
                playback.release()
                let released = Instant.now
                let dictating = Task { try await engine.dictate(Recording(samples: clip.samples, releasedAt: released)) }
                let (previewCount, lastPreview) = await previews.value
                var row: [String: Any] = ["clip": clip.id, "round": round, "audio_s": seconds, "previews": previewCount,
                                          "last_preview": lastPreview]
                do {
                    let dictation = try await dictating.value
                    row["release_to_text_s"] = Instant.now - released
                    row.merge(["raw": dictation.raw, "boosted": dictation.boosted ?? NSNull(), "text": dictation.text,
                               "waited_s": dictation.waited, "decode_s": dictation.decode,
                               "rescore_s": dictation.rescore, "finish_s": dictation.finish]) { old, _ in old }
                } catch {
                    failures += 1
                    row["error"] = error.localizedDescription
                }
                emit(row)
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func listInputs() -> Int32 {
        let inputs = AudioDevices.inputs()
        for input in inputs { print("\(input.name)\t\(input.uid)") }
        print("default: \(AudioDevices.defaultInput().map { "\($0.name) (\($0.uid))" } ?? "none")")
        if inputs.isEmpty { print("no audio inputs") }
        return 0
    }

    /// Refuses before FluidAudio can reach URLSession, which traps (exit 133) in an SSH session. Offline mode
    /// also stops the engine from deleting a cache that fails its check or downloading a new one, so the run
    /// reports the failure and leaves the folder alone. The engine does the check itself.
    private static func modelsAreCached(in store: ModelStore) -> Bool {
        guard PinnedModels.all.allSatisfy({ FileManager.default.fileExists(atPath: store.folder(for: $0).path) }) else {
            log("models missing: run scripts/fetch-models.sh")
            return false
        }
        ModelHub.offlineMode = true
        return true
    }

    /// The engine's first `.ready`, or nil after printing why it failed.
    private static func waitUntilReady(_ engine: SpeechEngine, printProgress: Bool) async -> EngineStatus.Boosting? {
        var lastLine = ""
        for await status in engine.statuses {
            switch status {
            case .ready(let boosting):
                return boosting
            case .failed(let reason):
                log("model failed to load: \(reason)")
                return nil
            case .loading(let phase):
                let line = switch phase {
                case .downloading(let fraction): String(format: "progress phase=downloading fraction=%.2f", fraction)
                case .compiling: "progress phase=compiling"
                case .preparingVocabulary: "progress phase=preparing-vocabulary"
                }
                if printProgress, line != lastLine { print(line) }
                lastLine = line
            }
        }
        return nil
    }

    private static func describe(_ boosting: EngineStatus.Boosting) -> String {
        switch boosting {
        case .on(let terms): "on (\(terms) terms)"
        case .off: "off"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    private static func emit(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// A clip as the microphone would deliver it: `head` seconds are captured at the press, the rest in real time.
/// Released, it reads as empty, as the closed sample sink does.
private final class ClipPlayback: LiveAudio {
    let clip: [Float]
    let pressed: Instant
    let head: Double
    private let released = Atomic(false)

    init(clip: [Float], pressed: Instant, head: Double) { (self.clip, self.pressed, self.head) = (clip, pressed, head) }

    var count: Int {
        released.load(ordering: .relaxed) ? 0 : min(clip.count, Int((Instant.now - pressed + head) * Recording.sampleRate))
    }

    func samples(_ range: Range<Int>) -> [Float] { Array(clip[range.clamped(to: 0..<count)]) }

    func release() { released.store(true, ordering: .relaxed) }
}
