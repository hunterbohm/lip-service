import Foundation
import Testing
@testable import DictationCore

@Suite("Voice levels") struct VoiceLevelsTests {
    private static let step = VoiceAnalyzer.hop

    /// Hears `hop` every 10 ms for `seconds`, from `start`, and returns the time reached.
    private static func hear(_ levels: inout VoiceLevels, _ hop: VoiceHop, from start: Double, seconds: Double) -> Double {
        var time = start
        for _ in 0..<Int((seconds / step).rounded()) {
            time += step
            levels.hear(hop, at: time)
        }
        return time
    }

    private static let room = VoiceHop(rms: 0.0005, low: 0.0004, mid: 0.0002, high: 0.0001)
    private static let talking = VoiceHop(rms: 0.1, low: 0.08, mid: 0.06, high: 0.01)

    @Test func theLevelFollowsAHopWithinAFewHundredthsOfASecond() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        #expect(levels.reading.level(delay: 0) < 0.05)
        // One new syllable: the level is already most of the way up 60 ms later, not a tenth of a second.
        time = Self.hear(&levels, Self.talking, from: time, seconds: 0.06)
        #expect(levels.reading.level(delay: 0) > 0.5)
    }

    @Test func aPauseDropsTheLevel() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        time = Self.hear(&levels, Self.talking, from: time, seconds: 1)
        #expect(levels.reading.level(delay: 0) > 0.8)
        time = Self.hear(&levels, Self.room, from: time, seconds: 0.5)
        #expect(levels.reading.level(delay: 0) < 0.1)
    }

    @Test func eachBandMovesWithItsOwnSound() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        // Talk for a while, then an "s": the hiss band jumps while the body of the voice stays down.
        time = Self.hear(&levels, Self.talking, from: time, seconds: 2)
        let hiss = VoiceHop(rms: 0.02, low: 0.0004, mid: 0.002, high: 0.02)
        time = Self.hear(&levels, hiss, from: time, seconds: 0.2)
        let reading = levels.reading
        #expect(reading.band(2, delay: 0) > 0.7)
        #expect(reading.band(0, delay: 0) < 0.15)
    }

    @Test func aQuietBandStaysDarkInAQuietRoom() {
        var levels = VoiceLevels()
        _ = Self.hear(&levels, Self.room, from: 0, seconds: 6)
        let reading = levels.reading
        for band in 0..<3 { #expect(reading.band(band, delay: 0) < 0.02) }
        #expect(reading.glow(delay: 0) < 0.02)
    }

    @Test func theEndsReadOlderAudioThanTheMiddle() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        time = Self.hear(&levels, Self.talking, from: time, seconds: 0.2)
        let reading = levels.reading
        #expect(reading.level(delay: 0) > reading.level(delay: LightWave.spread))
        #expect(reading.level(delay: LightWave.spread) > 0)
    }

    @Test func resetKeepsTheSpeakersScale() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        time = Self.hear(&levels, Self.talking, from: time, seconds: 1)
        levels.reset()
        #expect(levels.reading.level(delay: 0) == 0 && levels.clock == nil)
        // The first syllable of the next dictation is already full scale, as the speaker's peak is remembered.
        var next = Self.hear(&levels, Self.talking, from: 0, seconds: 0.3)
        #expect(levels.reading.level(delay: 0) > 0.8)
        next = Self.hear(&levels, Self.room, from: next, seconds: 0.5)
        #expect(levels.reading.level(delay: 0) < 0.1)
    }

    @Test func followingZeroSettlesEveryLevel() {
        var levels = VoiceLevels()
        var time = Self.hear(&levels, Self.room, from: 0, seconds: 3)
        time = Self.hear(&levels, Self.talking, from: time, seconds: 1)
        levels.follow(0)
        levels.advance(to: time + 1.5)
        let reading = levels.reading
        #expect(reading.level(delay: 0) < 0.01 && reading.glow(delay: 0) < 0.05)
        for band in 0..<3 { #expect(reading.band(band, delay: 0) < 0.01) }
    }

    @Test func aFrozenVoiceReadsItsProfile() {
        let levels = VoiceLevels(filling: { age in age < 0.5 ? 0.8 : 0.2 }, band: { band, _ in Float(band) / 4 })
        let reading = levels.reading
        #expect(abs(reading.level(delay: 0) - 0.8) < 1e-6 && abs(reading.level(delay: 1) - 0.2) < 1e-6)
        #expect(abs(reading.band(2, delay: 0.3) - 0.5) < 1e-6 && reading.band(0, delay: 0) == 0)
    }
}
