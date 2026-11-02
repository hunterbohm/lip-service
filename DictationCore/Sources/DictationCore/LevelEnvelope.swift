import Foundation

/// A microphone level smoothed into a signal that never steps. It follows the latest level through a chain of one-pole
/// stages, each with a fast attack and a slow release, keeps the last two seconds at 120 samples a second, and reads
/// them back at any delay with linear interpolation, so a view can lag each dot behind the voice by its own amount.
public struct LevelEnvelope: Sendable {
    public static let rate = 120.0
    public static let span = 2.0
    public static let attack = 0.05
    public static let release = 0.1
    /// The glow's extra stage, which follows the voice envelope: slower both ways.
    public static let glowAttack = 0.12
    public static let glowRelease = 0.35
    private static let count = Int(rate * span)

    /// One one-pole smoother. Each stage follows the output of the one before it.
    public struct Stage: Sendable {
        public let attack: Double
        public let release: Double
        fileprivate let rise: Float
        fileprivate let fall: Float

        public init(attack: Double, release: Double) {
            self.attack = attack
            self.release = release
            rise = Float(1 - exp(-1 / LevelEnvelope.rate / attack))
            fall = Float(1 - exp(-1 / LevelEnvelope.rate / release))
        }
    }

    /// The voice: one stage.
    public static let voice = [Stage(attack: attack, release: release)]
    /// The voice smoothed once more.
    public static let glow = voice + [Stage(attack: glowAttack, release: glowRelease)]

    private let stages: [Stage]
    private var samples = [Float](repeating: 0, count: count)
    private var head = 0
    private var values: [Float]
    /// What the envelope is moving toward, 0 to 1.
    public private(set) var target: Float = 0
    /// The time of the newest sample, nil until the first `advance`.
    public private(set) var clock: Double?

    public init(stages: [Stage] = LevelEnvelope.voice) {
        precondition(!stages.isEmpty, "an envelope needs at least one stage")
        self.stages = stages
        values = [Float](repeating: 0, count: stages.count)
    }

    /// A frozen envelope whose past is `profile(age)`, the level `age` seconds before the clock, which is 0.
    public init(stages: [Stage] = LevelEnvelope.voice, filling profile: (Double) -> Float) {
        self.init(stages: stages)
        for age in 0..<Self.count { samples[(head - age + Self.count) % Self.count] = profile(Double(age) / Self.rate) }
        target = samples[head]
        values = [Float](repeating: target, count: stages.count)
        clock = 0
    }

    public mutating func reset() { self = LevelEnvelope(stages: stages) }

    public mutating func follow(_ level: Float) { target = min(max(level, 0), 1) }

    /// Moves the clock to `time`, one 1/120 s sample at a time. The first call only sets the clock.
    public mutating func advance(to time: Double) {
        guard var now = clock else { return clock = time }
        let step = 1 / Self.rate
        if time - now > Self.span { now = time - Self.span }
        while now + step <= time {
            now += step
            var input = target
            for index in stages.indices {
                values[index] += (input - values[index]) * (input > values[index] ? stages[index].rise : stages[index].fall)
                input = values[index]
            }
            head = (head + 1) % Self.count
            samples[head] = input
        }
        clock = now
    }

    /// The level `delay` seconds before `time`, between the two samples around it. 0 past the two seconds kept.
    public func level(delay: Double, at time: Double) -> Float {
        guard let clock else { return 0 }
        let age = max(0, delay - (time - clock))
        let position = age * Self.rate, index = Int(position)
        guard index < Self.count - 1 else { return 0 }
        let fraction = Float(position - Double(index))
        let newer = samples[(head - index + Self.count) % Self.count]
        let older = samples[(head - index - 1 + Self.count) % Self.count]
        return newer + (older - newer) * fraction
    }
}
