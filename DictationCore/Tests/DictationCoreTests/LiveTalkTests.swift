import Foundation
import Testing
@testable import DictationCore

@Suite("Live talk key") struct LiveTalkKeyTests {
    private let down: UInt64 = 0x4_0000 | 0x0001
    private let up: UInt64 = 0x100

    private func taps(_ events: [(DoubleTapDetector.Input, Double)]) -> [Bool] {
        var detector = DoubleTapDetector()
        return events.map { detector.feed($0.0, at: Instant(seconds: $0.1)) }
    }

    @Test func twoQuickTapsOfLeftControlCount() {
        #expect(taps([(.down, 0), (.up, 0.08), (.down, 0.25), (.up, 0.32)]) == [false, false, false, true])
    }

    @Test func aHoldOrASlowSecondTapDoesNot() {
        #expect(taps([(.down, 0), (.up, 0.45), (.down, 0.6), (.up, 0.7)]).last == false)
        #expect(taps([(.down, 0), (.up, 0.1), (.down, 0.6), (.up, 0.7)]).last == false)
        // The slow second tap starts a new pair.
        #expect(taps([(.down, 0), (.up, 0.1), (.down, 0.6), (.up, 0.7), (.down, 0.8), (.up, 0.9)]).last == true)
    }

    @Test func anythingInBetweenStartsOver() {
        #expect(taps([(.down, 0), (.up, 0.08), (.other, 0.1), (.down, 0.25), (.up, 0.32)]).last == false)
        #expect(taps([(.down, 0), (.other, 0.05), (.up, 0.08), (.down, 0.25), (.up, 0.32)]).last == false)
    }

    @Test func aThirdTapDoesNotEndWhatTheSecondStarted() {
        #expect(taps([(.down, 0), (.up, 0.08), (.down, 0.2), (.up, 0.28), (.down, 0.4), (.up, 0.48)]) == [false, false, false, true, false, false])
    }

    @Test func onlyLeftControlAloneIsATap() {
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 59, flags: down) == .down)
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 59, flags: up) == .up)
        // Left Control with Shift, with fn, or with Right Control already down.
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 59, flags: down | 0x2_0000) == .other)
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 59, flags: down | 0x80_0000) == .other)
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 59, flags: down | 0x2000) == .other)
        // Right Control, fn, or a letter.
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 62, flags: 0x4_0000 | 0x2000) == .other)
        #expect(DoubleTapDetector.input(kind: .flagsChanged, keyCode: 63, flags: 0x80_0000) == .other)
        #expect(DoubleTapDetector.input(kind: .keyDown, keyCode: 8, flags: down) == .other)
        #expect(DoubleTapDetector.input(kind: .keyUp, keyCode: 8, flags: down) == nil)
    }

    @Test func controlCTwiceIsNotATalk() {
        var detector = DoubleTapDetector()
        var fired = false
        for start in [0.0, 0.3] {
            for (kind, code, flags, at) in [(KeyInput.EventKind.flagsChanged, 59, down, start), (.keyDown, 8, down, start + 0.05),
                                            (.keyUp, 8, down, start + 0.08), (.flagsChanged, 59, up, start + 0.1)] {
                if let input = DoubleTapDetector.input(kind: kind, keyCode: code, flags: flags) {
                    fired = fired || detector.feed(input, at: Instant(seconds: at))
                }
            }
        }
        #expect(!fired)
    }

    @Test func leftControlAsACaptureKeyClashes() {
        let keys = CaptureKeys(dictation: [.fn, Shortcut(key: 59)], ghostwrite: nil, handOff: nil)
        #expect(LiveTalkKey.conflict(with: keys)?.contains("a dictation key") == true)
        #expect(LiveTalkKey.conflict(with: Settings().captureKeys) == nil)
        // A shortcut that holds Left Control with Option is never a lone tap.
        #expect(LiveTalkKey.conflict(with: CaptureKeys(dictation: [Shortcut(key: 59, modifiers: [.option])], ghostwrite: nil, handOff: nil)) == nil)
    }
}

@Suite("Live talk turns") struct TalkEarTests {
    private let quiet = [Float](repeating: 0.001, count: 480)
    private let voice = [Float](repeating: 0.2, count: 480)
    private let echo = [Float](repeating: 0.02, count: 480)

