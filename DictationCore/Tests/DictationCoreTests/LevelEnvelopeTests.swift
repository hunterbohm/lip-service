import Testing
@testable import DictationCore

private func run(_ envelope: inout LevelEnvelope, from start: Double, seconds: Double, target: Float) -> Double {
    envelope.follow(target)
    let end = start + seconds
    var time = start
    while time < end { time += 1.0 / 60; envelope.advance(to: time) }
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
        #expect(envelope.level(delay: 0, at: time) > peak * 0.6)
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
}
