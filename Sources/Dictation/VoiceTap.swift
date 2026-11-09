import AVFoundation
import DictationCore
import Synchronization

/// Measures a live audio stream in 10 ms hops on the audio thread and hands them to the main thread, for the bar's
/// waves and the talk island. The audio thread takes no lock, allocates nothing and calls no Objective-C: it
/// filters, writes one slot of a fixed ring, and publishes the new count with a single atomic store. The main thread
/// reads the slots it has not seen.
///
/// The microphone's tap gets about 100 ms at a time whatever buffer size it asks for, so on its own it can move the
/// bar only ten times a second. A sink node on the same input is called for every hardware buffer, 512 frames, about
/// every 10 ms; `Microphone` uses one, and falls back to the tap when it cannot.
final class VoiceTap: @unchecked Sendable {
    struct Slot {
        var time = 0.0
        var hop = VoiceHop.silence
    }

    private static let capacity = 512
    private static let scratchFrames = 4096

    private let ring = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
    /// Touched only by whatever thread feeds the tap, one at a time.
    private let analyzer = UnsafeMutablePointer<VoiceAnalyzer?>.allocate(capacity: 1)
    private let written = Atomic<Int>(0)
    /// Whether a sink node feeds this tap, so the microphone's own tap leaves it alone.
    private let sinkFeeds = Atomic<Bool>(false)
    private let sinkLatency: Double
    private let chunkLatency: Double

    /// How long the bar holds a hop before showing it, so a hop that is a little late still shows on time: a bit more
    /// than the longest one is late. A sink node's hops are at most about 11 ms late and a tap's as late as its chunk.
    var latency: Double { sinkFeeds.load(ordering: .relaxed) ? sinkLatency : chunkLatency }

    init(sinkLatency: Double = 0.03, chunkLatency: Double) {
        self.sinkLatency = sinkLatency
        self.chunkLatency = chunkLatency
        ring.initialize(repeating: Slot(), count: Self.capacity)
        scratch.initialize(repeating: 0, count: Self.scratchFrames)
        analyzer.initialize(to: nil)
    }

    deinit {
        analyzer.deinitialize(count: 1)
        analyzer.deallocate()
        ring.deallocate()
        scratch.deallocate()
    }

    // MARK: Main thread

    /// How many hops have been written, for a reader to start after.
    var head: Int { written.load(ordering: .acquiring) }

    /// Calls `body` with the time and the hop of each hop after `cursor` that is at or before `limit`, oldest first, in
    /// the clock `now` reads, and moves `cursor` past them. A reader that falls more than the ring behind skips ahead.
    func read(from cursor: inout Int, until limit: Double, _ body: (Double, VoiceHop) -> Void) {
        let end = head
        if end - cursor > Self.capacity - 16 { cursor = end - (Self.capacity - 16) }
        while cursor < end {
            let slot = ring[cursor % Self.capacity]
            if slot.time > limit { return }
            body(slot.time, slot.hop)
            cursor += 1
        }
    }

    /// The seconds of the host clock the hops are stamped in.
    static var now: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    // MARK: Audio thread

    /// A sink node that feeds this tap with every buffer the input makes. Formed here, not in a main-actor method, because
    /// a closure formed there is inferred main-actor and traps on the audio thread.
    func makeSinkNode() -> AVAudioSinkNode {
        AVAudioSinkNode { [self] timestamp, frames, list in
            let start = timestamp.pointee.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) : Self.now
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frames)
            if buffers.count == 1, first.mNumberChannels == 1 {
                feed(UnsafeBufferPointer(start: data, count: count), rate: sinkRate, start: start)
            } else if buffers.count >= 2, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                mixed(count, rate: sinkRate, start: start) { index in (data[index] + second[index]) / 2 }
            } else {
                // One interleaved buffer: the first channel.
                let stride = Int(first.mNumberChannels)
                mixed(count, rate: sinkRate, start: start) { index in data[index * stride] }
            }
            return noErr
        }
    }

    /// The rate the sink node was connected at.
    private let sinkHertz = Atomic<Int>(48_000)
    private var sinkRate: Double { Double(sinkHertz.load(ordering: .relaxed)) }

    /// Says that a sink node connected at `hertz` now feeds this tap, or, with nil, that none does, so the microphone's
    /// own tap feeds it. Call it before the engine starts.
    func useSink(at hertz: Double?) {
        sinkHertz.store(Int((hertz ?? 48_000).rounded()), ordering: .relaxed)
        sinkFeeds.store(hertz != nil, ordering: .relaxed)
    }

    /// The tap on the microphone's input, which feeds this only when no sink node does. `buffer` is whatever chunk the
    /// engine delivered.
    func tap(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard !sinkFeeds.load(ordering: .relaxed), let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Self.now - Double(buffer.frameLength) / buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        if buffer.format.channelCount == 1 {
            feed(UnsafeBufferPointer(start: channels[0], count: count), rate: buffer.format.sampleRate, start: start)
        } else {
            let (left, right) = (channels[0], channels[1])
            mixed(count, rate: buffer.format.sampleRate, start: start) { index in (left[index] + right[index]) / 2 }
        }
    }

    /// The tap block for a player's output. Formed here, outside the main actor, for the same reason as the sink node's.
    func outputTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, when in tapOutput(buffer, at: when) }
    }

    /// Feeds a player's output, whose tap has no sink alternative.
    func tapOutput(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Self.now - Double(buffer.frameLength) / buffer.format.sampleRate
        feed(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)), rate: buffer.format.sampleRate, start: start)
    }

    /// Copies `count` frames through `sample` into the scratch buffer, in pieces, and measures them.
    private func mixed(_ count: Int, rate: Double, start: Double, _ sample: (Int) -> Float) {
        var done = 0
        while done < count {
            let piece = min(count - done, Self.scratchFrames)
            for index in 0..<piece { scratch[index] = sample(done + index) }
            feed(UnsafeBufferPointer(start: scratch, count: piece), rate: rate, start: start + Double(done) / rate)
            done += piece
        }
    }

    private func feed(_ samples: UnsafeBufferPointer<Float>, rate: Double, start: Double) {
        if analyzer.pointee?.sampleRate != rate { analyzer.pointee = VoiceAnalyzer(sampleRate: rate) }
        var count = written.load(ordering: .relaxed)
        analyzer.pointee?.process(samples) { hop, end in
            ring[count % Self.capacity] = Slot(time: start + Double(end) / rate, hop: hop)
            count += 1
            written.store(count, ordering: .releasing)
        }
    }
}
