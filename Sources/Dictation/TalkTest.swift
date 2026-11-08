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
    }

    static func run(_ options: Options) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let preset = AgentPreset.with(id: options.preset) else { return fail("no preset \(options.preset)") }
        var agent = preset.connection()
        if let command = options.command { agent.command = command }
        agent.remoteHost = options.remoteHost
        if let note = options.note { agent.talkNote = note }
        let clips: [[Float]]
        do { clips = try options.clips.map { try Recording.load(wav: $0).samples } } catch {
            return fail("cannot read clips: \(error.localizedDescription)")
        }

        let store = ModelStore(directory: options.models ?? ModelStore.defaultDirectory)
        guard PinnedModels.all.allSatisfy({ FileManager.default.fileExists(atPath: store.folder(for: $0).path) }) else {
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

        let input = ClipInput(clips: clips), speaker = SilentSpeaker(), pool = AgentPool()
        let talk = Talk(agent: agent, pool: pool, engine: engine, voice: Voices.provider(for: options.voice), input: input, speaker: speaker)
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
        talk.onCard = { event in
            if case .show(let card) = event { FileHandle.standardError.write(Data("card: \(card)\n".utf8)) }
        }
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
        // A goodbye clip ends the talk without a turn of its own.
        let expected = reason == .goodbye ? clips.count - 1 : clips.count
        return failures == 0 && turns == expected ? 0 : 1
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
