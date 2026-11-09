import Foundation

/// The microphone level as the bar shows it, 0 to 1, scaled to the speaker and the room instead of a fixed window, so
/// a quiet voice and a loud one both move the dots. It tracks the room floor, the quietest level of the last few
/// seconds but never under `noiseFloor`, and the speaker's recent peak, which rises at once and eases back over about
/// 3 s toward the current level, though never below `minimumSpan` over the floor. The level runs in decibels
/// from the higher of just above the floor and `range` below the peak, up to the peak. Measured on real speech, a
/// window from the floor up put every syllable near full, so the print stood still while someone talked. The peak
/// never sits closer than `minimumSpan` to the floor, so a quiet room is never stretched to full.
public struct AutoLevel: Sendable {
    /// Levels per second, one per `fraction(rms:)` call.
    public let rate: Double
    public static let minimumSpan = 16.0
    /// The room's own flicker stays dark: the level starts counting this far above the floor.
    public static let gate = 5.0
    /// The loudest syllables reach full, and anything this far below the peak is dark.
    public static let range = 24.0
    public static let peakRelease = 3.0
    /// The floor is the quietest level over this many seconds, kept as the quietest of each quarter second.
    public static let floorWindow = 4.0
    public static let floorBucket = 0.25
    private static let silence = -100.0
    /// A room quieter than this, such as digital silence, counts as this loud, so the window never opens wider.
    public static let noiseFloor = -60.0

    private var peak: Double?
    private var buckets: [Double]
    private var bucket = 0
    private var bucketFill = 0
    private let perBucket: Int
    private let fall: Double
    private let noiseFloor: Double

    /// `noiseFloor` is where the room is taken to sit when it is quieter, in decibels.
    public init(rate: Double, noiseFloor: Double = AutoLevel.noiseFloor) {
        self.rate = rate
        self.noiseFloor = noiseFloor
        perBucket = max(1, Int((rate * Self.floorBucket).rounded()))
        buckets = []
        fall = 1 - exp(-1 / rate / Self.peakRelease)
    }

    /// Takes the RMS of the newest audio and returns its level.
    public mutating func fraction(rms: Float) -> Float {
        let level = max(20 * log10(Double(max(rms, 1e-5))), Self.silence)
        record(level)
        let floor = max(buckets.min() ?? level, noiseFloor)
        let lowest = floor + Self.minimumSpan
        if let current = peak, level <= current { peak = current - (current - max(level, lowest)) * fall } else { peak = level }
        let top = max(peak ?? level, lowest)
        let bottom = max(floor + Self.gate, top - Self.range)
        func amplitude(_ decibels: Double) -> Double { pow(10, decibels / 20) }
        return Float(min(max((amplitude(level) - amplitude(bottom)) / (amplitude(top) - amplitude(bottom)), 0), 1))
    }

    private mutating func record(_ level: Double) {
        let count = Int((Self.floorWindow / Self.floorBucket).rounded())
        if buckets.isEmpty || bucketFill == perBucket {
            if buckets.count < count {
                buckets.append(level)
                bucket = buckets.count - 1
            } else {
                bucket = (bucket + 1) % count
                buckets[bucket] = level
            }
            bucketFill = 1
        } else {
            buckets[bucket] = min(buckets[bucket], level)
            bucketFill += 1
        }
    }
}
