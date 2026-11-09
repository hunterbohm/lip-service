import DictationCore
import FluidAudio
import Foundation

/// `--test-talk`: a whole live talk with no microphone and no speakers. Each WAV clip is played into the talk in real
/// time when it is your turn, the agent answers in a real session, and the voice is made but not played; the speaker
/// takes each clip's real length, so the timings are a real talk's. Prints one JSON line per turn and the session id
/// last, so a test talk can be deleted from the agent's history.
@MainActor enum TalkTest {
    struct Options {
        var clips: [URL] = []
        var preset = "hermes"
        var command: [String]?
        var remoteHost: String?
        var voice = TalkVoiceChoice.onMac(.standard)
        var out: URL?
        var models: URL?
        /// The talk-note extra, replacing the preset's.
        var note: String?
        /// The live-talk session options, replacing the preset's when any are given.
        var talkOptions: [ConfigChoice] = []
        /// Starts the talk as a call back about this, with this result, before the first clip.
        var callBack: (about: String, result: String)?
        /// The file that remembers the agent's last talk session. A talk run with one picks up where the last run with it
        /// ended; with none, every run is a new conversation, and nothing is written, so a test never moves the thread of a
        /// real install.
        var threadFile: URL?
        /// Start a new conversation first, as Start a new conversation does.
        var startOver = false
    }

    static func run(_ options: Options) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let preset = AgentPreset.with(id: options.preset) else { return fail("no preset \(options.preset)") }
        var agent = preset.connection()
        if let command = options.command { agent.command = command }
        agent.remoteHost = options.remoteHost
        if let note = options.note { agent.talkNote = note }
        if !options.talkOptions.isEmpty { agent.talkOptions = options.talkOptions }
        let clips: [[Float]]
        do { clips = try options.clips.map { try Recording.load(wav: $0).samples } } catch {
            return fail("cannot read clips: \(error.localizedDescription)")
        }

        let store = ModelStore(directory: options.models ?? ModelStore.defaultDirectory)
        guard PinnedModels.speech.allSatisfy({ FileManager.default.fileExists(atPath: store.folder(for: $0).path) }) else {
            return fail("speech models missing: run scripts/fetch-models.sh")
        }
        ModelHub.offlineMode = true
        let engine = SpeechEngine(vocabulary: nil, options: .init(models: store))
        for await status in engine.statuses {
            if case .ready = status { break }
            if case .failed(let message) = status { return fail("speech model failed: \(message)") }
        }
        // The voice may still need its first download.
        ModelHub.offlineMode = false

        let input = ClipInput(clips: clips), speaker = SilentSpeaker(), pool = AgentPool(threadsAt: options.threadFile)
        if options.startOver { pool.startOver(agent.id) }
        let secrets = T3Bridge.secrets()
        pool.talkExtras = { agent in await TalkT3.extras(for: agent, secrets: secrets) }
        let opening = options.callBack.map { call in
            TalkOpening(greeting: CallbackPrompt.greeting(from: agent.name, about: call.about),
                        prompt: CallbackPrompt.opening(from: agent.name, about: call.about, result: call.result))
        }
        let talk = Talk(agent: agent, pool: pool, engine: engine, voice: Voices.provider(for: options.voice), input: input, speaker: speaker,
                        opening: opening)
        let started = Instant.now
        var turns = 0, failures = 0
        let done = AsyncStream<TalkEnd>.makeStream()
        talk.onListening = { [weak talk] in
            // A moment of quiet first, as between a reply and your next words.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard let talk, !talk.ended else { return }
                if !input.next() { talk.end(.byYou) }
            }
        }
        talk.onTurn = { report in
            turns += 1
            if report.failed != nil { failures += 1 }
            var row: [String: JSONValue] = [
                "turn": .number(Double(turns)), "words": .string(report.words), "reply": .string(Speech.collapse(report.reply)),
                "tools": .array(report.tools.map(JSONValue.string)), "cards": .number(Double(report.cards)), "timings": report.clock.json,
            ]
            if let failed = report.failed { row["failed"] = .string(failed) }
            print(String(decoding: JSONValue.object(row).data(), as: UTF8.self))
        }
        var lastSteps: [TalkStep] = []
        talk.onBar = { bar in
            // What the island would show of the agent's work: each step with its app, and whether it failed.
            let steps = bar.trail + (bar.step.map { [$0] } ?? [])
            guard !steps.isEmpty, steps != lastSteps else { return }
            lastSteps = steps
            let line = steps.map { "\($0.line) [\($0.app?.rawValue ?? "-")\($0.failed ? ", failed" : "")]" }.joined(separator: " > ")
            FileHandle.standardError.write(Data("steps: \(line)\n".utf8))
        }
        talk.onCard = { [weak talk] event in
            if case .show(let card) = event { FileHandle.standardError.write(Data("card: \(card)\n".utf8)) }
            if case .result(let card) = event { FileHandle.standardError.write(Data("result: \(card)\n".utf8)) }
            if case .callBackPromised = event { FileHandle.standardError.write(Data("call back promised\n".utf8)) }
            // A question about a tool waits for your answer, so the next clip is it, once the question has been said.
            if case .permission(_, let phrase, _, let byVoice) = event {
                FileHandle.standardError.write(Data("asked: \(phrase) (\(byVoice ? "by voice" : "click only"))\n".utf8))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(byVoice ? 7 : 2))
                    guard let talk, !talk.ended else { return }
                    if !input.next() { talk.answerPermission(false) }
                }
            }
        }
        talk.onOpening = { said in print(#"{"callBack":"\#(said ? "said" : "failed")"}"#) }
        talk.onEnd = { done.continuation.yield($0) }
        talk.start()
        var reason = TalkEnd.byYou
        for await end in done.stream {
            reason = end
            break
        }
        if let out = options.out {
            try? WAVFile.encode(speaker.recorded, sampleRate: Int(speaker.recordedRate)).write(to: out)
        }
        var summary: [String: JSONValue] = [
            "agent": .string(agent.name), "turns": .number(Double(turns)), "seconds": .number(((Instant.now - started) * 10).rounded() / 10),
            "ended": .string(String(describing: reason)),
        ]
        if let session = talk.sessionID { summary["session"] = .string(session) }
        print(String(decoding: JSONValue.object(summary).data(), as: UTF8.self))
        pool.stopAll()
        try? await Task.sleep(for: .milliseconds(300))
        if case .failed = reason { return 1 }
        // A goodbye clip ends the talk without a turn of its own, and a call back's opening is a turn of its own.
        let expected = (reason == .goodbye ? clips.count - 1 : clips.count) + (opening == nil ? 0 : 1)
        return failures == 0 && turns == expected ? 0 : 1
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
