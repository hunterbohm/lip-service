import DictationCore
import FluidAudio
import Foundation

extension Headless {
    struct TtsCheckOptions {
        var voice = "en_us_Preston"
        var text = "Okay, I looked at the build and it passed, so you can ship it whenever you are ready."
        /// A pack folder already on disk, loaded as it is. Without it the pinned pack is checked, and downloaded if missing.
        var pack: URL?
        /// The text-to-speech models folder that holds the pinned pack, FluidAudio's unless given.
        var directory: URL?
        var out: URL?
    }

    /// Says one sentence with the Phonon voices that FluidAudio ships, through the same library the app links, so a
    /// build without its `TTS` trait, or a FluidAudio that cannot load the pack, fails here and not in a later feature.
    static func ttsCheck(_ options: TtsCheckOptions) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 1
        }
        do {
            let manager = PocketTtsSmallManager(model: .phonon31m, defaultVoice: options.voice)
            let loadStarted = Instant.now
            if let pack = options.pack {
                try await manager.load(from: pack)
            } else {
                // The pack the app uses: the pinned files, each checked before Core ML reads it.
                let store = ModelStore(directory: try options.directory ?? ModelStore.voiceDirectory())
                try await manager.load(from: try await store.phononPack())
            }
            let load = Instant.now - loadStarted
            guard try await manager.availableVoices().contains(options.voice) else {
                return fail("the pack has no voice \(options.voice)")
            }

            let started = Instant.now
            var firstAudio: Double?
            var samples: [Float] = []
            for try await frame in try await manager.synthesizeStreaming(text: options.text, voice: options.voice) {
                if firstAudio == nil { firstAudio = Instant.now - started }
                samples.append(contentsOf: frame.samples)
            }
            let synthesis = Instant.now - started
            let rate = Double(PocketTtsConstants.audioSampleRate)
            let seconds = Double(samples.count) / rate
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            var row: [String: Any] = [
                "voice": options.voice, "text": options.text, "load_s": load, "first_audio_s": firstAudio ?? NSNull(),
                "synthesis_s": synthesis, "audio_s": seconds, "peak": Double(peak),
            ]
            if let out = options.out {
                try AudioWAV.data(from: samples, sampleRate: rate).write(to: out)
                row["wav"] = out.path
            }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            guard seconds >= 1, peak > 0.01 else { return fail("FAIL: \(seconds) s of audio, peak \(peak)") }
            print("PASS: \(options.voice) said \(String(format: "%.1f", seconds)) s in \(String(format: "%.2f", synthesis)) s")
            return 0
        } catch {
            return fail("FAIL: \(error.localizedDescription)")
        }
    }
}
