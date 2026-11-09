import DictationCore
import Foundation

/// The voice as the bar draws it: the hops the microphone (or the agent's voice) measured, scaled and smoothed, with the
/// last two seconds kept. Views read it with the time they are drawing for, and it takes the hops that are due by then
/// from the audio thread's ring and moves its own clock up to that time, so every wave is continuous and follows the
/// voice within a few hundredths of a second. It runs no timer: the views' own frames pull the hops in.
/// Not observable: the views run on a timeline and look at it each frame.
@MainActor final class VoiceMeter {
    /// Kept across dictations, so the next one starts already scaled to the speaker and the room.
    private var levels = VoiceLevels()
    private let feed: @MainActor () -> VoiceTap?
    private var source: VoiceTap?
    private var cursor = 0
    private var listening = false
    /// Set by --render-bar: the time every view draws for, and the levels stay as `freeze` left them.
    private(set) var frozenAt: Double?

    /// `feed` names the tap to read while listening: the microphone, or the agent's voice while it talks.
    init(feed: @escaping @MainActor () -> VoiceTap? = { nil }) { self.feed = feed }

    /// Starts or stops taking hops. Stopping sends every level toward silence, which the waves settle into.
    func listen(_ on: Bool) {
        guard frozenAt == nil, on != listening else { return }
        listening = on
        if on {
            levels.reset()
            source = nil
        } else {
            levels.follow(0)
        }
    }

    func freeze(at time: Double, profile: (Double) -> Float, band: ((Int, Double) -> Float)? = nil) {
        frozenAt = time
        levels = VoiceLevels(filling: profile, band: band)
    }

    func reading(at time: Double) -> VoiceReading {
        if frozenAt == nil {
            let latency = pull(at: time)
            levels.advance(to: time - latency)
        }
        return levels.reading
    }

    /// Takes in every hop due by `time`, and returns how far behind `time` the levels run.
    private func pull(at time: Double) -> Double {
        guard listening, let tap = feed() else { return source?.latency ?? 0 }
        if tap !== source {
            // A different voice, or the first: start from what is coming in now, not what an idle tap held.
            source = tap
            cursor = tap.head
        }
        let latency = tap.latency
        let offset = Date.timeIntervalSinceReferenceDate - VoiceTap.now
        let horizon = time - latency
        tap.read(from: &cursor, until: horizon - offset) { stamp, hop in levels.hear(hop, at: stamp + offset) }
        return latency
    }
}