    /// Feeds blocks 30 ms apart from `start` and returns every event with its time.
    private func run(_ ear: inout TalkEar, _ blocks: [[Float]], from start: Double) -> [(TalkEar.Event, Double)] {
        var out: [(TalkEar.Event, Double)] = []
        for (index, block) in blocks.enumerated() {
            let time = start + Double(index + 1) * 0.03
            if let event = ear.hear(block, at: Instant(seconds: time)) { out.append((event, time)) }
        }
        return out
    }

    private func calibrated() -> TalkEar {
        var ear = TalkEar()
        _ = run(&ear, Array(repeating: quiet, count: 20), from: 0)
        return ear
    }

    @Test func theRoomSetsTheThresholdsWithinLimits() {
        let ear = calibrated()
        #expect(ear.thresholds.start == Float(250) / 32768)
        #expect(ear.thresholds.cutIn == Float(900) / 32768)
        #expect(TalkThresholds.floor(of: [0.5, 0.5, 0.5]) == Float(400) / 32768)
    }

    @Test func aTurnEndsAfterEightTenthsOfQuiet() throws {
        var ear = calibrated()
        let events = run(&ear, Array(repeating: quiet, count: 5) + Array(repeating: voice, count: 40) + Array(repeating: quiet, count: 40), from: 0.6)
        #expect(events.first?.0 == .began)
        guard case .ended(let utterance) = try #require(events.last?.0) else { Issue.record("no end"); return }
        let speechEnd = 0.6 + 45 * 0.03
        #expect(abs(utterance.speechEnd.seconds - speechEnd) < 1e-9)
        #expect(utterance.turnEnd - utterance.speechEnd > 0.8)
        #expect(utterance.turnEnd - utterance.speechEnd < 0.84)
        // The preroll keeps the blocks just before the turn began.
        #expect(utterance.samples.count > 40 * 480)
    }

    @Test func aPauseIsTranscribedBeforeTheTurnEnds() throws {
        var ear = calibrated()
        let events = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 40), from: 0.6)
        try #require(events.count == 3)
        guard case .paused(let soFar) = events[1].0, case .ended(let whole) = events[2].0 else { Issue.record("\(events)"); return }
        #expect(soFar.speechEnd == whole.speechEnd)
        // The words so far come 0.5 s into the quiet, 0.3 s before the turn ends, and hold everything but quiet after.
        #expect(events[1].1 - soFar.speechEnd.seconds > 0.5 && events[1].1 - soFar.speechEnd.seconds < 0.53)
        #expect(soFar.samples.count < whole.samples.count && whole.samples.starts(with: soFar.samples))
    }

    @Test func talkingAgainAfterAPauseGoesOnWithTheTurn() throws {
        var ear = calibrated()
        let blocks = Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 20) + Array(repeating: voice, count: 10)
            + Array(repeating: quiet, count: 40)
        let events = run(&ear, blocks, from: 0.6).map(\.0)
        try #require(events.count == 5)
        #expect(events[0] == .began && events[2] == .resumed)
        guard case .paused(let first) = events[1], case .paused(let second) = events[3], case .ended(let whole) = events[4] else {
            Issue.record("\(events)"); return
        }
        #expect(first.speechEnd != whole.speechEnd)
        #expect(second.speechEnd == whole.speechEnd)
    }

    @Test func aClickIsNotTranscribedEarly() {
        var ear = calibrated()
        let events = run(&ear, Array(repeating: voice, count: 4) + Array(repeating: quiet, count: 30), from: 0.6)
        #expect(!events.contains { if case .paused = $0.0 { true } else { false } })
    }

    @Test func aClickIsDropped() {
        var ear = calibrated()
        let events = run(&ear, Array(repeating: voice, count: 4) + Array(repeating: quiet, count: 30), from: 0.6)
        #expect(events.map(\.0) == [.began, .dropped])
    }

    @Test func aQuickNoIsATurn() throws {
        var ear = calibrated()
        // About 0.3 s of voice, as a short "no" or "bye" is.
        let events = run(&ear, Array(repeating: voice, count: 10) + Array(repeating: quiet, count: 30), from: 0.6)
        #expect(events.first?.0 == .began)
        guard case .ended = try #require(events.last?.0) else { Issue.record("a quick word was dropped"); return }
    }

    @Test func theAgentsEchoDoesNotCutInButYourVoiceDoes() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        // Its first syllables are held off by the grace period, and its echo stays under the cut-in level after it.
        #expect(run(&ear, Array(repeating: voice, count: 10), from: 2.4).isEmpty)
        #expect(run(&ear, Array(repeating: echo, count: 30), from: 3.1).isEmpty)
        let cut = run(&ear, Array(repeating: voice, count: 6), from: 4)
        #expect(cut.map(\.0) == [.cutIn])
        #expect(ear.isHearing)
    }

    @Test func afterTheAgentFinishesTheNextTurnStartsFresh() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        ear.agentDone(at: Instant(seconds: 5))
        let events = run(&ear, Array(repeating: voice, count: 3), from: 5)
        #expect(events.map(\.0) == [.began])
    }

    @Test func quietWarnsThenEnds() {
        var ear = TalkEar()
        ear.assume(floor: 0.001, at: Instant(seconds: 0))
        #expect(ear.hear(quiet, at: Instant(seconds: 99)) == nil)
        #expect(ear.hear(quiet, at: Instant(seconds: 100.5)) == .idleWarning)
        #expect(ear.hear(quiet, at: Instant(seconds: 101)) == nil)
        #expect(ear.hear(quiet, at: Instant(seconds: 120.5)) == .idleEnded)
    }
}

