import Foundation

/// The recording bar's scope: a grid of dots, columns running left to right with the newest voice next to the words.
/// Each dot's brightness comes from here; the view only draws it.
public enum HalftoneScope {
    public static let columns = 15
    public static let rows = 7
    /// Seconds of voice history between neighbouring columns.
    public static let step = 0.045

    public static var lastColumn: Int { columns - 1 }
    public static var middleRow: Int { (rows - 1) / 2 }

    /// How long ago the voice a column shows was heard.
    public static func delay(column: Int) -> Double { Double(lastColumn - column) * step }

    /// Older columns, to the left, are dimmer.
    public static func age(column: Int) -> Double { 0.45 + 0.55 * Double(column) / Double(lastColumn) }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// How lit a dot is by the voice alone, 0 to 1. `voice` is the level at the column's delay, times how far the bar is
    /// listening. Rows reach outward from the middle as the voice grows, and a silent column keeps a faint middle dot.
    public static func lit(column: Int, row: Int, voice: Double) -> Double {
        let band = -0.06 + 1.06 * voice
        let y = Double(abs(row - middleRow)) / Double(middleRow)
        return smoothstep(min(max((band - y) / 0.38 + 0.5, 0), 1)) * age(column: column)
    }

    /// The dot's final brightness. While `spin` is up the words are being finished: the voice fades out and the middle row
    /// ripples toward the words, or holds one dim level when `still`.
    public static func brightness(column: Int, row: Int, voice: Double, spin: Double, time: Double, still: Bool) -> Double {
        let lit = lit(column: column, row: row, voice: voice) * (1 - spin)
        guard row == middleRow else { return lit }
        let wave = still ? 0.25 : pow(0.5 + 0.5 * sin(Double(column) * 0.75 - time * 7), 2)
        return max(lit, spin * (0.2 + 0.6 * wave))
    }
}
