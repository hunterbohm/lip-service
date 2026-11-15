import Foundation

/// The inside of the recording bar: one line of braille cells. While you talk it is a scrolling scope of the voice,
/// one column for each 58 ms, newest at the right, each as tall as the voice was in it, and flat when it is quiet.
/// While the words are finished the line is dim with one cell sweeping along it. This holds the cells and when each is
/// lit; the view only draws them.
public enum AsciiScope {
    public static let columns = 24
    /// Samples of the voice's envelope in one column, 7 at 120 a second.
    public static let hop = 7
    /// A cell from flat to full: a quiet floor of three, so room noise never shows as a bump, then six steps up.
    private static let ramp = Array("⣀⣀⣀⣄⣤⣦⣶⣷⣿")
    public static let baseline: Character = "⣀"
    public static let sweeping: Character = "⣤"
    /// How long the sweeping cell stays on one column, in seconds.
    public static let sweepStep = 0.055
    /// The scale's bend. Measured on a clip of continuous speech, a straight scale put half the columns in the top two
    /// cells, so the bar looked full while someone talked. Raised to this power, the top is kept for the loudest
    /// syllables and the rest of the voice spreads over the steps below.
    private static let bend = 1.5

    /// Cells, and which of them are lit. The rest are dim.
    public struct Frame: Equatable, Sendable {
        public var cells: [Character]
        public var lit: Range<Int>
    }

    /// The cell for a voice level, 0 to 1.
    public static func cell(level: Float) -> Character {
        let height = pow(Double(min(max(level, 0), 1)), bend)
        return ramp[min(Int(height * Double(ramp.count)), ramp.count - 1)]
    }

    /// The scope for `peaks`, the loudest voice in each column, oldest first. Every cell is lit.
    public static func listening(peaks: [Float]) -> Frame {
        Frame(cells: peaks.map(cell(level:)), lit: peaks.indices)
    }

    /// A flat line, lit, for Reduce Motion while you talk.
    public static var resting: Frame { listening(peaks: [Float](repeating: 0, count: columns)) }

    /// A dim line with the sweeping cell at `time`, which runs from one end to the other and back. With no time, as
    /// for Reduce Motion, it rests in the middle.
    public static func transcribing(at time: Double?) -> Frame {
        let period = 2 * columns - 2
        let step = time.map { Int(max($0, 0) / sweepStep) % period } ?? columns / 2
        let at = step < columns ? step : period - step
        var cells = [Character](repeating: baseline, count: columns)
        cells[at] = sweeping
        return Frame(cells: cells, lit: at..<at + 1)
    }
}