@Suite("Live talk words") struct TalkWordsTests {
    @Test func goodbyesEndTheTalk() {
        for line in ["Goodbye.", "Bye!", "Okay, bye.", "Thanks, that's all.", "End call", "Hang up.", "Bye, Hermes.", "Alright, goodbye then.",
                     "That's all for now."] {
            #expect(TalkWords.isGoodbye(line, agentNames: ["Hermes"]), "\(line)")
        }
    }

    @Test func aSentenceWithAGoodbyeInItDoesNot() {
        for line in ["How do I say goodbye to my landlord?", "That's all I wanted to know about the build, what's next?", "Thank you.",
                     "Hang up the picture in the hall", ""] {
            #expect(!TalkWords.isGoodbye(line, agentNames: ["Hermes"]), "\(line)")
        }
    }

    @Test func noiseAndAnswers() {
        #expect(TalkWords.isNoise("Mm."))
        #expect(TalkWords.isNoise(""))
        #expect(!TalkWords.isNoise("No."))
        #expect(TalkWords.answer("Yes, please.") == true)
        #expect(TalkWords.answer("Go ahead.") == true)
        #expect(TalkWords.answer("No.") == false)
        #expect(TalkWords.answer("Don't.") == false)
        #expect(TalkWords.answer("What does it do?") == nil)
    }
}

@Suite("Live talk replies") struct TalkReplyTests {
    @Test func showBlocksAreSplitOutEvenAcrossChunks() {
        var splitter = ShowSplitter()
        var pieces: [ReplyPiece] = []
        for chunk in ["Here it is. <sh", "ow>https://example.com</s", "how> Anything else?"] { pieces += splitter.feed(chunk) }
        pieces += splitter.finish()
        #expect(pieces == [.speech("Here it is. "), .show("https://example.com"), .speech(" Anything else?")])
    }

    @Test func anOpenShowBlockIsShownAtTheEnd() {
        var splitter = ShowSplitter()
        #expect(splitter.feed("Look: <show>a table") == [.speech("Look: ")])
        #expect(splitter.finish() == [.show("a table")])
    }

