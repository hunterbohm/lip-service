import Foundation

/// The inside of the recording bar: three soft blue waves that follow the voice. Each sound starts in the middle and
/// ripples out to both ends, so a word shows as a swell that spreads and a pause as the middle going calm first. The
/// waves also run faster and glow brighter as the voice rises. While the words are finished the waves settle to a dim,
/// almost flat line that breathes. This holds the shapes and timings; the view only draws them.
public enum LightWave {
    /// The waves' width inside the capsule, in points.
    public static let width = 184.0
    /// How many full waves fit across.
    public static let cycles = 1.6
    /// Half the waves' height at silence and at the loudest voice, in points.
    public static let restingAmplitude = 1.5
    public static let loudestAmplitude = 16.0
    /// Half the waves' height while the words are finished.
    public static let finishingAmplitude = 1.2
    /// How long a sound takes to ripple from the middle out to the ends, in seconds.
    public static let spread = 0.45

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

    private static func clamped(_ level: Double) -> Double { min(max(level, 0), 1) }

    /// Half the waves' height for a voice level, 0 to 1. Eased up, so an everyday voice already swells them well.
    public static func amplitude(level: Double) -> Double {
        restingAmplitude + (loudestAmplitude - restingAmplitude) * pow(clamped(level), 0.6)
    }

    /// How long ago the voice that shapes the waves at `along` was heard: now in the middle, `spread` at the ends. It
    /// grows with the square of the distance from the middle, so the middle has no crease where the two sides meet.
    public static func delay(along: Double) -> Double { pow(abs(min(max(along, 0), 1) - 0.5) * 2, 2) * spread }

    /// How fast the waves travel for a voice level, as a multiple of their resting speed: up to two and a half times as
    /// fast at the loudest.
    public static func pace(level: Double) -> Double { 1 + 1.5 * clamped(level) }

    /// How bright the waves are for a voice level, 0 to 1: dimmer at silence, full at an everyday voice and above.
    public static func brightness(level: Double) -> Double { 0.55 + 0.45 * min(1, pow(clamped(level), 0.6) / 0.6) }

    /// How bright the waves are while the words are finished, at `time`: a slow breath, so the bar shows it is still
    /// working.
    public static func finishingBrightness(at time: Double) -> Double { 0.3 + 0.2 * (sin(time * 2 * .pi / 1.4) + 1) / 2 }

    /// How far in from each end the waves fade in, as a share of their width.
    public static let fade = 0.12

    /// How much of the amplitude a wave has at `along`, 0 at the left end to 1 at the right: none at the ends and all of
    /// it in the middle, so the waves taper into the capsule's rounded ends.
    public static func taper(_ along: Double) -> Double {
        let u = min(max(along, 0), 1)
        return pow(sin(.pi * u), 1.5)
    }

    /// A wave's height above the centre line at `along`, after the waves have travelled for `travel` seconds at their
    /// resting speed, for the amplitude there.
    public static func offset(_ strand: Strand, along: Double, travel: Double, amplitude: Double) -> Double {
        sin(along * .pi * 2 * cycles + travel * strand.speed + strand.phase) * amplitude * strand.share * taper(along)
    }
}
