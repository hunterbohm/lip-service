import Foundation
import Testing
@testable import DictationCore

@Suite("Voice analyzer") struct VoiceAnalyzerTests {
    private static func sine(_ frequency: Double, amplitude: Double = 0.5, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// Every hop of `samples`, fed in pieces of `chunk`, with where in its piece each one ended.
    private static func hops(_ samples: [Float], rate: Double, chunk: Int = 512) -> [(hop: VoiceHop, end: Int)] {
        var analyzer = VoiceAnalyzer(sampleRate: rate)
        var out: [(VoiceHop, Int)] = []
        var start = 0
        while start < samples.count {
            let piece = Array(samples[start..<min(start + chunk, samples.count)])
            piece.withUnsafeBufferPointer { analyzer.process($0) { out.append(($0, $1)) } }
            start += chunk
        }
        return out
    }

    @Test(arguments: [48_000.0, 44_100.0, 16_000.0, 24_000.0])
    func makesAHundredHopsASecond(rate: Double) {
        let hops = Self.hops(Self.sine(300, rate: rate, seconds: 1), rate: rate)
        #expect(abs(Double(hops.count) - 100) <= 1)
        #expect(abs(VoiceAnalyzer(sampleRate: rate).hopRate - 100) < 1)
    }

    @Test func overallIsTheRMS() {
        let hops = Self.hops(Self.sine(300, amplitude: 0.5, rate: 48_000, seconds: 0.5), rate: 48_000)
        // A sine of amplitude A has RMS A / sqrt 2.
        for hop in hops.dropFirst(3) { #expect(abs(Double(hop.hop.rms) - 0.5 / 2.0.squareRoot()) < 0.01) }
    }

    @Test(arguments: [(200.0, 0), (1000.0, 1), (5000.0, 2)])
    func aToneLightsItsOwnBand(frequency: Double, band: Int) {
        for rate in [48_000.0, 16_000.0] {
            let hops = Self.hops(Self.sine(frequency, rate: rate, seconds: 0.6), rate: rate)
            let settled = hops.dropFirst(10).map(\.hop)
            #expect(!settled.isEmpty)
            for hop in settled {
                let own = hop[band]
                #expect(own > 0.7 * hop.rms, "a \(frequency) Hz tone should sit in band \(band) at \(rate) Hz, got \(hop)")
                for other in 0..<3 where other != band { #expect(hop[other] < 0.45 * own) }
            }
        }
    }

    @Test func rumbleBelowTheVoiceDoesNotMoveTheLowBand() {
        let hops = Self.hops(Self.sine(30, rate: 48_000, seconds: 0.6), rate: 48_000).dropFirst(10)
        for hop in hops.map(\.hop) { #expect(hop.low < 0.4 * hop.rms) }
    }

    @Test func silenceIsSilent() {
        let hops = Self.hops([Float](repeating: 0, count: 48_000), rate: 48_000)
        #expect(hops.allSatisfy { $0.hop == .silence })
    }

    @Test func aBurstShowsUpWithinOneHop() {
        // 100 ms of silence, then 100 ms of tone, in 100 ms chunks the way the microphone tap delivers them.
        let rate = 48_000.0
        let samples = [Float](repeating: 0, count: 4800) + Self.sine(400, rate: rate, seconds: 0.1)
        let hops = Self.hops(samples, rate: rate, chunk: 4800).map(\.hop)
        let first = hops.firstIndex { $0.rms > 0.1 }
        #expect(first != nil && abs(first! - 10) <= 1)
        #expect(hops[..<10].allSatisfy { $0.rms < 0.01 })
    }

    @Test func chunkSizeDoesNotChangeTheHops() {
        let samples = Self.sine(700, rate: 48_000, seconds: 0.5) + Self.sine(3000, rate: 48_000, seconds: 0.5)
        let whole = Self.hops(samples, rate: 48_000, chunk: samples.count).map(\.hop)
        for chunk in [1, 100, 512, 1024, 4800] {
            let pieces = Self.hops(samples, rate: 48_000, chunk: chunk).map(\.hop)
            #expect(pieces.count == whole.count)
            for (a, b) in zip(pieces, whole) {
                #expect(abs(a.rms - b.rms) < 1e-6 && abs(a.low - b.low) < 1e-6 && abs(a.mid - b.mid) < 1e-6 && abs(a.high - b.high) < 1e-6)
            }
        }
    }

    @Test func reportsWhereInTheChunkEachHopEnded() {
        // 512-sample chunks at 48 kHz: hops end every 480 samples, so the n-th ends at 480 n.
        let hops = Self.hops(Self.sine(300, rate: 48_000, seconds: 0.2), rate: 48_000, chunk: 512)
        for (index, item) in hops.enumerated() {
            let sinceStart = 480 * (index + 1)
            #expect(item.end >= 1 && item.end <= 512)
            #expect((sinceStart - item.end) % 512 == 0)
        }
    }

    @Test func aLowSampleRateKeepsItsCornersUnderNyquist() {
        // An 8 kHz Bluetooth microphone has a 4 kHz Nyquist, and the 2 kHz corner stays under it.
        let hops = Self.hops(Self.sine(3000, rate: 8000, seconds: 0.6), rate: 8000).dropFirst(10)
        for hop in hops.map(\.hop) {
            #expect(hop.rms.isFinite && hop.high.isFinite && hop.high > 0.5 * hop.rms)
        }
    }
}