    @Test func theFirstPieceEndsAtTheFirstClauseAfterAFewWords() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("Yes, you have ") == [])
        #expect(chunker.feed("three meetings today, the first at ") == ["Yes, you have three meetings today,"])
        #expect(chunker.feed("nine. Then lunch") == ["the first at nine."])
        #expect(chunker.feed(" with Dana. ") == ["Then lunch with Dana."])
        #expect(chunker.finish() == [])
    }

    @Test func numbersAndShortSentencesAreNotCut() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("It costs 1,000 dollars, or 3.5 percent ") == ["It costs 1,000 dollars,"])
        #expect(chunker.feed("more. OK. ") == ["or 3.5 percent more."])
        #expect(chunker.feed("That is it. ") == ["OK. That is it."])
    }

    @Test func aLongSentenceIsCutAtAComma() {
        var chunker = SpeechChunker()
        _ = chunker.feed("Sure, here goes. ")
        let long = (1...30).map { "item \($0)," }.joined(separator: " ") + " and"
        let pieces = chunker.feed(long)
        #expect(pieces.count == 1)
        #expect(pieces[0].hasSuffix(","))
        #expect(pieces[0].count <= 220)
        #expect(chunker.finish().last?.hasSuffix("and") == true)
    }

    @Test func theRestIsSaidAtTheEnd() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("Four") == [])
        #expect(chunker.finish() == ["Four"])
    }

    @Test func spokenTextHasNoMarkdownOrAddresses() {
        #expect(Speech.spoken("See **this** [page](https://a.com) or https://b.com/x.") == "See this page or a link")
        #expect(Speech.caption("See **this** [page](https://a.com)") == "See this page")
    }

    @Test func cardsAreClassified() {
        #expect(ShowCard.classify("https://example.com/a") == .link(URL(string: "https://example.com/a")!))
        #expect(ShowCard.classify("![chart](https://example.com/c.png)") == .image(URL(string: "https://example.com/c.png")!))
        #expect(ShowCard.classify("<div><svg></svg></div>") == .html("<div><svg></svg></div>"))
        #expect(ShowCard.classify("```html\n<b>x</b>\n```") == .html("<b>x</b>"))
        #expect(ShowCard.classify("- one\n- two") == .text("- one\n- two"))
    }

    @Test func toolsGetPlainLinesWithoutTheirArguments() {
        #expect(ToolLine.phrase(title: "google_calendar_list_events", kind: "fetch") == "Checking your calendar")
        #expect(ToolLine.phrase(title: "terminal: hermes send -t photon \"call mom about the gmail thing\"", kind: "execute") == "Running a command")
        #expect(ToolLine.phrase(title: "Read ~/.ssh/id_ed25519", kind: "read") == "Reading a file")
        #expect(ToolLine.phrase(title: "zz", kind: "search") == "Searching")
        #expect(ToolLine.phrase(title: "", kind: nil) == "Working on it")
    }

    @Test func atMostOneToolLineEveryFewSeconds() {
        var announcer = ToolAnnouncer()
        #expect(announcer.announce(id: "a", title: "web_search", kind: nil, at: Instant(seconds: 0)) == "Searching the web")
        #expect(announcer.announce(id: "a", title: "web_search", kind: nil, at: Instant(seconds: 5)) == nil)
        #expect(announcer.announce(id: "b", title: "read_file", kind: nil, at: Instant(seconds: 2)) == nil)
        #expect(announcer.announce(id: "c", title: "read_file", kind: nil, at: Instant(seconds: 6)) == "Reading a file")
        #expect(announcer.announce(id: "d", title: "read_file", kind: nil, at: Instant(seconds: 11)) == nil)
        #expect(announcer.announce(id: "e", title: "read_file", kind: nil, at: Instant(seconds: 19)) == "Reading a file")
    }

    @Test func eachTurnCarriesTheNoteAndTheAgentsExtra() {
        let plain = TalkPrompt.message("what's on today", extra: " ")
        #expect(plain.hasPrefix("(Voice call through Lip Service"))
        #expect(plain.hasSuffix(") what's on today"))
        let hermes = TalkPrompt.message("text me that", extra: AgentPreset.with(id: "hermes")!.talkNote)
        // Sent through a quoted heredoc, so nothing in the text is run by the shell.
        #expect(hermes.contains(#"hermes send -t photon <<'EOF'"#))
    }

    @Test func aTurnIsTimedFromTheEndOfSpeech() {
        var clock = TurnClock(speechEnd: Instant(seconds: 10))
        clock.mark(.turnEnd, at: Instant(seconds: 10.8))
        clock.mark(.transcribed, at: Instant(seconds: 10.95))
        clock.mark(.firstText, at: Instant(seconds: 12.5))
        clock.mark(.firstText, at: Instant(seconds: 13))
        clock.mark(.firstAudio, at: Instant(seconds: 12.9))
        #expect(clock.seconds(.firstText) == 2.5)
        #expect(clock.summary == "turn end 0.80 s, transcribed 0.95 s, first text 2.50 s, first audio 2.90 s after speech end")
        #expect(clock.json["first_audio"] == .number(2.9))
    }
}

