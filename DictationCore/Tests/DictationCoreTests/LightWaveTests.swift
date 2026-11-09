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

    @Test func soundRipplesOutFromTheMiddle() {
        #expect(LightWave.delay(along: 0.5) == 0)
        #expect(abs(LightWave.delay(along: 0) - LightWave.spread) < 1e-12)
        #expect(abs(LightWave.delay(along: 1) - LightWave.spread) < 1e-12)
        #expect(abs(LightWave.delay(along: 0.25) - LightWave.delay(along: 0.75)) < 1e-12)
        #expect(LightWave.delay(along: 0.3) > LightWave.delay(along: 0.4))
        // Flat at the middle, so the two sides meet without a point.
        #expect(LightWave.delay(along: 0.51) < 0.01 * LightWave.spread)
        // The envelope keeps two seconds, so every delay can be read back.
        #expect(LightWave.spread < LevelEnvelope.span)
        // The ends show the voice now, not a beat ago: under a fifth of a second behind the middle.
        #expect(LightWave.spread <= 0.2)
    }

    @Test func aLouderVoiceRunsFasterAndBrighter() {
        #expect(LightWave.pace(level: 0) == 1)
        #expect(LightWave.pace(level: 1) > LightWave.pace(level: 0.3))
        #expect(LightWave.pace(level: 7) == LightWave.pace(level: 1))
        #expect(LightWave.brightness(level: 0) < LightWave.brightness(level: 0.2))
        #expect(abs(LightWave.brightness(level: 0.5) - 1) < 1e-12 && abs(LightWave.brightness(level: 1) - 1) < 1e-12)
    }

    @Test func finishingBreathesDimmerThanAVoice() {
        let breath = stride(from: 0.0, to: 2, by: 0.05).map(LightWave.finishingBrightness(at:))
        #expect(breath.max()! < LightWave.brightness(level: 0))
        #expect(breath.max()! - breath.min()! > 0.15)
    }

    @Test func wavesTaperToNothingAtBothEnds() {
        #expect(LightWave.taper(0) == 0 && abs(LightWave.taper(1)) < 1e-9)
        #expect(abs(LightWave.taper(0.5) - 1) < 1e-12)
        for strand in LightWave.strands {
            for travel in [0.0, 0.4, 3.7] {
                #expect(abs(LightWave.offset(strand, along: 0, travel: travel, amplitude: 15)) < 1e-9)
                #expect(abs(LightWave.offset(strand, along: 1, travel: travel, amplitude: 15)) < 1e-9)
                #expect(abs(LightWave.offset(strand, along: 0.5, travel: travel, amplitude: 15)) <= 15 * strand.share + 1e-9)
            }
        }
    }

    @Test func wavesMove() {
        let strand = LightWave.strands[0]
        #expect(LightWave.offset(strand, along: 0.3, travel: 0, amplitude: 10) != LightWave.offset(strand, along: 0.3, travel: 0.1, amplitude: 10))
    }

    @Test func strandsAreBlue() {
        #expect(LightWave.strands.count == 3)
        for strand in LightWave.strands { #expect(strand.blue >= strand.red && strand.blue >= strand.green) }
    }

    @Test func eachWaveFollowsItsOwnBandMostly() {
        #expect(LightWave.strands.map(\.band) == [0, 1, 2])
        #expect(LightWave.level(overall: 0, band: 1) == LightWave.bandShare)
        #expect(LightWave.level(overall: 1, band: 0) == 1 - LightWave.bandShare)
        #expect(abs(LightWave.level(overall: 0.6, band: 0.6) - 0.6) < 1e-12)
        // Every wave still moves when only the whole voice does.
        #expect(LightWave.level(overall: 1, band: 0) > 0.2)
        #expect(LightWave.level(overall: 7, band: -3) == 1 - LightWave.bandShare)
    }

    @Test func columnsMatchTheDirectFormulas() {
        let columns = LightWave.columns(steps: 92)
        #expect(columns.count == 93 && columns.first?.along == 0 && columns.last?.along == 1)
        for strand in LightWave.strands {
            for column in columns {
                #expect(abs(LightWave.offset(strand, column: column, travel: 1.3, amplitude: 9)
                    - LightWave.offset(strand, along: column.along, travel: 1.3, amplitude: 9)) < 1e-9)
                #expect(column.delay == LightWave.delay(along: column.along) && column.taper == LightWave.taper(column.along))
            }
        }
    }
}
