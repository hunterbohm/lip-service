import Foundation
import Testing
@testable import DictationCore

@Suite("Auto level") struct AutoLevelTests {
    private static let rate = 60.0

    /// A room at `room` dB, then speech in syllables four times a second whose loudest moments reach `peak` dB, with a
    /// short pause between words.
    private static func speech(room: Double, peak: Double, seconds: Double) -> [Float] {
        let roomAmplitude = pow(10, room / 20), peakAmplitude = pow(10, peak / 20)
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let inPause = time.truncatingRemainder(dividingBy: 1.5) > 1.2
            let syllable = inPause ? 0 : pow(sin(Double.pi * 4 * time), 2)
            return Float(roomAmplitude + (peakAmplitude - roomAmplitude) * syllable)
        }
    }

    private static func room(_ decibels: Double, seconds: Double) -> [Float] {
        var seed: UInt64 = 7
        return (0..<Int(seconds * rate)).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = (Double(seed >> 11) / Double(1 << 53) - 0.5) * 3
            return Float(pow(10, (decibels + jitter) / 20))
        }
    }

    private static func ninetiethPercentile(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.9)]
    }

    private static func levels(_ rms: [Float]) -> [Float] {
        var level = AutoLevel(rate: rate)
        return rms.map { level.fraction(rms: $0) }
    }

    @Test(arguments: [(-36.0, -58.0), (-14.0, -50.0)])
    func quietAndLoudVoicesBothFillThePrint(peak: Double, room: Double) {
        let lead = Self.room(room, seconds: 1)
        let fractions = Self.levels(lead + Self.speech(room: room, peak: peak, seconds: 8))
        let speaking = Array(fractions.dropFirst(lead.count + Int(Self.rate)))
        #expect(Self.ninetiethPercentile(speaking) > 0.8)
    }

    @Test func syllablesSpreadOverTheRangeInsteadOfSittingAtFull() {
        let lead = Self.room(-50, seconds: 1)
        let fractions = Self.levels(lead + Self.speech(room: -50, peak: -20, seconds: 8))
        let speaking = Array(fractions.dropFirst(lead.count + Int(Self.rate))).sorted()
        #expect(speaking[speaking.count / 2] < 0.7)
        #expect(speaking[speaking.count / 4] < 0.2)
    }

    @Test func soundFarUnderThePeakIsDarkEvenInDigitalSilence() {
        let talk = Self.speech(room: -120, peak: -20, seconds: 3)
        var level = AutoLevel(rate: Self.rate)
        for rms in talk { _ = level.fraction(rms: rms) }
        #expect(level.fraction(rms: Float(pow(10, -50.0 / 20))) == 0)
    }

    @Test func aSteadyRoomStaysDark() {
        let fractions = Self.levels(Self.room(-48, seconds: 10))
        #expect(fractions.allSatisfy { $0 < 0.05 })
    }

    @Test func theDotsFallBackWhenTheSpeakerStops() {
        let talk = Self.speech(room: -50, peak: -20, seconds: 4), after = Self.room(-50, seconds: 2)
        let fractions = Self.levels(talk + after)
        #expect(fractions.suffix(Int(Self.rate)).allSatisfy { $0 < 0.05 })
    }
}