@Suite("Live talk settings") struct LiveTalkSettingsTests {
    @Test func anAgentSavedBeforeLiveTalkGetsItsPresetsTalkSettings() throws {
        let old = #"{"id":"hermes","name":"Hermes","presetID":"hermes","command":["hermes","acp"],"remoteHost":"mini","spokenNames":["Hermes"],"#
            + #""draftOptions":[],"taskOptions":[],"destination":{"agentReply":{}}}"#
        let agent = try JSONDecoder().decode(AgentConnection.self, from: Data(old.utf8))
        #expect(agent.talkOptions == [.option(id: "model", value: "anthropic:claude-opus-5-5"), .option(id: "reasoning_effort", value: "low")])
        #expect(agent.talkNote.contains("hermes send -t photon"))
        #expect(agent.remoteHost == "mini")
        var changed = agent
        changed.talkOptions = []
        changed.talkNote = ""
        let back = try JSONDecoder().decode(AgentConnection.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
    }

    @Test func onlyHermesSendsMessagesItsWay() {
        for preset in AgentPreset.all where preset.id != "hermes" { #expect(!preset.connection().talkNote.contains("hermes"), "\(preset.id)") }
    }

    @Test func settingsWithoutLiveTalkReadTheDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(settings.liveTalk == LiveTalkSettings())
        #expect(settings.liveTalk.voice == .onMac(.preston))
        #expect(OnMacVoice.preston.id == "phonon:en_us_Preston")
        var custom = Settings()
        custom.liveTalk.voice = .server(url: "http://msi:8890", voice: "hunter")
        custom.liveTalk.agentID = "claude"
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(custom)).liveTalk == custom.liveTalk)
    }

    @Test func theTalkGoesToThePickedAgentOrTheDefault() {
        var agents = AgentSettings()
        agents.agents = [AgentPreset.with(id: "hermes")!.connection(), AgentPreset.with(id: "claude")!.connection()]
        agents.defaultAgent = "hermes"
        var talk = LiveTalkSettings()
        #expect(talk.agent(in: agents)?.id == "hermes")
        talk.agentID = "claude"
        #expect(talk.agent(in: agents)?.id == "claude")
        talk.agentID = "gone"
        #expect(talk.agent(in: agents)?.id == "hermes")
    }

    @Test func aVoiceServerAddressGetsItsSpeakPath() {
        #expect(TalkVoiceChoice.speakURL("http://msi:8890")?.absoluteString == "http://msi:8890/speak")
        #expect(TalkVoiceChoice.speakURL("https://voice.example.com/v1/")?.absoluteString == "https://voice.example.com/v1/speak")
        #expect(TalkVoiceChoice.speakURL("http://msi:8890/speak")?.absoluteString == "http://msi:8890/speak")
        #expect(TalkVoiceChoice.speakURL("msi:8890") == nil)
        #expect(TalkVoiceChoice.speakURL("ftp://x") == nil)
        #expect(OnMacVoice.michael.title == "Michael (American, Kokoro)")
        #expect(OnMacVoice.preston.title == "Preston (American, Phonon)")
        #expect(OnMacVoice(model: .phonon, voice: "en_gb_Hugh").title == "Hugh (British, Phonon)")
        #expect(OnMacVoice.offered.first == .standard)
        #expect(OnMacVoice.offered.contains(.michael))
    }

    @Test func theOfferedPhononVoicesAreTheOnesPinned() {
        let pinned = Set(PinnedModels.phonon.files.map(\.path).filter { $0.hasPrefix("voices/") })
        #expect(pinned == Set(OnMacVoice.phononVoices.map { "voices/\($0.voice).safetensors" }))
        #expect(OnMacVoice.offered.filter { $0.model == .phonon } == OnMacVoice.phononVoices)
    }

    @Test func toolCallsCarryTheirKindAndID() throws {
        let params: JSONValue = ["sessionId": "s", "update": ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "web_search", "kind": "fetch",
                                                               "status": "pending"]]
        let (_, update) = try #require(SessionUpdate.parse(params))
        #expect(update == .tool(title: "web_search", status: "pending", kind: "fetch", id: "t1"))
    }
}

