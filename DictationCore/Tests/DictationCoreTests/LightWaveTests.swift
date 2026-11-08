import Foundation
import Testing
@testable import DictationCore

@Suite("LightWave") struct LightWaveTests {
    @Test func amplitudeRisesWithTheVoiceAndStaysInTheCapsule() {
        #expect(LightWave.amplitude(level: 0) == LightWave.restingAmplitude)
        #expect(LightWave.amplitude(level: 1) == LightWave.loudestAmplitude)
        #expect(LightWave.amplitude(level: 0.5) > LightWave.amplitude(level: 0.2))
        // An everyday voice already swells the waves more than halfway.
        #expect(LightWave.amplitude(level: 0.35) > (LightWave.restingAmplitude + LightWave.loudestAmplitude) / 2)
        #expect(LightWave.amplitude(level: 3) == LightWave.loudestAmplitude && LightWave.amplitude(level: -1) == LightWave.restingAmplitude)
        // The bar is 40 points tall; the tallest wave keeps a few points clear of its edge.
        #expect(LightWave.loudestAmplitude < 20 - 3)
        #expect(LightWave.finishingAmplitude < LightWave.restingAmplitude)
    }

    @Test func wavesTaperToNothingAtBothEnds() {
        #expect(LightWave.taper(0) == 0 && abs(LightWave.taper(1)) < 1e-9)
        #expect(abs(LightWave.taper(0.5) - 1) < 1e-12)
        for strand in LightWave.strands {
            for time in [0.0, 0.4, 3.7] {
                #expect(abs(LightWave.offset(strand, along: 0, time: time, amplitude: 15)) < 1e-9)
                #expect(abs(LightWave.offset(strand, along: 1, time: time, amplitude: 15)) < 1e-9)
                #expect(abs(LightWave.offset(strand, along: 0.5, time: time, amplitude: 15)) <= 15 * strand.share + 1e-9)
            }
        }
    }

    @Test func wavesMove() {
        let strand = LightWave.strands[0]
        #expect(LightWave.offset(strand, along: 0.3, time: 0, amplitude: 10) != LightWave.offset(strand, along: 0.3, time: 0.1, amplitude: 10))
    }

    @Test func strandsAreBlue() {
        #expect(LightWave.strands.count == 3)
        for strand in LightWave.strands { #expect(strand.blue >= strand.red && strand.blue >= strand.green) }
    }

    @Test func aSparkCrossesOnceAndFades() {
        #expect(LightWave.spark(startedAt: 1, at: 0.9) == nil)
        let start = LightWave.spark(startedAt: 1, at: 1)!
        #expect(start.along == 0 && start.light == 0)
        let early = LightWave.spark(startedAt: 1, at: 1 + LightWave.sparkLife * LightWave.fade)!
        let later = LightWave.spark(startedAt: 1, at: 1 + LightWave.sparkLife / 2)!
        #expect(abs(early.light - (1 - 0.6 * LightWave.fade)) < 1e-9)
        #expect(abs(later.along - 0.5) < 1e-12 && later.light < early.light)
        #expect(LightWave.spark(startedAt: 1, at: 1 + LightWave.sparkLife * 0.999)!.light < 0.05)
        #expect(LightWave.spark(startedAt: 1, at: 1 + LightWave.sparkLife) == nil)
    }

    @Test func eachNewWordStartsASparkUpToALimit() {
        #expect(LightWave.sparks(forAdded: 0, at: 2).isEmpty)
        #expect(LightWave.sparks(forAdded: -2, at: 2).isEmpty)
        #expect(LightWave.sparks(forAdded: 2, at: 2) == [2, 2 + LightWave.sparkStagger])
        #expect(LightWave.sparks(forAdded: 9, at: 2).count == LightWave.sparksPerUpdate)
    }

    @Test func aSparkKeepsCrossingWhileTheWordsAreFinished() {
        let every = LightWave.finishingSparkEvery
        #expect(LightWave.finishingSpark(at: every * 2.5) == every * 2)
        #expect(LightWave.finishingSpark(at: every * 3) == every * 3)
        #expect(every > LightWave.sparkLife)
    }

    private func added(_ old: String, _ new: String) -> Int {
        LightWave.addedWords(from: old.split(separator: " "), to: new.split(separator: " "))
    }

    @Test func newWordsAreCountedWhileTheWindowHoldsEverything() {
        #expect(added("", "so I") == 2)
        #expect(added("so I", "so I was thinking") == 2)
        #expect(added("so I was", "so I was") == 0)
        #expect(added("so I was", "so I") == 0)
    }

    @Test func newWordsAreCountedOnceOldOnesDropOffTheFront() {
        // The 15 s window slid: two words left the front and two arrived, so the count did not change.
        #expect(added("so I was thinking we could", "was thinking we could move the") == 2)
        // It slid further than words arrived, so the count fell.
        #expect(added("so I was thinking we could", "thinking we could move") == 1)
    }

    @Test func aRevisedWordCountsAsNew() {
        #expect(added("send it to their", "send it to there") == 1)
        #expect(added("so I was thinking we could", "thinking we could moo the") == 2)
        #expect(added("alpha beta", "gamma") == 1)
        #expect(added("alpha beta", "") == 0)
    }
}
