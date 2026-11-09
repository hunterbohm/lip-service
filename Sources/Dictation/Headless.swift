import AppKit
import DictationCore
import FluidAudio
import Foundation
import Synchronization

enum Mode {
    case app
    case selfTest(Headless.SelfTestOptions)
    case bench(Headless.BenchOptions)
    case listInputs
    case ttsCheck(Headless.TtsCheckOptions)
    case micStart(Headless.MicStartOptions)
    case renderBar(URL)
    case renderWindow(URL)
    case importWillowDryRun(URL)
    case installFormatter(URL)
    case agentBench(AgentBench.Options)
    case handOffTest(HandOffTest.Options)
    case talkTest(TalkTest.Options)
    case t3Connect(home: String?, code: String)
    case t3Bridge(home: String?)
    case setup(Headless.SetupCommand)
    case usage(String)

    static let usage = """
        usage: Dictation
                   Runs the menu bar app.
               Dictation --self-test [--clip PATH] [--models DIR] [--allow-download]
                   Transcribes the bundled clip through the app's pipeline and exits 1 on failure.
                   --clip locates the clip when the binary runs outside the app bundle.
                   --models reads the models from DIR instead of FluidAudio's folder.
               Dictation --bench [--rounds N] [--hold-cap S] [--gap S] [--warm on|off] [--preview on|off]
                         [--vocabulary PATH] [--screen-names PATH] [--models DIR] [--format-app GROUP] CLIP.wav...
                   Prints one JSON line per clip and round. Round 0 warms up on the first clip.
                   --screen-names boosts the names in PATH, one per line, as names from the screen at each key-down.
                   With the smart formatting model installed, each line also has the formatted text and its time.
                   --format-app formats for one app group: messages, workChat, email, aiAndCode or everythingElse.
               Dictation --list-inputs
                   Prints the audio inputs and the system default.
               Dictation --tts-check [--voice NAME] [--text TEXT] [--pack DIR | --directory DIR] [--out FILE.wav]
                   Says one sentence with FluidAudio's Phonon text-to-speech through the library the app is built with, and
                   prints one JSON line: the load time, the time to the first audio, the time to the last, and the length.
                   Exits 1 if no sound came out. The voice is en_us_Preston and the text a short sentence unless given.
                   --pack loads a pack folder that is already on disk, unchecked. Otherwise the pinned pack in --directory,
                   or FluidAudio's text-to-speech models folder, is checked as the app checks it, and downloaded when it is
                   missing, which URLSession only does in a GUI session. Over SSH, fetch it with scripts/fetch-models.sh --voice.
               Dictation --mic-start [--rounds N] [--hold S] [--gap S] [--microphone automatic|default|UID]
                   Starts and stops the microphone as dictation does, and prints one JSON line per round with how long
                   the first audio took and how much of the hold was recorded. Uses the saved microphone unless given.
               Dictation --render-bar DIR
                   Writes a PNG of every bar state into DIR. Needs a logged-in GUI session.
               Dictation --render-window DIR
                   Draws each page of the window, light and dark, with sample data to PNG files in DIR.
               Dictation --agent-bench --command 'hermes acp' [--host HOST] [--preset ID] [--option ID=VALUE]...
                         [--model ID] [--runs N] [--cold] [--speech S] [--supersede S] [--idle-limit S] [--prompt-file PATH]
                   Times Ghostwrite drafts against an agent through the app's agent pool. One JSON line per run.
                   --preset applies the tool-free draft settings of that preset (hermes, claude, codex, opencode, gemini,
                   custom). Every permission is refused and a run stops at the agent's first tool, as in Ghostwrite;
                   "tools" counts the tool updates.
                   --prompt-file sends the prompt in PATH instead of the sample request.
               Dictation --hand-off DESTINATION.json [--dry-run] [--window-text] WORDS
                   Sends WORDS through one Hand off destination, as the app does. --dry-run builds it and sends nothing.
                   --window-text includes the sample window text, as with Send the window's text with hand-offs on.
               Dictation --test-talk [--preset ID] [--command 'hermes acp'] [--host HOST] [--voice VOICE]
                         [--voice-server URL [--voice-name NAME]] [--option ID=VALUE]... [--note TEXT] [--out PATH.wav]
                         [--models DIR] CLIP.wav...
                   Holds a live talk with no microphone or speakers: each clip is played in as your next turn, in real
                   time, and the agent's voice is made but not played. One JSON line per turn with its timings, in
                   seconds after your speech ended, then one with the session, to delete it from the agent's history.
                   --voice is an on-Mac voice, phonon:en_us_Preston unless given, or another such as kokoro:am_michael. --out writes what the voice said.
                   --note replaces the preset's per-agent talk note. --option replaces its live-talk session options.
               Dictation --t3-connect PAIRING_CODE [T3_HOME]
                   Signs in to T3 Code's MCP endpoint and keeps the token in this user's Keychain, as Connect does.
               Dictation --t3-mcp [T3_HOME]
                   An MCP server on stdin and stdout that a live talk's agent starts. It passes four of T3 Code's tools
                   (list projects, start a thread, list and read threads) to T3 Code, with the token from the Keychain.
               Dictation setup show
                   Prints the setup as JSON: agents, drafts, voice notes, profiles and keys, with `found` (agents installed
                   on this Mac) and `help`. Prints no secret.
               Dictation setup apply [--by NAME]
                   Reads the same JSON on stdin. A field left out stays as it is. Checks everything first and, if anything is
                   wrong, changes nothing, prints why and exits 1. Otherwise saves the old setup for Undo and tells a running
                   Lip Service, which shows "NAME set up Lip Service" with the changes.
               Dictation setup test [AGENT_ID]
                   Asks the agent (the default one unless given) to answer, and prints how long it took or why it did not.
               Dictation --import-willow-dry-run WILLOW_FOLDER
                   Prints what Import from Willow would add and change. Writes nothing.
               Dictation --install-formatter ARCHIVE
                   Checks a copy of the published smart formatting archive the way a download is checked, and installs it.
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
                    case "--format-app":
                        let name = try Self.value(of: argument, from: &rest)
                        guard let group = ProfileGroup(rawValue: name) else {
                            throw DictationError("--format-app is one of \(ProfileGroup.allCases.map(\.rawValue).joined(separator: ", "))")
                        }
                        options.formatApp = group
                    case "--vocabulary": options.vocabulary = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--screen-names": options.screenNames = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--models": options.models = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case let flag where flag.hasPrefix("--"): throw DictationError("unknown option \(flag)")
                    default: options.clips.append(URL(fileURLWithPath: argument))
                    }
                }
                if options.clips.isEmpty { throw DictationError("--bench needs at least one clip") }
                self = .bench(options)
            case "--list-inputs":
                self = .listInputs
            case "--tts-check":
                var options = Headless.TtsCheckOptions()
                while let flag = rest.popFirst() {
                    switch flag {
                    case "--voice": options.voice = try Self.value(of: flag, from: &rest)
                    case "--text": options.text = try Self.value(of: flag, from: &rest)
                    case "--pack": options.pack = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--directory": options.directory = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--out": options.out = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    default: throw DictationError("unknown option \(flag)")
                    }
                }
                self = .ttsCheck(options)
            case "--mic-start":
                var options = Headless.MicStartOptions()
                while let flag = rest.popFirst() {
                    switch flag {
                    case "--rounds": options.rounds = try Self.number(of: flag, from: &rest, Int.init, in: 1...1000)
                    case "--hold": options.hold = try Self.number(of: flag, from: &rest, Double.init, in: 0.1...60)
                    case "--gap": options.gap = try Self.number(of: flag, from: &rest, Double.init, in: 0...600)
                    case "--microphone":
                        let uid = try Self.value(of: flag, from: &rest)
                        options.microphone = switch uid {
                        case "automatic": .automatic
                        case "default": .systemDefault
                        default: .device(uid: uid, name: AudioDevices.input(uid: uid)?.name ?? uid)
                        }
                    default: throw DictationError("unknown option \(flag)")
                    }
                }
                self = .micStart(options)
            case "--render-bar":
                self = .renderBar(URL(fileURLWithPath: try Self.value(of: "--render-bar", from: &rest)))
            case "--render-window":
                self = .renderWindow(URL(fileURLWithPath: try Self.value(of: "--render-window", from: &rest)))
            case "--install-formatter":
                self = .installFormatter(URL(fileURLWithPath: try Self.value(of: "--install-formatter", from: &rest)))
            case "--import-willow-dry-run":
                self = .importWillowDryRun(URL(fileURLWithPath: try Self.value(of: "--import-willow-dry-run", from: &rest)))
            case "--agent-bench":
                var options = AgentBench.Options()
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--command": options.command = try Self.value(of: argument, from: &rest).split(separator: " ").map(String.init)
                    case "--host": options.remoteHost = try Self.value(of: argument, from: &rest)
                    case "--name": options.name = try Self.value(of: argument, from: &rest)
                    case "--preset":
                        options.preset = try Self.value(of: argument, from: &rest)
                        guard AgentPreset.with(id: options.preset) != nil else { throw DictationError("--preset is one of \(AgentPreset.all.map(\.id).joined(separator: ", "))") }
                    case "--option":
                        let pair = try Self.value(of: argument, from: &rest).split(separator: "=", maxSplits: 1).map(String.init)
                        guard pair.count == 2 else { throw DictationError("--option takes ID=VALUE") }
                        options.draftOptions.append(.option(id: pair[0], value: pair[1]))
                    case "--model": options.draftOptions.append(.model(try Self.value(of: argument, from: &rest)))
                    case "--runs": options.runs = try Self.number(of: argument, from: &rest, Int.init, in: 1...200)
                    case "--speech": options.speech = try Self.number(of: argument, from: &rest, Double.init, in: 0...30)
                    case "--cold": options.cold = true
                    case "--supersede": options.supersede = try Self.number(of: argument, from: &rest, Double.init, in: 0...30)
                    case "--idle-limit": options.idleLimit = try Self.number(of: argument, from: &rest, Double.init, in: 0.2...86_400)
                    case "--prompt-file": options.prompt = try String(contentsOfFile: try Self.value(of: argument, from: &rest), encoding: .utf8)
                    default: throw DictationError("unknown option \(argument)")
                    }
                }
                if options.command.isEmpty { throw DictationError("--agent-bench needs --command") }
                self = .agentBench(options)
            case "--test-talk":
                var options = TalkTest.Options()
                var server: String?, serverVoice = ""
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--preset":
                        options.preset = try Self.value(of: argument, from: &rest)
                        guard AgentPreset.with(id: options.preset) != nil else { throw DictationError("--preset is one of \(AgentPreset.all.map(\.id).joined(separator: ", "))") }
                    case "--command": options.command = ShellWords.split(try Self.value(of: argument, from: &rest))
                    case "--host": options.remoteHost = try Self.value(of: argument, from: &rest)
                    case "--voice":
                        let parts = try Self.value(of: argument, from: &rest).split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let model = OnMacVoice.Model(rawValue: parts[0]) else { throw DictationError("--voice takes MODEL:VOICE, such as phonon:en_us_Preston or kokoro:am_michael") }
                        options.voice = .onMac(OnMacVoice(model: model, voice: parts[1]))
                    case "--voice-server": server = try Self.value(of: argument, from: &rest)
                    case "--voice-name": serverVoice = try Self.value(of: argument, from: &rest)
                    case "--note": options.note = try Self.value(of: argument, from: &rest)
                    case "--option":
                        let pair = try Self.value(of: argument, from: &rest).split(separator: "=", maxSplits: 1).map(String.init)
                        guard pair.count == 2 else { throw DictationError("--option takes ID=VALUE") }
                        options.talkOptions.append(.option(id: pair[0], value: pair[1]))
                    case "--out": options.out = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--models": options.models = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case let flag where flag.hasPrefix("--"): throw DictationError("unknown option \(flag)")
                    default: options.clips.append(URL(fileURLWithPath: argument))
                    }
                }
                if let server { options.voice = .server(url: server, voice: serverVoice) }
                if options.clips.isEmpty { throw DictationError("--test-talk needs at least one CLIP.wav") }
                self = .talkTest(options)
            case "--t3-connect":
                let code = try Self.value(of: "--t3-connect", from: &rest)
                self = .t3Connect(home: rest.popFirst(), code: code)
            case "--t3-mcp":
                self = .t3Bridge(home: rest.popFirst())
            case "setup":
                switch rest.popFirst() {
                case "show": self = .setup(.show)
                case "apply":
                    var by: String?
                    while let argument = rest.popFirst() {
                        guard argument == "--by" else { throw DictationError("unknown option \(argument)") }
                        by = try Self.value(of: argument, from: &rest)
                    }
                    self = .setup(.apply(by: by))
                case "test": self = .setup(.test(agentID: rest.popFirst()))
                default: throw DictationError("setup takes show, apply or test")
                }
            case "--hand-off":
                var options = HandOffTest.Options(destination: URL(fileURLWithPath: try Self.value(of: "--hand-off", from: &rest)))
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--dry-run": options.dryRun = true
                    case "--window-text": options.includeWindowText = true
                    default: options.words.append(argument)
                    }
                }
                self = .handOffTest(options)
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
    enum SetupCommand {
        case show
        case apply(by: String?)
        case test(agentID: String?)
    }

    struct SelfTestOptions {
        var clip: URL?
        var models: URL?
        var allowDownload = false
    }

    struct MicStartOptions {
        var rounds = 10
        var hold = 1.0
        /// Idle time before each start, as between dictations.
        var gap = 2.0
        var microphone: MicrophoneChoice?
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
        /// The app group smart formatting formats for, when its model is installed.
        var formatApp: ProfileGroup?
        /// The bakeoff's unless given.
        var vocabulary: URL?
        /// Names boosted at each key-down the way names from the screen are.
        var screenNames: URL?
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
        var screenNames: [String] = []
        if let file = options.screenNames {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                log("cannot read \(file.path)")
                return 1
            }
            screenNames = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let clips: [(id: String, samples: [Float])]
        do {
            clips = try options.clips.map { ($0.deletingPathExtension().lastPathComponent, try Recording.load(wav: $0).samples) }
        } catch {
            log("cannot read clips: \(error.localizedDescription)")
            return 1
        }

        let engine = SpeechEngine(vocabulary: vocabulary, options: .init(models: store))
        let formatter = SmartFormatter()
        await formatter.load(download: false)
        log("bench: smart formatting \(await formatter.state)")
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
                if !screenNames.isEmpty { engine.boost(screenNames: screenNames) }
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
                    if let formatted = await formatter.format(dictation, app: options.formatApp) {
                        row["formatted"] = formatted.text
                        row["format_s"] = formatted.seconds
                        row["release_to_formatted_s"] = Instant.now - released
                    }
                    row.merge(["raw": dictation.raw, "boosted": dictation.boosted ?? NSNull(), "text": dictation.text,
                               "waited_s": dictation.waited, "decode_s": dictation.decode,
                               "rescore_s": dictation.rescore, "finish_s": dictation.finish,
                               "screen_terms": dictation.screenTerms,
                               "tokens": dictation.tokens.map { [$0.text, $0.start, $0.end] as [Any] }]) { old, _ in old }
                } catch {
                    failures += 1
                    row["error"] = error.localizedDescription
                }
                emit(row)
            }
        }
        return failures == 0 ? 0 : 1
    }

    @MainActor static func micStart(_ options: MicStartOptions) async -> Int32 {
        let stored = SettingsStore.read(SettingsStore.defaults) ?? Settings()
        let choice = options.microphone ?? stored.microphone
        AudioDevices.automaticOrder = stored.automaticOrder
        let microphone = Microphone()
        var failure: (any Error)?
        var source: MicrophoneSource?
        microphone.onFailure = { failure = $0 }
        microphone.onSource = { source = $0 }
        microphone.prepare(choice)
        let sounds = Sounds()
        for round in 1...options.rounds {
            try? await Task.sleep(for: .seconds(options.gap))
            failure = nil
            source = nil
            let started = Instant.now
            do { try microphone.start(from: choice) } catch {
                log(error.localizedDescription)
                return 1
            }
            try? await Task.sleep(for: .seconds(0.12))
            sounds.play(.start)
            try? await Task.sleep(for: .seconds(max(0, options.hold - 0.12)))
            let ready = microphone.firstAudio.map { $0 - started }
            let audio = microphone.stop(releasedAt: .now)?.seconds ?? 0
            sounds.play(.stop)
            let held = Instant.now - started
            var row: [String: Any] = ["round": round, "held": held, "audio": audio, "lost": held - audio,
                                      "source": source.map { String(describing: $0) } ?? "none"]
            if let ready { row["ready"] = ready }
            if let failure { row["error"] = failure.localizedDescription }
            emit(row)
        }
        return 0
    }

    static func listInputs() -> Int32 {
        let inputs = AudioDevices.inputs()
        for input in inputs { print("\(input.name)\t\(input.uid)") }
        print("default: \(AudioDevices.defaultInput().map { "\($0.name) (\($0.uid))" } ?? "none")")
        // What Automatic picks now, by the saved order, with the lid and the system default as they are.
        AudioDevices.automaticOrder = (SettingsStore.read(SettingsStore.defaults) ?? Settings()).automaticOrder
        let automatic = if case .device(let uid) = AudioDevices.source(for: .automatic, among: inputs) {
            inputs.first { $0.uid == uid }.map { "\($0.name) (\($0.uid))" } ?? uid
        } else { "system default" }
        print("automatic: \(automatic)")
        if inputs.isEmpty { print("no audio inputs") }
        return 0
    }

    /// Refuses before FluidAudio can reach URLSession, which traps (exit 133) in an SSH session. Offline mode
    /// also stops the engine from deleting a cache that fails its check or downloading a new one, so the run
    /// reports the failure and leaves the folder alone. The engine does the check itself.
    private static func modelsAreCached(in store: ModelStore) -> Bool {
        guard PinnedModels.speech.allSatisfy({ FileManager.default.fileExists(atPath: store.folder(for: $0).path) }) else {
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

/// `Dictation setup show|apply|test`: how a user's own agent sets Lip Service up. The window never runs this; it reads and
/// writes the same settings through the same DictationCore code.
extension Headless {
    static func setup(_ command: SetupCommand) async -> Int32 {
        let defaults = SettingsStore.defaults
        switch command {
        case .show:
            let settings = SettingsStore.read(defaults) ?? Settings()
            let found = AgentPreset.all.map(\.id).filter { AgentDetection.found().contains($0) }
            print(String(decoding: SetupSpec.show(settings, found: found).prettyData(), as: UTF8.self))
            return 0
        case .apply(let by):
            return apply(by: by, defaults: defaults)
        case .test(let agentID):
            return await test(agentID: agentID, defaults: defaults)
        }
    }

    private static func apply(by: String?, defaults: UserDefaults) -> Int32 {
        let existing = SettingsStore.read(defaults)
        let settings = existing ?? Settings()
        switch SetupSpec.plan(FileHandle.standardInput.readDataToEndOfFile(), from: settings) {
        case .failure(let invalid):
            FileHandle.standardError.write(Data(("Nothing was changed. Fix these and run it again:\n"
                + invalid.problems.map { "- \($0)" }.joined(separator: "\n") + "\n").utf8))
            return 1
        case .success(let plan):
            guard !plan.changes.isEmpty else {
                print("Nothing to change. Lip Service already matches.")
                return 0
            }
            let record = SetupRecord(by: by, changes: plan.changes, previous: settings.setupFields)
            if existing == nil { defaults.set(true, forKey: SettingsStore.onboardingKey) }
            SettingsStore.write(record, to: defaults)
            SettingsStore.write(plan.settings, to: defaults)
            defaults.synchronize()
            var running = false
            if SettingsStore.isReal {
                running = !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.isEmpty
                if running, let settings = try? JSONEncoder().encode(plan.settings), let record = try? JSONEncoder().encode(record) {
                    DistributedNotificationCenter.default().postNotificationName(
                        SettingsStore.appliedNotification, object: nil,
                        userInfo: ["settings": String(decoding: settings, as: UTF8.self), "record": String(decoding: record, as: UTF8.self)],
                        deliverImmediately: true)
                }
            }
            print("\(record.title). \(plan.changes.count) \(plan.changes.count == 1 ? "change" : "changes"):")
            for line in plan.changes { print("- \(line)") }
            print(running ? "Lip Service is running and shows these changes, with Undo."
                          : "Lip Service isn't running. These apply when it starts.")
            print("Microphone, Accessibility and the fn key setting still need the user. Lip Service asks for them on first run.")
            return 0
        }
    }

    @MainActor private static func test(agentID: String?, defaults: UserDefaults) async -> Int32 {
        let settings = SettingsStore.read(defaults) ?? Settings()
        guard let agent = agentID.map({ settings.agents.agent(id: $0) }) ?? settings.agents.current else {
            let known = settings.agents.agents.map(\.id)
            FileHandle.standardError.write(Data((agentID.map { "No agent \"\($0)\". " + (known.isEmpty ? "None is set up." : "The agents are \(known.joined(separator: ", ")).") }
                ?? "No agent is set up yet. Run setup apply first.").appending("\n").utf8))
            return 1
        }
        if let problem = await AgentBench.checkDestination(agent) {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
            return 1
        }
        let pool = AgentPool()
        defer { pool.stopAll() }
        switch await AgentBench.check(agent, pool: pool) {
        case .success(let check):
            print("\(agent.name) answered in \(String(format: "%.1f", check.seconds)) s" + (check.model.map { " (\($0))" } ?? ""))
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("\(agent.name) didn't answer: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