@Suite("Live talk bar") struct TalkBarTests {
    private let hermes = BarAgent(initial: "H", name: "Hermes")

    @Test func aTalkOwnsTheBar() {
        let talk = TalkBar(agent: hermes, phase: .listening)
        let state = BarState.derive(hotkey: .idle, words: "", pending: 0, engine: .ready(boosting: .off), notice: .talkStarted(agent: "Hermes"),
                                    showsIdle: true, talk: talk)
        #expect(state.body == .talk(talk))
        #expect(state.toast == .talkStarted(agent: "Hermes"))
        #expect(BarNotice.talkStarted(agent: "Hermes").detail == "To end, double-tap Left Control or say goodbye.")
    }

    @Test func theBarShowsWordsOrAStatus() {
        #expect(TalkBar(agent: hermes, phase: .connecting).status == "Connecting to Hermes…")
        #expect(TalkBar(agent: hermes, phase: .listening, endingSoon: true).status == "Still there? Ending soon")
        #expect(TalkBar(agent: hermes, phase: .thinking, activity: "Checking your calendar").status == "Checking your calendar")
        #expect(TalkBar(agent: hermes, phase: .hearing, line: "what's on").words == "what's on")
        #expect(TalkBar(agent: hermes, phase: .thinking, line: "what's on").words == nil)
        #expect(TalkBar(agent: hermes, phase: .speaking, line: "You have two.").speaker == .agent)
        #expect(TalkBar(agent: hermes, phase: .hearing).speaker == .you)
        #expect(TalkBar(agent: hermes, phase: .thinking).speaker == .nobody)
    }

    @Test func theGlowBreathesAndFollowsWhoIsTalking() {
        #expect(TalkGlow.breath(at: 0) == 0)
        #expect(abs(TalkGlow.breath(at: TalkGlow.breathPeriod / 2) - 1) < 1e-9)
        #expect(TalkGlow.light(breath: 1, voice: 1, speaker: .nobody) < 0.5)
        #expect(abs(TalkGlow.light(breath: 0, voice: 1, speaker: .agent) - 1) < 1e-9)
        #expect(TalkGlow.beamSpeed(.agent) < 0)
        #expect(TalkGlow.beamSpeed(.you) == HaloGlow.speed)
        #expect(TalkGlow.rimColors(mix: 0).map(\.green) == TalkGlow.yourRimColors.map(\.green))
        // Neither side of a talk wears dictation's blues.
        #expect(TalkGlow.yourRimColors.map(\.blue) != HaloGlow.rimColors.map(\.blue))
        #expect(TalkGlow.agentRimColors.map(\.blue) != HaloGlow.rimColors.map(\.blue))
        #expect(zip(TalkGlow.rimColors(mix: 1), TalkGlow.agentRimColors).allSatisfy { abs($0.red - $1.red) < 1e-9 && abs($0.blue - $1.blue) < 1e-9 })
        #expect(TalkGlow.mix(for: .nobody, last: .agent) > TalkGlow.mix(for: .nobody, last: .you))
    }

    @Test func theBeamNeverJumpsWhenTheSpeakerChanges() {
        var clock = TalkGlow.BeamClock()
        var previous = clock.advance(to: 0, target: 260)
        var largest = 0.0
        for frame in 1...240 {
            let target = frame < 120 ? 260.0 : -208
            let head = clock.advance(to: Double(frame) / 60, target: target)
            largest = max(largest, abs(head - previous))
            previous = head
        }
        #expect(largest <= 260.0 / 60 + 1e-9)
        #expect(clock.speed < 0)
    }

    @Test func aBackwardBeamIsTheMirrorOfAForwardOne() {
        let forward = TalkGlow.beam(head: 100, perimeter: 1000, backward: false)
        let backward = TalkGlow.beam(head: -100, perimeter: 1000, backward: true)
        #expect(forward.count == backward.count)
        let brightest = forward.max { $0.light < $1.light }!, mirrored = backward.max { $0.light < $1.light }!
        #expect(abs(brightest.to - 0.1) < 1e-9)
        #expect(abs(mirrored.from - 0.9) < 1e-9)
    }
}

