import Foundation
import Testing
@testable import DictationCore

@Suite("Live talk key") struct LiveTalkKeyTests {
    private let down: UInt64 = 0x4_0000 | 0x0001
    private let up: UInt64 = 0x100

    @Test func controlOptionMMutes() {
        let controlOption: UInt64 = 0x4_0000 | 0x8_0000
        #expect(LiveTalkKey.isMute(keyCode: 46, flags: controlOption))
        #expect(LiveTalkKey.isMute(keyCode: 46, flags: controlOption | 0x0001 | 0x100))
        #expect(!LiveTalkKey.isMute(keyCode: 46, flags: 0x4_0000))
        #expect(!LiveTalkKey.isMute(keyCode: 46, flags: controlOption | 0x10_0000))
        #expect(!LiveTalkKey.isMute(keyCode: 45, flags: controlOption))
        #expect(LiveTalkKey.muteName == "⌃⌥M")
    }

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

    @Test func theStartSoundIsNotTakenForTheRoom() {
        // Half a second of the start sound from the speakers, then the quiet room.
        let blocks = Array(repeating: echo, count: 17) + Array(repeating: quiet, count: 23)
        var ear = TalkEar(cue: 0.5)
        #expect(run(&ear, blocks, from: 0).isEmpty)
        #expect(ear.thresholds.start == calibrated().thresholds.start)
        #expect(run(&ear, Array(repeating: voice, count: 3), from: 1.2).map(\.0) == [.began])
        // Read from the first block, the sound would be the room, and a quiet voice would go unheard.
        var early = TalkEar()
        _ = run(&early, blocks, from: 0)
        #expect(early.thresholds.start > ear.thresholds.start)
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

    /// Feeds blocks as `run` does, with the agent's voice playing at `playing`.
    private func run(_ ear: inout TalkEar, _ blocks: [[Float]], from start: Double, playing: Float) -> [(TalkEar.Event, Double)] {
        var out: [(TalkEar.Event, Double)] = []
        for (index, block) in blocks.enumerated() {
            let time = start + Double(index + 1) * 0.03
            if let event = ear.hear(block, at: Instant(seconds: time), playing: playing) { out.append((event, time)) }
        }
        return out
    }

    @Test func loudSpeakersDoNotCutTheAgentOff() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        // A laptop's speakers: the agent's voice comes back louder than the plain cut-in level.
        let loudEcho = [Float](repeating: 0.06, count: 480)
        #expect(TalkEar.rms(loudEcho) > ear.thresholds.cutIn)
        // Its first words teach the ear how much of it the microphone hears, and after that its echo never cuts in.
        #expect(run(&ear, Array(repeating: loudEcho, count: 20), from: 2.4, playing: 0.1).isEmpty)
        #expect(run(&ear, Array(repeating: loudEcho, count: 60), from: 3.0, playing: 0.1).isEmpty)
        // Quieter words echo quieter, and a louder word louder; neither cuts in.
        #expect(run(&ear, Array(repeating: [Float](repeating: 0.1, count: 480), count: 20), from: 4.8, playing: 0.18).isEmpty)
        // You, clearly louder than the echo, still do.
        #expect(run(&ear, Array(repeating: voice, count: 6), from: 5.4, playing: 0.1).map(\.0) == [.cutIn])
    }

