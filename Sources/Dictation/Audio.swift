import AVFoundation
import DictationCore

struct DictationError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Any PCM format to 16 kHz mono Float. The microphone and the bench share it, so the bench feeds the engine
/// audio prepared by the app's own code.
struct SampleConverter {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recording.sampleRate, channels: 1,
                                      interleaved: false)!

    let inputFormat: AVAudioFormat
    /// Nil when the input is already in `format`.
    private let converter: AVAudioConverter?
    private let ratio: Double

    init(from input: AVAudioFormat) throws {
        guard input.sampleRate > 0, input.channelCount > 0 else { throw DictationError("No audio input is available.") }
        inputFormat = input
        if input == Self.format {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: Self.format) else {
                throw DictationError("Cannot convert audio from \(input).")
            }
            converter.downmix = true
            self.converter = converter
        }
        ratio = Recording.sampleRate / input.sampleRate
    }

    /// Keeps the resampler's state between calls, so a stream of buffers converts without seams. Pass
    /// `endOfStream` with the last buffer to flush what the resampler still holds.
    func convert(_ buffer: AVAudioPCMBuffer, endOfStream: Bool = false) throws -> [Float] {
        guard let converter else { return Self.samples(of: buffer) }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else {
            throw DictationError("Cannot allocate a conversion buffer.")
        }
        // AVAudioConverter calls the input block synchronously inside convert, on this thread.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? DictationError("Audio conversion failed.") }
        return Self.samples(of: output)
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

extension Recording {
    static func load(wav url: URL, releasedAt: Instant = .now) throws -> Recording {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DictationError("Cannot allocate a buffer for \(url.lastPathComponent).")
        }
        try file.read(into: buffer)
        let samples = try SampleConverter(from: file.processingFormat).convert(buffer, endOfStream: true)
        return Recording(samples: samples, releasedAt: releasedAt)
    }
}