@Suite("Voice server audio") struct WAVFileTests {
    @Test func aWAVReadsBackAsItWasWritten() throws {
        let samples: [Float] = [0, 0.5, -0.5, 0.25, -1]
        let (back, rate) = try #require(WAVFile.decode(WAVFile.encode(samples, sampleRate: 24_000)))
        #expect(rate == 24_000)
        #expect(zip(samples, back).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func stereoFloatIsAveragedToMono() throws {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u32(36 + 16)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(3); u16(2); u32(22_050); u32(22_050 * 8); u16(8); u16(32)
        data.append(contentsOf: Array("data".utf8))
        u32(16)
        for value: Float in [0.5, 0.25, -1, 1] { u32(value.bitPattern) }
        let (back, rate) = try #require(WAVFile.decode(data))
        #expect(rate == 22_050)
        #expect(back == [0.375, 0])
    }

    @Test func somethingElseIsRefused() {
        #expect(WAVFile.decode(Data("not audio".utf8)) == nil)
    }
}

@Suite("Short first sentences")
struct ShortFirstSentenceTests {
    @Test func aShortSentenceIsTheFirstPiece() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("Sure. Let me check") == ["Sure."])
    }

    @Test func aFinishedSentenceWithNoSpaceYetCanBeFlushed() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("It's four.").isEmpty)
        #expect(chunker.sentenceEndWait == 0.15)
        #expect(chunker.finish() == ["It's four."])
    }

    @Test func aNumberWaitsLongerForADecimal() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("It went up 3.").isEmpty)
        #expect(chunker.sentenceEndWait == 0.6)
        #expect(chunker.feed("5 percent").isEmpty)
        #expect(chunker.sentenceEndWait == nil)
    }

    @Test func aBareNumberAnswerIsSaidWithoutWaitingForTheTurnToEnd() {
        var chunker = SpeechChunker()
        #expect(chunker.feed("366.").isEmpty)
        #expect(chunker.sentenceEndWait == 0.6)
        #expect(chunker.finish() == ["366."])
        #expect(chunker.feed("Is it 3?").isEmpty)
        #expect(chunker.sentenceEndWait == 0.15)
    }
}

@Suite("Talk permissions")
struct TalkPermissionTests {
    private func request(_ kind: String?, options: [String] = ["allow_once", "allow_always", "reject_once"], title: String = "Read notes.md") -> PermissionRequest {
        PermissionRequest(rpcID: .number(1), session: "s", title: title, options: options.map { .init(id: $0 + "-id", name: $0, kind: $0) }, toolKind: kind)
    }

    @Test func readingSearchingAndThinkingGoAheadOnce() {
        #expect(TalkPermission.decide(request("read")) == .answer("allow_once-id"))
        #expect(TalkPermission.decide(request("search")) == .answer("allow_once-id"))
    }

    @Test func onlyFetchingCanBeAllowedByVoice() {
        #expect(TalkPermission.decide(request("fetch")) == .ask(byVoice: true))
        for kind in ["execute", "edit", "delete", "move", "other"] { #expect(TalkPermission.decide(request(kind)) == .ask(byVoice: false)) }
        #expect(TalkPermission.decide(request(nil)) == .ask(byVoice: false))
    }

    @Test func alwaysIsNeverPicked() {
        #expect(TalkPermission.choice(request("execute"), allowed: true) == "allow_once-id")
        let onlyAlways = request("execute", options: ["allow_always", "reject_once"])
        #expect(TalkPermission.decide(onlyAlways) == .answer("reject_once-id"))
        #expect(TalkPermission.choice(onlyAlways, allowed: true) == nil)
        #expect(TalkPermission.choice(onlyAlways, allowed: false) == "reject_once-id")
    }

    @Test func aHarmlessTitleCantHideTheKind() {
        #expect(ToolLine.permissionPhrase(title: "Read the weather", kind: "execute") == "Running a command")
        #expect(ToolLine.permissionPhrase(title: "Check calendar", kind: "delete") == "Deleting a file")
        #expect(ToolLine.permissionPhrase(title: "google_calendar_list_events", kind: nil) == "Checking your calendar")
    }
}
