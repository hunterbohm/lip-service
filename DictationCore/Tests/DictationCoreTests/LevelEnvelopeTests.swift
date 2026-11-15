import Testing
@testable import DictationCore

private func run(_ envelope: inout LevelEnvelope, from start: Double, seconds: Double, target: Float) -> Double {
    envelope.follow(target)
    let end = start + seconds
    var time = start
    while time < end - 1e-9 { time += 1.0 / 120; envelope.advance(to: time) }
    return time
}

@Suite("LevelEnvelope") struct LevelEnvelopeTests {
    @Test func attackReachesAboutSixtyThreePercentInOneTimeConstant() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        let time = run(&envelope, from: 0, seconds: LevelEnvelope.attack, target: 1)
        #expect(abs(envelope.level(delay: 0, at: time) - 0.632) < 0.04)
    }

    @Test func releaseIsSlowerThanAttack() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        var time = run(&envelope, from: 0, seconds: 1, target: 1)
        let peak = envelope.level(delay: 0, at: time)
        time = run(&envelope, from: time, seconds: LevelEnvelope.attack, target: 0)
        #expect(envelope.level(delay: 0, at: time) > peak * (1 - 0.632))
        time = run(&envelope, from: time, seconds: 1.5, target: 0)
        #expect(envelope.level(delay: 0, at: time) < 0.01)
    }

    @Test func delayReadsTheEarlierLevel() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        var time = run(&envelope, from: 0, seconds: 1, target: 1)
        time = run(&envelope, from: time, seconds: 0.5, target: 0)
        #expect(envelope.level(delay: 0.5, at: time) > envelope.level(delay: 0, at: time) + 0.5)
    }

    @Test func readingMovesSmoothlyAcrossDelaysAndTime() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        let time = run(&envelope, from: 0, seconds: 0.6, target: 0.8)
        var previous = envelope.level(delay: 0, at: time)
        var biggestJump: Float = 0
        for step in 1...400 {
            let level = envelope.level(delay: Double(step) * 0.001, at: time)
            biggestJump = max(biggestJump, abs(level - previous))
            previous = level
        }
        #expect(biggestJump < 0.01)
    }

    @Test func nothingBeyondTwoSecondsAndNothingBeforeTheClockStarts() {
        var envelope = LevelEnvelope()
        #expect(envelope.level(delay: 0, at: 5) == 0)
        envelope.advance(to: 0)
        let time = run(&envelope, from: 0, seconds: 3, target: 1)
        #expect(envelope.level(delay: 2.5, at: time) == 0)
        #expect(envelope.level(delay: 1.5, at: time) > 0.9)
    }

    @Test func aFilledEnvelopeReadsItsProfile() {
        let envelope = LevelEnvelope { age in age < 0.5 ? 0.8 : 0.2 }
        #expect(abs(envelope.level(delay: 0.1, at: 0) - 0.8) < 0.001)
        #expect(abs(envelope.level(delay: 1, at: 0) - 0.2) < 0.001)
    }

    private func levels(_ voice: inout LevelEnvelope, _ glow: inout LevelEnvelope, from start: Double, seconds: Double, target: Float) -> Double {
        voice.follow(target)
        glow.follow(target)
        var time = start
        while time < start + seconds {
            time += 1.0 / 60
            voice.advance(to: time)
            glow.advance(to: time)
        }
        return time
    }

    @Test func theGlowTrailsTheVoiceAndReachesTheSameLevel() {
        var voice = LevelEnvelope(), glow = LevelEnvelope(stages: LevelEnvelope.glow)
        voice.advance(to: 0)
        glow.advance(to: 0)
        var time = levels(&voice, &glow, from: 0, seconds: 0.2, target: 1)
        #expect(glow.level(delay: 0, at: time) < voice.level(delay: 0, at: time) - 0.1)
        time = levels(&voice, &glow, from: time, seconds: 3, target: 1)
        #expect(glow.level(delay: 0, at: time) > 0.99)
        #expect(abs(glow.level(delay: 0, at: time) - voice.level(delay: 0, at: time)) < 0.01)
        time = levels(&voice, &glow, from: time, seconds: 0.3, target: 0)
        #expect(glow.level(delay: 0, at: time) > voice.level(delay: 0, at: time) + 0.05)
        time = levels(&voice, &glow, from: time, seconds: 3, target: 0)
        #expect(glow.level(delay: 0, at: time) < 0.01 && voice.level(delay: 0, at: time) < 0.01)
    }

    @Test func resettingKeepsTheStages() {
        var voice = LevelEnvelope(), glow = LevelEnvelope(stages: LevelEnvelope.glow)
        glow.reset()
        voice.advance(to: 0)
        glow.advance(to: 0)
        let time = levels(&voice, &glow, from: 0, seconds: 0.2, target: 1)
        #expect(glow.level(delay: 0, at: time) < voice.level(delay: 0, at: time) - 0.1)
    }

    @Test func aFilledGlowReadsTheSameProfile() {
        let glow = LevelEnvelope(stages: LevelEnvelope.glow) { age in age < 0.5 ? 0.8 : 0.2 }
        #expect(abs(glow.level(delay: 0.1, at: 0) - 0.8) < 0.001)
        #expect(abs(glow.level(delay: 1, at: 0) - 0.2) < 0.001)
    }

    /// Steps `envelope` to `samples` samples after its start, toward `target`.
    private func step(_ envelope: inout LevelEnvelope, samples: Int, target: Float, from start: Int = 0) {
        envelope.follow(target)
        for index in start..<(start + samples) { envelope.advance(to: (Double(index) + 1.5) / 120) }
    }

    @Test func peaksHoldTheLoudestSampleOfEachWindowNewestLast() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        // Two windows of 7 samples at full, one at silence, then 3 at full: the newest window holds 3 samples.
        step(&envelope, samples: 14, target: 1)
        step(&envelope, samples: 7, target: 0, from: 14)
        step(&envelope, samples: 3, target: 1, from: 21)
        let peaks = envelope.peaks(columns: 4, hop: 7)
        #expect(peaks.count == 4)
        #expect(peaks[3] > 0.03 && peaks[3] < peaks[2], "the newest window has only begun to rise")
        #expect(peaks[2] > 0.5, "the window before it still holds the fall from full")
        #expect(peaks[1] > peaks[2] && peaks[1] > 0.9)
        #expect(peaks[0] > 0.5, "the first window is still rising from silence")
    }

    @Test func aWindowHoldsTheSameSamplesAsItScrolls() {
        var envelope = LevelEnvelope()
        envelope.advance(to: 0)
        step(&envelope, samples: 70, target: 0.6)
        step(&envelope, samples: 7, target: 0.2, from: 70)
        let full = envelope.peaks(columns: 6, hop: 7)
        // One more sample starts a new window, and the full one is a column to the left with the same peak.
        step(&envelope, samples: 1, target: 0.2, from: 77)
        let next = envelope.peaks(columns: 6, hop: 7)
        #expect(next[4] == full[5] && next[3] == full[4])
        #expect(next[5] < full[5], "a window that has just begun holds only its first sample")
    }

    @Test func peaksAreSilentBeforeAnySample() {
        let envelope = LevelEnvelope()
        #expect(envelope.peaks(columns: 24, hop: 7) == [Float](repeating: 0, count: 24))
    }

    @Test func aFilledEnvelopeReadsItsProfileInPeaks() {
        let envelope = LevelEnvelope { age in age < 0.25 ? 0.9 : 0.1 }
        let peaks = envelope.peaks(columns: 24, hop: 7)
        #expect(abs(peaks[23] - 0.9) < 1e-6 && abs(peaks[0] - 0.1) < 1e-6)
    }
}

