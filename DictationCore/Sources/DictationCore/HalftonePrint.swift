import Foundation

/// The recording bar's glyph: a halftone print of the voice, on a 45-degree dot screen. It enters at the left and runs
/// right into the words, thinning as it arrives. This holds the screen's dot positions and how much of each dot the
/// print covers; the view only draws it.
public enum HalftonePrint {
    /// The glyph's width in points, which the words start after.
    public static let width = 45.0
    /// Distance between neighbouring dots on the screen's diagonals.
    public static let spacing = 2.6
    /// Dots sit this far from the glyph's left and right edges.
    public static let margin = 1.5
    /// Dots further than this from the bar's vertical centre are left out.
    public static let reach = 9.6
    /// How fast the voice travels from the left edge toward the words, in points per second.
    public static let speed = 70.0
    /// A dot smaller than this is not drawn.
    public static let smallestRadius = 0.14
    public static let largestRadius = 1.0
    /// Where the print starts to thin, and how far it thins over, in points from the left edge.
    public static let thinsFrom = 31.0
    public static let thinsOver = 14.0
    /// How much of the print is left at the words' edge.
    public static let thinnest = 0.15
    /// The light that runs along the baseline while the words are finished: how often it crosses, how far it travels
    /// before starting over, and where it starts.
    public static let passRate = 1.5
    public static let passTravel = 58.0
    public static let passStart = -7.0
    /// The dim line the baseline settles to while the words are finished, and the light's peak.
    public static let finishingLine = 0.16
    public static let finishingLight = 0.7

    /// A dot of the screen. `x` runs from the glyph's left edge, `y` from the bar's vertical centre, up.
    public struct Dot: Equatable, Sendable {
        public let x: Double
        public let y: Double
        /// How long ago the voice that sets this dot's height was heard: the further right, the older.
        public let delay: Double
        /// How much of the print survives at this dot, 1 on the left down to `thinnest` at the words.
        public let arrive: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
            delay = x / HalftonePrint.speed
            arrive = 1 - (1 - HalftonePrint.thinnest) * HalftonePrint.smoothstep(HalftonePrint.unit((x - HalftonePrint.thinsFrom) / HalftonePrint.thinsOver))
        }
    }

    /// The screen: columns `spacing / sqrt 2` apart, rows `spacing * sqrt 2` apart within a column, every odd column
    /// shifted half a row.
    public static let dots: [Dot] = {
        let column = spacing / 2.0.squareRoot(), row = spacing * 2.0.squareRoot()
        var dots: [Dot] = []
        let rows = Int((reach / row).rounded(.up))
        var index = 0
        var x = margin
        while x <= width - margin {
            let shift = index % 2 == 1 ? 0.5 : 0
            for step in -rows...rows {
                let y = (Double(step) + shift) * row
                if abs(y) <= reach { dots.append(Dot(x: x, y: y)) }
            }
            index += 1
            x = margin + Double(index) * column
        }
        return dots
    }()

    fileprivate static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    fileprivate static func unit(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// The light that runs along the baseline while the words are being finished.
    public enum Light: Equatable, Sendable {
        /// A light crossing the glyph from the left, 1.5 times a second, at `time`.
        case running(time: Double)
        /// Reduce Motion: only the dim baseline, with no light moving along it.
        case still
    }

    /// How much of the dot the print covers, 0 to 1. `voice` is the level at the dot's `delay`, times how far the bar is
    /// listening. `spin` is how far the words are being finished: the print settles to a dim baseline and a light runs along it.
    public static func coverage(of dot: Dot, voice: Double, spin: Double, light: Light) -> Double {
        let height = 1.0 + 8.2 * voice
        let y = abs(dot.y)
        let covered = smoothstep(unit((height - y) / 3 + 0.5)) * (1 - 0.6 * min(1, y / max(height, 1))) * dot.arrive
        guard spin > 0 else { return covered }
        var finishing = finishingLine * exp(-dot.y * dot.y / 3)
        if case .running(let time) = light {
            let pass = (time * passRate).truncatingRemainder(dividingBy: 1) * passTravel + passStart
            finishing = max(finishing, finishingLight * exp(-pow(dot.x - pass, 2) / 28 - dot.y * dot.y / 10))
        }
        return max(covered * (1 - spin), spin * finishing)
    }

    /// The dot's radius for a coverage, or nil when it is too small to draw.
    public static func radius(coverage: Double) -> Double? {
        let radius = largestRadius * max(0, coverage).squareRoot()
        return radius < smallestRadius ? nil : radius
    }
}
