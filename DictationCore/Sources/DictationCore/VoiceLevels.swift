import Foundation

/// The voice as the bar draws it: each hop scaled to the speaker and the room, one overall and one per band, smoothed
/// into signals that never step, with the last two seconds kept. A view reads any of them back at any delay.
public struct VoiceLevels: Sendable {
    public static let bandCount = 3

    /// Kept across dictations, so the next one starts already scaled to the speaker and the room.
    private var loudness: AutoLevel
    private var bandLoudness: [AutoLevel]
    private var voice = LevelEnvelope()
    /// The same voice smoothed once more, which lights the halo.
    private var glow = LevelEnvelope(stages: LevelEnvelope.glow)
    private var bands = [LevelEnvelope](repeating: LevelEnvelope(), count: bandCount)

    /// A band is far quieter than the whole voice, so its own floor sits lower than `AutoLevel.noiseFloor`.
    public static let bandNoiseFloor = -80.0

    public init(hopRate: Double = 1 / VoiceAnalyzer.hop) {
        loudness = AutoLevel(rate: hopRate)
        bandLoudness = (0..<Self.bandCount).map { _ in AutoLevel(rate: hopRate, noiseFloor: Self.bandNoiseFloor) }
    }

    /// A frozen voice whose past is `profile(age)`, the level `age` seconds before the clock, for --render-bar. `band`
    /// does the same for one band, and defaults to `profile`.
    public init(filling profile: (Double) -> Float, band: ((Int, Double) -> Float)? = nil) {
        self.init()
        voice = LevelEnvelope(filling: profile)
        glow = LevelEnvelope(stages: LevelEnvelope.glow, filling: profile)
        bands = (0..<Self.bandCount).map { index in LevelEnvelope { age in band?(index, age) ?? profile(age) } }
    }

    /// Forgets the voice but keeps how loud the speaker and the room are.
    public mutating func reset() {
        voice.reset()
        glow.reset()
        for index in bands.indices { bands[index].reset() }
    }

    /// Takes the hop that was heard at `time` and scales it.
    public mutating func hear(_ hop: VoiceHop, at time: Double) {
        advance(to: time)
        voice.follow(loudness.fraction(rms: hop.rms))
        glow.follow(voice.target)
        for index in bands.indices { bands[index].follow(bandLoudness[index].fraction(rms: hop[index])) }
    }

    /// Sends every signal toward `fraction`, 0 to 1.
    public mutating func follow(_ fraction: Float) {
        voice.follow(fraction)
        glow.follow(fraction)
        for index in bands.indices { bands[index].follow(fraction) }
    }

    /// Moves the clock to `time`.
    public mutating func advance(to time: Double) {
        voice.advance(to: time)
        glow.advance(to: time)
        for index in bands.indices { bands[index].advance(to: time) }
    }

    /// The time of the newest sample, nil until the clock first moves.
    public var clock: Double? { voice.clock }

    /// A copy to read from, as of the clock.
    public var reading: VoiceReading { VoiceReading(voice: voice, glow: glow, bands: bands, time: voice.clock ?? 0) }
}

/// The voice at one moment, as a view reads it.
public struct VoiceReading: Sendable {
    fileprivate let voice: LevelEnvelope
    fileprivate let glow: LevelEnvelope
    fileprivate let bands: [LevelEnvelope]
    fileprivate let time: Double

    /// The overall level, 0 to 1, `delay` seconds ago.
    public func level(delay: Double) -> Double { Double(voice.level(delay: delay, at: time)) }
    /// The level the halo glows with, `delay` seconds ago.
    public func glow(delay: Double) -> Double { Double(glow.level(delay: delay, at: time)) }
    /// One band's level, 0 to 1, `delay` seconds ago.
    public func band(_ index: Int, delay: Double) -> Double { Double(bands[index].level(delay: delay, at: time)) }
}
