import Foundation

/// How FluidAudio runs the boosting model over audio longer than 15 s: 15 s windows every 13 s, each window run on
/// its own, and the overlapping frames of neighbours averaged in probability space. Mirrors
/// `computeLogProbsChunked` in FluidAudio v0.17.7 (`CtcKeywordSpotter+Inference.swift`). A window's
/// log-probabilities depend only on its audio, so every window that ends before release can be computed while
/// the key is still held.
public enum CtcWindows {
    public static let size = 240_000
    public static let overlap = 32_000
    public static let stride = size - overlap

    /// Window `index` of any capture long enough to complete it. It is final once the capture reaches its end.
    public static func window(_ index: Int) -> Range<Int> {
        index * stride..<(index * stride + size)
    }

    /// The windows FluidAudio runs for `count` samples. Audio up to 15 s is one window.
    public static func ranges(count: Int) -> [Range<Int>] {
        guard count > size else { return count > 0 ? [0..<count] : [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while true {
            let end = min(start + size, count)
            ranges.append(start..<end)
            if end >= count { return ranges }
            start += stride
        }
    }

    /// Joins per-window frames as FluidAudio does. `frameDuration` is the first window's.
    public static func merge(_ windows: [[[Float]]], frameDuration: Double, sampleRate: Double) -> [[Float]] {
        guard windows.count > 1 else { return windows.first ?? [] }
        guard frameDuration > 0 else { return [] }
        let overlapFrames = Int(Double(overlap) / sampleRate / frameDuration)
        var merged: [[Float]] = []
        for (index, frames) in windows.enumerated() where !frames.isEmpty {
            if index == 0 {
                merged = frames
                continue
            }
            let shared = min(overlapFrames, merged.count, frames.count)
            for i in 0..<shared {
                merged[merged.count - shared + i] = meanInProbability(merged[merged.count - shared + i], frames[i])
            }
            merged += frames[shared...]
        }
        return merged
    }

    /// `log((exp(a) + exp(b)) / 2)` per token, in FluidAudio's exact float operations, so the result matches it
    /// bit for bit.
    static func meanInProbability(_ existing: [Float], _ incoming: [Float]) -> [Float] {
        let count = min(existing.count, incoming.count)
        if count == 0 { return existing }
        let log2: Float = 0.69314718
        return (0..<count).map { j in
            let a = existing[j], b = incoming[j]
            let m = max(a, b)
            return m == -Float.infinity ? -Float.infinity : m + logf(expf(a - m) + expf(b - m)) - log2
        }
    }
}