    @Test func theAgentsLastWordsInTheAirDoNotStartATurn() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        let loudEcho = [Float](repeating: 0.06, count: 480)
        _ = run(&ear, Array(repeating: loudEcho, count: 20), from: 2.4, playing: 0.1)
        ear.agentDone(at: Instant(seconds: 3))
        #expect(run(&ear, Array(repeating: loudEcho, count: 5), from: 3, playing: 0.1).isEmpty)
        // Once nothing plays, you start a turn as before.
        #expect(run(&ear, Array(repeating: voice, count: 3), from: 3.2, playing: 0).map(\.0) == [.began])
    }

    /// Learns from one reply's first words, each block heard at `heard` while `playing` played.
    private func firstWords(_ echo: inout TalkEcho, _ heard: [Float], playing: Float = 0.1, speakers: Bool = true) {
        echo.begin(speakers: speakers)
        for level in heard { echo.learn(heard: level, playing: playing, room: 0.008) }
        echo.settle()
    }

    @Test func aNewReplyRelearnsTheEcho() {
        var echo = TalkEcho()
        firstWords(&echo, Array(repeating: 0.06, count: 20))
        #expect(abs(echo.gain - 0.6) < 0.0001)
        #expect(abs(echo.level(0.1) - 0.12) < 0.0001)
        // Almost nothing playing teaches nothing.
        firstWords(&echo, Array(repeating: 0.05, count: 20), playing: 0.01)
        #expect(abs(echo.gain - 0.3) < 0.0001)
        // The volume turned down: the next reply's quieter echo takes over from half of the old.
        firstWords(&echo, Array(repeating: 0.01, count: 20))
        #expect(abs(echo.gain - 0.15) < 0.0001)
        // Headphones: nothing is heard back, and nothing is kept.
        firstWords(&echo, Array(repeating: 0.06, count: 20), speakers: false)
        #expect(echo.gain == 0)
    }

    @Test func aLoudSyllableThenQuieterOnesDoNotHideTheEcho() {
        var echo = TalkEcho()
        echo.begin(speakers: true)
        // The echo is 0.3 of what plays. A loud syllable at 0.3, then quieter ones at 0.03, measured as their slices go.
        for _ in 0..<7 { echo.learn(heard: 0.09, playing: 0.3, room: 0.008) }
        for _ in 0..<13 { echo.learn(heard: 0.009, playing: 0.03, room: 0.008) }
        echo.settle()
        #expect(abs(echo.gain - 0.3) < 0.0001)
        // So the loud syllable's echo, when it comes back, stays under the bar.
        #expect(echo.level(0.3) > 0.09)
    }

    @Test func theEchoIsLearnedOverTheSameStretchItPlayed() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        // A loud syllable then quieter ones; the bar's level still remembers the loud one for a while, but the echo is
        // learned from what played over each block's own stretch.
        let loud = [Float](repeating: 0.09, count: 480), soft = [Float](repeating: 0.012, count: 480)
        var time = 2.4
        for _ in 0..<7 { time += 0.03; _ = ear.hear(loud, at: Instant(seconds: time), playing: 0.3, playingNow: 0.3) }
        for _ in 0..<13 { time += 0.03; _ = ear.hear(soft, at: Instant(seconds: time), playing: 0.3, playingNow: 0.04) }
        // The loud syllable comes back after the first words: its echo doesn't cut in.
        var events: [TalkEar.Event] = []
        for _ in 0..<20 {
            time += 0.03
            if let event = ear.hear(loud, at: Instant(seconds: time), playing: 0.3, playingNow: 0.3) { events.append(event) }
        }
        #expect(events.isEmpty)
        #expect(ear.echo.gain >= 0.29)
    }

    @Test func talkInSomeOfTheFirstWordsIsNotTakenForEcho() {
        var echo = TalkEcho()
        // An echo at 0.03 all through, and you saying a word at 0.2 over part of it.
        firstWords(&echo, Array(repeating: 0.03, count: 7) + Array(repeating: 0.2, count: 7) + Array(repeating: 0.03, count: 6))
        #expect(abs(echo.gain - 0.3) < 0.0001)
        // Talk all through them is the most the echo can be.
        // Talk all through them raises the echo by at most half of what the last reply played to the end taught.
        echo.finished()
        firstWords(&echo, Array(repeating: 0.2, count: 20))
        #expect(abs(echo.gain - 0.45) < 0.0001)
        // That reply was cut in on, so the next is bound by the same.
        firstWords(&echo, Array(repeating: 0.2, count: 20))
        #expect(abs(echo.gain - 0.45) < 0.0001)
        // On the first reply, with nothing learned before, the most the echo can be.
        var fresh = TalkEcho()
        firstWords(&fresh, Array(repeating: 0.2, count: 20))
        #expect(fresh.gain == TalkEcho.most)
    }

    @Test func onSpeakersTalkingAllThroughTheFirstWordsStillLetsYouCutIn() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        // An earlier reply taught the laptop speakers' echo.
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        let loudEcho = [Float](repeating: 0.06, count: 480)
        _ = run(&ear, Array(repeating: loudEcho, count: 20), from: 2.4, playing: 0.3)
        ear.agentDone(at: Instant(seconds: 4))
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 4)
        // This reply, you talk all through its first words.
        ear.agentSpeaking(at: Instant(seconds: 6))
        _ = run(&ear, Array(repeating: voice, count: 20), from: 6, playing: 0.3)
        #expect(ear.echo.gain <= 0.2 * TalkEcho.growth + 0.0001)
        // Talking on at the same level cuts in, and keeps doing so reply after reply.
        var from = 6.6
        for _ in 0..<4 {
            #expect(run(&ear, Array(repeating: voice, count: 6), from: from, playing: 0.3).map(\.0) == [.cutIn])
            _ = run(&ear, Array(repeating: voice, count: 10) + Array(repeating: quiet, count: 30), from: from + 0.18)
            from += 2
            ear.agentSpeaking(at: Instant(seconds: from))
            _ = run(&ear, Array(repeating: voice, count: 20), from: from, playing: 0.3)
            #expect(ear.echo.gain <= 0.2 * TalkEcho.growth + 0.0001)
            from += 0.6
        }
    }

    @Test func withHeadphonesTalkingOverTheFirstWordsStillLetsYouCutIn() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4), speakers: false)
        _ = run(&ear, Array(repeating: voice, count: 20), from: 2.4, playing: 0.3)
        #expect(ear.echo.gain == 0)
        #expect(run(&ear, Array(repeating: voice, count: 6), from: 3.0, playing: 0.3).map(\.0) == [.cutIn])
    }

    @Test func theRoomTeachesNoEcho() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        // The microphone hears only the room, a little noisy, while the first words play quietly.
        let noise = [Float](repeating: 0.006, count: 480)
        #expect(TalkEar.rms(noise) < ear.thresholds.start)
        _ = run(&ear, Array(repeating: noise, count: 20), from: 2.4, playing: 0.03)
        // So talking over the agent works as it always did, however loud it plays.
        #expect(run(&ear, Array(repeating: voice, count: 6), from: 3.1, playing: 0.3).map(\.0) == [.cutIn])
        #expect(ear.echo.gain == 0)
    }

    @Test func aQuickNoOverTheAgentIsATurn() throws {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        ear.agentSpeaking(at: Instant(seconds: 2.4))
        _ = run(&ear, Array(repeating: echo, count: 30), from: 3.1)
        // About 0.24 s of voice: the six blocks it takes to cut in, and two more. They all count toward the turn.
        let events = run(&ear, Array(repeating: voice, count: 8) + Array(repeating: quiet, count: 30), from: 4)
        #expect(events.first?.0 == .cutIn)
        guard case .ended = try #require(events.last?.0) else { Issue.record("a quick no over the agent was dropped: \(events)"); return }
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

    @Test func mutingDropsYourTurnAndTheTimeMutedNeverEndsTheTalk() {
        var ear = calibrated()
        let events = run(&ear, Array(repeating: voice, count: 10), from: 0.6)
        #expect(events.map(\.0) == [.began])
        let dropped = ear.muted(at: Instant(seconds: 1))
        #expect(dropped)
        #expect(!ear.isHearing)
        // Five minutes muted, then unmuted: the quiet counts from the unmute, so the talk goes on.
        ear.unmuted(at: Instant(seconds: 300))
        #expect(ear.hear(quiet, at: Instant(seconds: 301)) == nil)
        #expect(ear.hear(quiet, at: Instant(seconds: 401)) == .idleWarning)
        // Nothing from before the mute starts the next turn: it takes the usual run of loud blocks.
        let next = run(&ear, Array(repeating: voice, count: 3), from: 402)
        #expect(next.map(\.0) == [.began])
    }

    @Test func mutingWhileTheAgentHasTheTurnLeavesItAlone() {
        var ear = calibrated()
        _ = run(&ear, Array(repeating: voice, count: 30) + Array(repeating: quiet, count: 30), from: 0.6)
        let dropped = ear.muted(at: Instant(seconds: 3))
        #expect(!dropped)
        ear.agentDone(at: Instant(seconds: 5))
        ear.unmuted(at: Instant(seconds: 50))
        #expect(ear.hear(quiet, at: Instant(seconds: 149)) == nil)
        #expect(ear.hear(quiet, at: Instant(seconds: 151)) == .idleWarning)
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
        // A step says what it is for in plain words, as Grok Bot's status line does: never a command, file or host.
        #expect(ToolLine.phrase(title: "terminal: hermes send -t photon \"call mom about the gmail thing\"", kind: "execute") == "Sending you a message")
        #expect(ToolLine.phrase(title: "Read ~/.ssh/id_ed25519", kind: "read") == "Doing some reading")
        #expect(ToolLine.phrase(title: "zz", kind: "search") == "Digging around")
        #expect(ToolLine.phrase(title: "", kind: nil) == "Chipping away")
    }

    @Test func toolLinesSayWhatTheAgentIsDoing() {
        let lines: [(String, String?, String)] = [
            ("terminal: t3-run status 1a7431fb-4f9e-45ec-a8f2-200f1da", "execute", "Checking T3 Code"),
            ("terminal: ~/bin/gog --account hunterbohm8@gmail.com gmail search 'from:x' --max 5", "execute", "Checking Gmail"),
            ("terminal: python3 skills/custom-skills/meet/prep.py --a", "execute", "Running a few commands"),
            ("terminal: python3 - <<'EOF' print(1) EOF", "execute", "Running a few commands"),
            ("terminal: K=$(cat ~/.config/cli-gateway/management.key) curl -s -H \"x: $K\" http://x", "execute", "Running a few commands"),
            ("terminal: OPENAI_API_KEY=sk-abc123 infisical run --env=prod -- git push origin main", "execute", "Running a few commands"),
            ("terminal: timeout 60 hermes cron list", "execute", "Checking with another agent"),
            ("terminal: git commit -m 'fix the gmail bug'", "execute", "Running a few commands"),
            ("terminal: ghp_abcdefghijklmnop1234567890 --x", "execute", "Running a few commands"),
            ("`cd ~/code && git status`", "execute", "Running a few commands"),
            ("skill_view: productivity/media-request", "read", "Thinking it through"),
            ("skill_view: obsidian → references/tasks.md", nil, "Thinking it through"),
            ("skill_view", nil, "Thinking it through"),
            ("read_file: plan.md", "read", "Doing some reading"),
            ("write_file: /tmp/a/notes.md", "edit", "Jotting it down"),
            ("web_search: cheap flights to denver friday morning", "fetch", "Digging around"),
            ("search_files: 'demo-password'", "search", "Digging around"),
            ("web_search: don't share this", "fetch", "Digging around"),
            ("web_search: cheap flights to denver \"private\"", "fetch", "Digging around"),
            ("web_extract: https://www.example.com/a?b=c", "fetch", "Doing some reading"),
            ("browser_navigate: https://mail.google.com/mail/u/0", nil, "Clicking through pages"),
            ("browser_exec", nil, "Clicking through pages"),
            ("tool_call: Scheduling", nil, "Scheduling"),
            ("cronjob_manage: create", nil, "Managing scheduled jobs"),
            ("delegate_task: Research flights", nil, "Checking with another agent"),
            ("google_calendar_list_events", "fetch", "Checking your calendar"),
        ]
        for (title, kind, line) in lines { #expect(ToolLine.phrase(title: title, kind: kind) == line, "\(title)") }
        // Short enough for the island, whatever the agent sends.
        #expect(ToolLine.phrase(title: "terminal: " + String(repeating: "a", count: 39) + " status", kind: "execute").count <= ToolLine.longest)
        #expect(ToolLine.symbol("Running a few commands") == "terminal")
        #expect(ToolLine.symbol("Digging around") == "magnifyingglass")
        #expect(ToolLine.symbol("Checking Gmail") == "envelope")
        #expect(ToolLine.symbol("Something new") == "sparkle")
    }

    @Test func aShortLineFromTheAgentIsANoticeInTheIsland() {
        let task = "PP-3 · ProfitPilot outreach: run it and improve overall, maybe add another channel · due Nov 9 · todo"
        #expect(TalkIsland.notice(.text(task)) == task)
        #expect(TalkIsland.notice(.text("  **Done.**\nAdded to Friday.  ")) == "Done.\nAdded to Friday.")
        // Links, images, visuals, code and long text stay cards.
        #expect(TalkIsland.notice(.link(URL(string: "https://example.com")!)) == nil)
        #expect(TalkIsland.notice(.html("<b>x</b>")) == nil)
        #expect(TalkIsland.notice(.text("git switch -c live-talk\nswift build -c release\nscripts/test.sh")) == nil)
        #expect(TalkIsland.notice(.text("let x = f()\nprint(x)")) == nil)
        #expect(TalkIsland.notice(.text(String(repeating: "word ", count: 60))) == nil)
        #expect(TalkIsland.notice(.text("a\nb\nc\nd")) == nil)
        #expect(TalkIsland.notice(.text("   ")) == nil)
        // What the agent wrote is kept, marks and all.
        #expect(TalkIsland.notice(.text("Added #123 to task_notes.md")) == "Added #123 to task_notes.md")
        #expect(TalkIsland.notice(.text("Moved the call (with Zach) to Friday")) == "Moved the call (with Zach) to Friday")
        // One-line commands and Markdown links stay cards.
        #expect(TalkIsland.notice(.text("echo \"$HOME\" > output_file")) == nil)
        #expect(TalkIsland.notice(.text("git push -u origin main")) == nil)
        for command in ["npm install", "git status", "python script.py", "./build.sh", "run scripts/test.sh now", "t3-run status"] {
            #expect(TalkIsland.notice(.text(command)) == nil, "\(command)")
        }
        // Prose that only mentions a tool is still a notice.
        #expect(TalkIsland.notice(.text("Pushed the fix to GitHub")) == "Pushed the fix to GitHub")
        #expect(TalkIsland.notice(.text("See [the doc](https://example.com/a)")) == nil)
    }

    @Test func stepsShowInTurnEachLongEnoughToRead() {
        var steps = StepQueue()
        let none = steps.next(at: Instant(seconds: 0))
        #expect(none.line == nil && none.wait == nil)
        steps.offer("Loading media-request skill")
        steps.offer("Running t3-run status")
        steps.offer("Running t3-run status")
        #expect(steps.next(at: Instant(seconds: 0)).line == "Loading media-request skill")
        let early = steps.next(at: Instant(seconds: 0.5))
        #expect(early.line == nil && abs((early.wait ?? 0) - 0.4) < 1e-9)
        #expect(steps.next(at: Instant(seconds: 0.9)).line == "Running t3-run status", "a repeat waits once")
        let done = steps.next(at: Instant(seconds: 5))
        #expect(done.line == nil && done.wait == nil)
        #expect(steps.shown == "Running t3-run status")
        // A burst keeps the newest few, in order.
        for line in ["a", "b", "c", "d", "e"] { steps.offer(line) }
        #expect(steps.next(at: Instant(seconds: 6)).line == "c")
        #expect(steps.next(at: Instant(seconds: 7)).line == "d")
        #expect(steps.next(at: Instant(seconds: 8)).line == "e")
    }

    @Test func onlyTheAgentsOwnLinesAreSaidAtMostOneEveryFewSeconds() {
        var announcer = ToolAnnouncer()
        let said = [
            announcer.announce("Turning on your lights", at: Instant(seconds: 0)),
            announcer.announce("Checking your calendar", at: Instant(seconds: 2)),
            announcer.announce("Checking your calendar", at: Instant(seconds: 5)),
            // A line said once this turn isn't said again.
            announcer.announce("turning on your lights", at: Instant(seconds: 20)),
        ]
        #expect(said == ["Turning on your lights", nil, "Checking your calendar", nil])
    }

    @Test func stepLinesAreSplitOutLikeShowBlocks() {
        var splitter = ShowSplitter()
        var pieces: [ReplyPiece] = []
        for chunk in ["On it. <st", "ep>Turning on your lights</st", "ep><show>done</show>", " All set."] { pieces += splitter.feed(chunk) }
        pieces += splitter.finish()
        #expect(pieces == [.speech("On it. "), .step("Turning on your lights"), .show("done"), .speech(" All set.")])
    }

    @Test func theAgentsLineIsCleanedForTheIsland() {
        #expect(ToolLine.agentLine("checking what's using your CPU.") == "Checking what's using your CPU")
        #expect(ToolLine.agentLine("**Looking for flights**") == "Looking for flights")
        #expect(ToolLine.agentLine(" . ") == nil)
        #expect(ToolLine.agentLine("Using key sk-abc123def456ghi789jkl") == nil)
        #expect(ToolLine.agentLine(String(repeating: "word ", count: 20))!.count <= ToolLine.longest)
    }

    @Test func toolCallsGoUnderTheAgentsLineUntilItSaysSomethingElse() {
        var steps = StepQueue()
        steps.offerAgent("Turning on your lights")
        let first = steps.claim(call: "a", app: nil), second = steps.claim(call: "b", app: nil)
        #expect(first && second)
        // A claimed call's later updates never put its own words up.
        steps.offer("Running a few commands", call: "b")
        #expect(steps.has(call: "b"))
        let shown = steps.next(at: Instant(seconds: 0)).line, after = steps.next(at: Instant(seconds: 5)).line
        #expect(shown == "Turning on your lights")
        #expect(after == nil)
        let failed = steps.fail(call: "a")
        #expect(failed)
        #expect(steps.step?.failed == true)
        steps.endAgentStep()
        let third = steps.claim(call: "c", app: nil)
        #expect(!third)
        steps.offer("Checking Gmail", call: "c")
        let next = steps.next(at: Instant(seconds: 6)).line
        #expect(next == "Checking Gmail")
    }

    @Test func everyTalkAsksForPlainStepLines() {
        #expect(TalkPrompt.note.contains("<step>Turning on your lights</step>"))
        #expect(TalkPrompt.note.contains("never a command"))
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
        // It says how to call back without a skill, and a Hermes saved with the earlier note gets this one.
        #expect(agent.talkNote.contains("call-me-back run --about"))
        #expect(agent.talkNote.contains("don't load a skill"))
        var saved = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as! [String: Any]
        saved["talkNote"] = AgentPreset.formerTalkNotes["hermes"]!.first!
        let reloaded = try! JSONDecoder().decode(AgentConnection.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(reloaded.talkNote == AgentPreset.hermesTalkNote)
        saved["talkNote"] = "My own note."
        #expect(try! JSONDecoder().decode(AgentConnection.self, from: JSONSerialization.data(withJSONObject: saved)).talkNote == "My own note.")
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

    @Test func mutedShowsAllThroughTheTalk() {
        let muted = TalkBar(agent: hermes, phase: .listening, muted: true)
        #expect(muted.status == "Muted")
        #expect(TalkIsland.headline(muted) == "Muted")
        #expect(TalkIsland.ear(muted) == .muted)
        #expect(TalkIsland.mood(muted) == .muted)
        // While the agent works or speaks the globe stays red, so the shortcut always shows it took. Its voice still plays,
        // so the ear shows that while it speaks.
        let speaking = TalkBar(agent: hermes, phase: .speaking, line: "Two meetings.", muted: true)
        #expect(TalkIsland.ear(speaking) == .voice(agent: true))
        #expect(TalkIsland.mood(speaking) == .muted)
        let thinking = TalkBar(agent: hermes, phase: .thinking, muted: true)
        #expect(TalkIsland.mood(thinking) == .muted)
        #expect(TalkIsland.ear(thinking) == .muted)
        #expect(TalkIsland.mood(TalkBar(agent: hermes, phase: .connecting, muted: true)) == .connecting)
        #expect(TalkIsland.ear(TalkBar(agent: hermes, phase: .listening)) == .voice(agent: false))
    }

    @Test func aTalkOwnsTheBar() {
        let talk = TalkBar(agent: hermes, phase: .listening)
        let state = BarState.derive(hotkey: .idle, words: "", pending: 0, engine: .ready(boosting: .off), notice: nil,
                                    showsIdle: true, talk: talk)
        #expect(state.body == .talk(talk))
        // Starting a talk pops nothing up under the island: how to end it is inside, beside the button that ends it.
        #expect(state.toast == nil)
        #expect(TalkIsland.endHint == "Double-tap Left Control or say goodbye to end")
        #expect(TalkIsland.muteHelp(muted: false) == "Mute your microphone (⌃⌥M)")
        #expect(TalkIsland.muteHelp(muted: true) == "Unmute your microphone (⌃⌥M)")
    }

    @Test func theRimStandsOutOnABlackWindow() {
        let moods: [TalkIsland.Mood] = [.connecting, .you, .thinking, .speaking, .ringing, .muted]
        for mood in moods {
            // Even where it is faintest, an edge needs a contrast of 3 against black to be seen.
            #expect(TalkIsland.edgeContrast(mood) >= 3)
            #expect(TalkIsland.edgeContrast(mood, opacity: TalkIsland.edgeBrightest) > TalkIsland.edgeContrast(mood))
        }
        // The rim takes the mood's colour: bluer while you talk, warmer while the agent does.
        #expect(TalkIsland.edgeColor(.you).blue > TalkIsland.edgeColor(.you).red)
        #expect(TalkIsland.edgeColor(.speaking).red > TalkIsland.edgeColor(.speaking).blue)
        #expect(TalkIsland.edgeColor(.you).red != TalkIsland.edgeColor(.thinking).red)
    }

    @Test func aTalkSoundsUnlikeADictation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = try String(contentsOf: root.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        var sounds: [String: Data] = [:]
        for file in Cue.allCases.map(\.file) + TalkCue.allCases.map(\.file) {
            sounds[file] = try Data(contentsOf: root.appending(path: "Resources/\(file).wav"))
            // A sound the build leaves out of the app is silence.
            #expect(build.contains(" \(file).wav "))
        }
        #expect(Set(sounds.values).count == 5)
        #expect(TalkCue.start.file == "talk-start" && TalkCue.end.file == "talk-end")
        // The fn key still makes a dictation's sounds, never a talk's.
        #expect(Cue.after([.start], wasListening: false, isListening: true) == .start)
        #expect(Cue.after([.finish], wasListening: true, isListening: false) == .stop)
    }

    @Test func theIslandSaysWhatIsHappening() {
        #expect(TalkBar(agent: hermes, phase: .connecting).status == "Connecting to Hermes…")
        #expect(TalkBar(agent: hermes, phase: .listening, endingSoon: true).status == "Still there? Ending soon")
        #expect(TalkBar(agent: hermes, phase: .thinking, activity: "Checking your calendar").status == "Checking your calendar")
        #expect(TalkIsland.headline(TalkBar(agent: hermes, phase: .hearing)) == "Listening")
        #expect(TalkIsland.headline(TalkBar(agent: hermes, phase: .speaking)) == "Hermes")
    }

    @Test func theIslandOpensWhenThereIsSomethingToRead() {
        #expect(!TalkIsland.isOpen(TalkBar(agent: hermes, phase: .listening), hovering: false))
        #expect(!TalkIsland.isOpen(TalkBar(agent: hermes, phase: .hearing, line: "what's on"), hovering: false))
        #expect(!TalkIsland.isOpen(TalkBar(agent: hermes, phase: .thinking), hovering: false))
        #expect(TalkIsland.isOpen(TalkBar(agent: hermes, phase: .thinking, line: "what's on"), hovering: false))
        #expect(TalkIsland.isOpen(TalkBar(agent: hermes, phase: .thinking, activity: "Checking your calendar"), hovering: false))
        #expect(TalkIsland.isOpen(TalkBar(agent: hermes, phase: .speaking, line: "You have two."), hovering: false))
        #expect(TalkIsland.isOpen(TalkBar(agent: hermes, phase: .listening, endingSoon: true), hovering: false))
        // The pointer over it opens it, which shows the button that ends the talk.
        #expect(TalkIsland.isOpen(TalkBar(agent: hermes, phase: .listening), hovering: true))
    }

    @Test func theIslandFitsTheNotch() {
        let notched = TalkIsland.Screen(hasNotch: true, notchWidth: 185, barHeight: 32)
        #expect(TalkIsland.compactWidth(notched) == 185 + 2 * 54)
        // Floating, it is a little bigger than the bar a dictation shows, which is 220 by 40.
        #expect(TalkIsland.compactWidth(.plain) == 132 + 2 * 62)
        #expect(TalkIsland.compactWidth(.plain) > 220 && TalkIsland.Screen.plain.barHeight > 40)
        // The globe fits the header with black around it as it floats, under a notch too.
        for screen in [notched, .plain] { #expect(TalkIsland.globeSize(screen) + 2 * TalkIsland.globeBob <= screen.barHeight - 10) }
        #expect(TalkIsland.openWidth(notched) > TalkIsland.compactWidth(notched))
        #expect(TalkIsland.openWidth(TalkIsland.Screen(hasNotch: true, notchWidth: 900, barHeight: 32)) == TalkIsland.widest)
    }

    @Test func theOrbAndEarFollowWhoIsTalking() {
        #expect(TalkIsland.mood(.hearing) == .you && TalkIsland.mood(.speaking) == .speaking && TalkIsland.mood(.thinking) == .thinking)
        #expect(TalkIsland.ear(.hearing) == .voice(agent: false))
        #expect(TalkIsland.ear(.speaking) == .voice(agent: true))
        #expect(TalkIsland.ear(.thinking) == .working && TalkIsland.ear(.connecting) == .working)
        #expect(TalkIsland.orbSpeed(.thinking) > TalkIsland.orbSpeed(.you))
        for mood in [TalkIsland.Mood.connecting, .you, .thinking, .speaking] { #expect(TalkIsland.orbColors(mood).count == 3) }
        // The orb swells with the voice and stays within a quarter of its size.
        #expect(TalkIsland.orbScale(level: 1, mood: .you, time: 0) > TalkIsland.orbScale(level: 0, mood: .you, time: 0))
        #expect(TalkIsland.orbScale(level: 5, mood: .you, time: 0) <= 1.22 + 1e-9)
    }

    @Test func theGlobeIsAGridOfDotsThatTurnsAndAnswersTheVoice() {
        let grid = TalkIsland.globeGrid
        let quiet = TalkIsland.globeDots(time: 1, level: 0, mood: .you)
        // Dots, not a solid ball: every dot sits inside the disc, smaller than its cell, and some cells are dark sea.
        #expect(!quiet.isEmpty)
        for dot in quiet {
            let x = (Double(dot.column) + 0.5) / Double(grid) * 2 - 1, y = (Double(dot.row) + 0.5) / Double(grid) * 2 - 1
            #expect(x * x + y * y <= 1)
            #expect(dot.size < 1 && dot.size > 0)
            #expect((0...1).contains(dot.brightness))
            #expect((0..<3).contains(dot.tint))
        }
        #expect(Set(quiet.map(\.size)).count > 1, "sizes step like an ASCII ramp")
        // It turns: the land moves between two moments.
        #expect(TalkIsland.globeDots(time: 4, level: 0, mood: .you) != quiet)
        // The voice brightens it.
        let loud = TalkIsland.globeDots(time: 1, level: 1, mood: .you)
        #expect(loud.map(\.brightness).reduce(0, +) > quiet.map(\.brightness).reduce(0, +))
        // It turns faster while the agent works than while it waits on you.
        // Counted by the dots whose size changed as land and sea moved under them.
        let turn = { (mood: TalkIsland.Mood) in
            let sizes = { (time: Double) in
                Dictionary(TalkIsland.globeDots(time: time, level: 0, mood: mood).map { ("\($0.column),\($0.row)", $0.size) },
                           uniquingKeysWith: { a, _ in a })
            }
            let before = sizes(0), after = sizes(1)
            return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.count
        }
        #expect(turn(.thinking) > turn(.you))
        #expect(abs(TalkIsland.globeFloat(time: 3)) <= TalkIsland.globeBob)
        // Swollen by a loud voice and breathing, it still fits the header.
        let biggest = TalkIsland.globeSize(.plain) * TalkIsland.globeScale(level: 1, mood: .thinking, time: Double.pi / 9)
        #expect(biggest / 2 + TalkIsland.globeBob <= TalkIsland.Screen.plain.barHeight / 2)
    }

    @Test func theVoiceBarsRiseWithTheLevelAndStayInTheEar() {
        for index in 0..<5 {
            #expect(TalkIsland.barHeight(index: index, level: 0, time: 1) == 4)
            #expect(TalkIsland.barHeight(index: index, level: 1, time: 1) <= TalkIsland.barTallest)
        }
        #expect(TalkIsland.barHeight(index: 2, level: 0.8, time: 0.3) > TalkIsland.barHeight(index: 2, level: 0.1, time: 0.3))
        #expect((0..<3).allSatisfy { (0...1).contains(TalkIsland.dotLift(index: $0, time: 2.2)) })
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

@Suite("Talk with T3 Code's tools")
struct TalkT3Tests {
    private func call(_ tool: String, input: JSONValue? = nil, kind: String? = "other",
                      options: [String] = ["allow_once", "allow_always", "reject_once"]) -> PermissionRequest {
        PermissionRequest(rpcID: .number(1), session: "s", title: "mcp__lip-service-t3__\(tool)",
                          options: options.map { .init(id: $0 + "-id", name: $0, kind: $0) }, toolKind: kind,
                          toolName: T3Talk.toolPrefix + tool, input: input)
    }

    @Test func claudeCodeCarriesTheToolsAndNobodyElseDoes() {
        #expect(AgentPreset.with(id: "claude")!.connection().talkT3)
        for preset in AgentPreset.all where preset.id != "claude" { #expect(!preset.connection().talkT3, "\(preset.id)") }
        #expect(AgentPreset.with(id: "claude")!.connection().talkNote.contains("short"))
    }

    @Test func anAgentSavedBeforeGetsThePresetsSetting() throws {
        let old = #"{"id":"claude","name":"Claude Code","presetID":"claude","command":["npx"],"spokenNames":["Claude"],"draftOptions":[],"#
            + #""taskOptions":[],"talkOptions":[],"talkNote":"","destination":{"agentReply":{}}}"#
        let agent = try JSONDecoder().decode(AgentConnection.self, from: Data(old.utf8))
        #expect(agent.talkT3)
        var off = agent
        off.talkT3 = false
        #expect(try JSONDecoder().decode(AgentConnection.self, from: JSONEncoder().encode(off)).talkT3 == false)
    }

    @Test func theSessionNamesAStdioServerThatHoldsNoSecret() {
        let server = ACP.stdioServer(name: "lip-service-t3", command: "/Applications/Lip Service.app/Contents/MacOS/Dictation", args: ["--t3-mcp"])
        #expect(server == ["name": "lip-service-t3", "command": "/Applications/Lip Service.app/Contents/MacOS/Dictation", "args": ["--t3-mcp"], "env": []])
        #expect(ACP.newSession(cwd: "/tmp/x", mcpServers: [server])["mcpServers"]?.array?.count == 1)
        #expect(ACP.newSession(cwd: "/tmp/x", mcpServers: []) == ["cwd": "/tmp/x", "mcpServers": []])
        // Not "auto", where Claude Code may start a thread without asking.
        #expect(T3Talk.sessionOptions == [.option(id: "mode", value: "default")])
    }

    private func tool(_ name: String, properties: [String: JSONValue] = [:]) -> JSONValue {
        ["name": .string(name), "description": "d", "inputSchema": ["type": "object", "properties": .object(properties), "required": ["projectId", "runtimeMode"]],
         "outputSchema": ["type": "object"]]
    }

    @Test func onlyFourOfTheServersSeventyToolsAreOffered() {
        let all = ["t3_project_delete", "t3_thread_launch", "preview_evaluate", "t3_project_list", "t3_thread_read", "t3_thread_list", "request_secret",
                   "t3_thread_send", "delegate_task"].map { tool($0) }
        let offered = T3Talk.exposed(all)
        #expect(offered.compactMap { $0["name"]?.string }.sorted() == ["t3_project_list", "t3_thread_launch", "t3_thread_list", "t3_thread_read"].sorted())
        #expect(offered.allSatisfy { $0["outputSchema"] == nil })
        #expect(T3Talk.exposed([]).isEmpty)
    }

    @Test func startingAThreadTakesOnlyTheProjectTheTaskAndATitle() {
        let launch = tool("t3_thread_launch", properties: ["projectId": ["type": "string"], "title": ["type": "string"], "runtimeMode": ["type": "string"],
                                                           "workspaceStrategy": ["type": "object"], "message": ["type": "string"]])
        let schema = T3Talk.exposed([launch])[0]
        #expect(schema["description"]?.string == T3Talk.launchDescription)
        if case .object(let properties)? = schema["inputSchema"]?["properties"] { #expect(Set(properties.keys) == ["projectId", "title", "message"]) } else { Issue.record("no properties") }
        #expect(schema["inputSchema"]?["required"]?.array == ["projectId"])
        let args = T3Talk.arguments(for: "t3_thread_launch", ["projectId": "p", "title": "t", "message": "m", "runtimeMode": "full-access",
                                                                "workspaceStrategy": ["type": "worktree"], "scratch": true], requestID: "req-1")
        #expect(args == ["projectId": "p", "title": "t", "message": "m", "clientRequestId": "req-1"])
        // The agent's own request id stays, so its retry after a lost answer is the same request.
        #expect(T3Talk.arguments(for: "t3_thread_launch", ["projectId": "p", "clientRequestId": "mine"], requestID: "req-1")?["clientRequestId"]?.string == "mine")
        #expect(T3Talk.arguments(for: "t3_thread_launch", nil, requestID: "req-2") == ["clientRequestId": "req-2"])
    }

    @Test func aToolThatIsNotOfferedIsNeverCalled() {
        for name in ["t3_project_delete", "t3_thread_send", "preview_evaluate", "request_secret", "t3_project_create", "unknown"] {
            #expect(T3Talk.arguments(for: name, ["projectId": "p"], requestID: "r") == nil, "\(name)")
        }
        #expect(T3Talk.arguments(for: "t3_thread_read", ["threadId": "x"], requestID: "r") == ["threadId": "x"])
        #expect(T3Talk.arguments(for: "t3_project_list", nil, requestID: "r") == ["limit": 100])
        #expect(T3Talk.arguments(for: "t3_project_list", ["limit": 5, "cursor": 20], requestID: "r") == ["limit": 5, "cursor": 20])
    }

    @Test func listingAndReadingGoAheadAndStartingAThreadTakesASpokenYes() {
        for tool in T3Talk.readingTools { #expect(TalkPermission.decide(call(tool)) == .answer("allow_once-id"), "\(tool)") }
        #expect(TalkPermission.decide(call("t3_thread_launch")) == .ask(byVoice: true))
        #expect(TalkPermission.choice(call("t3_thread_launch"), allowed: true) == "allow_once-id")
        // Only "allow once": a request that offers nothing else is refused.
        #expect(TalkPermission.decide(call("t3_thread_launch", options: ["allow_always", "reject_once"])) == .answer("reject_once-id"))
    }

    @Test func anyOtherToolOfTheServerNeedsAClick() {
        for tool in ["t3_project_delete", "t3_thread_send", "request_secret", "preview_evaluate", "a_tool_added_later"] {
            #expect(TalkPermission.decide(call(tool)) == .ask(byVoice: false), "\(tool)")
        }
        // The same name from a server that isn't ours is no T3 tool.
        let other = PermissionRequest(rpcID: .number(1), session: "s", title: "x", options: [.init(id: "allow_once-id", name: "a", kind: "allow_once")],
                                      toolKind: "other", toolName: "mcp__elsewhere__t3_thread_launch")
        #expect(TalkPermission.decide(other) == .ask(byVoice: false))
    }

    @Test func theQuestionIsBuiltFromWhatTheAgentPassesToT3() {
        let input: JSONValue = ["projectId": "p1", "title": "Fix the login bug", "message": "The login form drops the cursor. Fix it."]
        let request = call("t3_thread_launch", input: input)
        #expect(T3Talk.isLaunch(request))
        #expect(T3Talk.launchDetails(request).projectID == "p1")
        #expect(T3Talk.launchPhrase(request, projectName: "Lip Service") == "Start a T3 Code thread in Lip Service called Fix the login bug")
        #expect(T3Talk.launchPhrase(request, projectName: nil) == "Start a T3 Code thread called Fix the login bug")
        let untitled = call("t3_thread_launch", input: ["message": "Fix it"])
        #expect(T3Talk.launchPhrase(untitled, projectName: nil) == "Start a T3 Code thread called Fix it")
        #expect(T3Talk.launchPhrase(call("t3_thread_launch"), projectName: nil) == "Start a T3 Code thread")
        #expect(!T3Talk.isLaunch(call("t3_project_list")))
    }

    @Test func aPermissionRequestCarriesTheToolNameAndInput() {
        let params: JSONValue = ["sessionId": "s", "toolCall": ["title": "mcp__lip-service-t3__t3_thread_launch", "kind": "other",
                                                               "rawInput": ["projectId": "p1"],
                                                               "_meta": ["claudeCode": ["toolName": "mcp__lip-service-t3__t3_thread_launch"]]],
                                 "options": [["optionId": "y", "name": "Yes", "kind": "allow_once"]]]
        let request = PermissionRequest.parse(id: 1, params: params)
        #expect(request?.toolName == "mcp__lip-service-t3__t3_thread_launch")
        #expect(request?.input?["projectId"]?.string == "p1")
        #expect(T3Talk.tool(of: request!) == "t3_thread_launch")
    }

    @Test func theNoteNamesNoSecretAndLeavesTheAskingToLipService() {
        #expect(T3Talk.note.contains("t3_thread_launch"))
        #expect(T3Talk.note.contains("don't ask me first"))
        #expect(!T3Talk.note.lowercased().contains("bearer"))
        #expect(ToolLine.phrase(title: "mcp__lip-service-t3__t3_thread_launch", kind: nil) == "Starting a thread in T3 Code")
        #expect(ToolLine.phrase(title: "t3_project_list", kind: nil) == "Looking through your T3 projects")
    }
}

@Suite("Required session options") struct RequiredOptionsTests {
    @Test func savedOptionCannotUndoRequiredMode() {
        let saved: [ConfigChoice] = [.option(id: "mode", value: "auto"), .option(id: "effort", value: "low"), .model("opus")]
        let kept = ConfigChoice.sparing(T3Talk.sessionOptions, from: saved)
        #expect(kept == [.option(id: "effort", value: "low"), .model("opus")])
    }

    @Test func nothingRequiredKeepsEverything() {
        let saved: [ConfigChoice] = [.option(id: "mode", value: "auto"), .model("opus")]
        #expect(ConfigChoice.sparing([], from: saved) == saved)
    }

    @Test func requiredModelDropsSavedModel() {
        #expect(ConfigChoice.sparing([.model("a")], from: [.model("b"), .option(id: "x", value: "1")]) == [.option(id: "x", value: "1")])
    }
}
