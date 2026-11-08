import Foundation

/// The inside of the recording bar: three soft blue waves that swell with the voice, and a spark that runs along them
/// each time a word is recognised, so the bar shows both that it hears you and that it is writing down what you say.
/// While the words are finished the waves settle flat and a spark keeps crossing. This holds the shapes and timings;
/// the view only draws them.
public enum LightWave {
    /// The waves' width inside the capsule, in points.
    public static let width = 184.0
    /// How many full waves fit across.
    public static let cycles = 1.6
    /// Half the waves' height at silence and at the loudest voice, in points.
    public static let restingAmplitude = 2.0
    public static let loudestAmplitude = 15.0
    /// Half the waves' height while the words are finished.
    public static let finishingAmplitude = 1.2
    /// How long a spark takes to cross, in seconds.
    public static let sparkLife = 0.62
    /// The gap between sparks when several words land in one update, and the most sparks one update starts.
    public static let sparkStagger = 0.09
    public static let sparksPerUpdate = 3
    /// How often a spark starts while the words are finished, in seconds.
    public static let finishingSparkEvery = 0.75

    public typealias RGB = (red: Double, green: Double, blue: Double)

    /// One wave: its colour, its height as a share of the amplitude, its phase, and how fast it travels.
    public struct Strand: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let share: Double
        public let phase: Double
        public let speed: Double
        public var color: RGB { (red, green, blue) }
    }

    /// Sky, blue, and near white, so the waves match the rim and the beam.
    public static let strands: [Strand] = [
        Strand(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255, share: 1, phase: 0, speed: 5),
        Strand(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, share: 0.8, phase: 2.1, speed: 4),
        Strand(red: 0xBA / 255, green: 0xF0 / 255, blue: 0xFF / 255, share: 0.55, phase: 4.2, speed: 4.5),
    ]

    /// Half the waves' height for a voice level, 0 to 1. Eased up, so an everyday voice already swells them well.
    public static func amplitude(level: Double) -> Double {
        restingAmplitude + (loudestAmplitude - restingAmplitude) * pow(min(max(level, 0), 1), 0.6)
    }

    /// How far in from each end the waves fade in, as a share of their width.
    public static let fade = 0.12

    /// How much of the amplitude a wave has at `along`, 0 at the left end to 1 at the right: none at the ends and all of
    /// it in the middle, so the waves taper into the capsule's rounded ends.
    public static func taper(_ along: Double) -> Double {
        let u = min(max(along, 0), 1)
        return pow(sin(.pi * u), 1.5)
    }

    /// A wave's height above the centre line at `along`, at `time`, for an amplitude.
    public static func offset(_ strand: Strand, along: Double, time: Double, amplitude: Double) -> Double {
        sin(along * .pi * 2 * cycles + time * strand.speed + strand.phase) * amplitude * strand.share * taper(along)
    }

    /// Where a spark started at `start` is at `time`, 0 to 1 along the waves, and how bright it is; nil once it has
    /// crossed or before it starts. It dims as it goes, and fades in and out where the waves do.
    public static func spark(startedAt start: Double, at time: Double) -> (along: Double, light: Double)? {
        let age = time - start
        guard age >= 0, age < sparkLife else { return nil }
        let along = age / sparkLife
        return (along, (1 - 0.6 * along) * min(1, along / fade, (1 - along) / fade))
    }

    /// The start times of the sparks for a word update at `time` that adds `added` words.
    public static func sparks(forAdded added: Int, at time: Double) -> [Double] {
        (0..<min(max(added, 0), sparksPerUpdate)).map { time + Double($0) * sparkStagger }
    }

    /// The spark that crosses while the words are finished, at `time`.
    public static func finishingSpark(at time: Double) -> Double {
        (time / finishingSparkEvery).rounded(.down) * finishingSparkEvery
    }
}
