import Foundation

/// What 10 ms of audio sounded like: its overall loudness and how loud three bands of it were, as RMS. Low is the body
/// of a voice, mid its vowels and the start of its consonants, and high the hiss of "s" and "f". The bar draws a wave
/// from each band, so different sounds move different waves.
public struct VoiceHop: Sendable, Equatable {
    public var rms: Float
    public var low: Float
    public var mid: Float
    public var high: Float

    public static let silence = VoiceHop(rms: 0, low: 0, mid: 0, high: 0)

    public init(rms: Float, low: Float, mid: Float, high: Float) {
        (self.rms, self.low, self.mid, self.high) = (rms, low, mid, high)
    }

    /// The bands, lowest first, as `VoiceLevels` and the waves number them.
    public subscript(band: Int) -> Float {
        switch band {
        case 0: low
        case 1: mid
        default: high
        }
    }
}

/// Cuts a stream of mono samples into 10 ms hops and measures each, with no allocation and no locks, so it can run
/// on the audio thread. AVAudioEngine hands a microphone tap about 100 ms at a time whatever size it is asked for, so
/// one level per chunk moved the bar ten times a second; measured here, the same audio gives a hundred.
///
/// Three bands come from second-order Butterworth filters: low under 500 Hz (and over 80, so a desk thump or fan
/// does not count), mid from 500 Hz to 2 kHz, and high above 2 kHz. They overlap a little at the edges, which is fine
/// for a picture.
public struct VoiceAnalyzer: Sendable {
    /// The length of one hop, in seconds.
    public static let hop = 0.01
    public static let edges = (rumble: 80.0, low: 500.0, high: 2000.0)

    public let sampleRate: Double
    public let hopSamples: Int

    private struct Biquad: Sendable {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        init(lowpassAt frequency: Double, rate: Double) {
            let (cosine, alpha) = Biquad.angle(frequency, rate)
            (b0, b1, b2) = ((1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2)
            normalize(cosine, alpha)
        }

        init(highpassAt frequency: Double, rate: Double) {
            let (cosine, alpha) = Biquad.angle(frequency, rate)
            (b0, b1, b2) = ((1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2)
            normalize(cosine, alpha)
        }

        private static func angle(_ frequency: Double, _ rate: Double) -> (cosine: Double, alpha: Double) {
            // Keep the corner under Nyquist, so a 8 kHz Bluetooth microphone still gets sensible bands.
            let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
            return (cos(w), sin(w) / (2 * 0.70710678118654752))
        }

        private mutating func normalize(_ cosine: Double, _ alpha: Double) {
            let a0 = 1 + alpha
            (b0, b1, b2) = (b0 / a0, b1 / a0, b2 / a0)
            (a1, a2) = (-2 * cosine / a0, (1 - alpha) / a0)
        }

        @inline(__always) mutating func step(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var rumble: Biquad
    private var lowCut: Biquad
    private var midLow: Biquad
    private var midHigh: Biquad
    private var highCut: Biquad
    private var sums = (all: 0.0, low: 0.0, mid: 0.0, high: 0.0)
    private var filled = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hopSamples = max(1, Int((sampleRate * Self.hop).rounded()))
        rumble = Biquad(highpassAt: Self.edges.rumble, rate: sampleRate)
        lowCut = Biquad(lowpassAt: Self.edges.low, rate: sampleRate)
        midLow = Biquad(highpassAt: Self.edges.low, rate: sampleRate)
        midHigh = Biquad(lowpassAt: Self.edges.high, rate: sampleRate)
        highCut = Biquad(highpassAt: Self.edges.high, rate: sampleRate)
    }

    /// The hops per second.
    public var hopRate: Double { sampleRate / Double(hopSamples) }

    /// Measures `samples`, which continue the ones before. `emit` gets each hop that completes, with the count of
    /// samples of this call that had been read when it did, so the caller can time it: the hop ended that many samples
    /// into this call.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>, emit: (VoiceHop, Int) -> Void) {
        for index in samples.indices {
            let x = Double(samples[index])
            sums.all += x * x
            let low = lowCut.step(rumble.step(x))
            sums.low += low * low
            let mid = midHigh.step(midLow.step(x))
            sums.mid += mid * mid
            let high = highCut.step(x)
            sums.high += high * high
            filled += 1
            if filled == hopSamples {
                let scale = 1 / Double(hopSamples)
                emit(VoiceHop(rms: Float((sums.all * scale).squareRoot()), low: Float((sums.low * scale).squareRoot()),
                              mid: Float((sums.mid * scale).squareRoot()), high: Float((sums.high * scale).squareRoot())),
                     index - samples.startIndex + 1)
                sums = (0, 0, 0, 0)
                filled = 0
            }
        }
    }
}
