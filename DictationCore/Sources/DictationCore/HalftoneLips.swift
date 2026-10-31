import Foundation

/// The recording bar's glyph: two lips of dots on a 45-degree halftone screen. They part as the voice rises, the middle
/// first and the corners a moment later. This holds the screen's dot positions and how much of each dot the lips cover;
/// the view only draws it.
public enum HalftoneLips {
    /// The glyph's width in points, which the words start after.
    public static let width = 45.0
    /// Distance between neighbouring dots on the screen's diagonals.
    public static let spacing = 2.4
    /// Dots sit this far from the glyph's left and right edges.
    public static let margin = 1.5
    /// The length of the lips, from the left corner's dots to the right's.
    public static let length = width - 3
    /// Dots further than this from the bar's vertical centre are left out.
    public static let reach = 9.6
    /// How much later the corners follow the middle, in seconds.
    public static let lag = 0.16
    /// A dot smaller than this is not drawn.
    public static let smallestRadius = 0.14
    public static let largestRadius = 0.95
    /// The most the light along a closed seam reaches while Reduce Motion holds it still.
    public static let stillSeam = 0.35

    /// A dot of the screen. `x` runs from the glyph's left edge, `y` from the bar's vertical centre, up.
    public struct Dot: Equatable, Sendable {
        public let x: Double
        public let y: Double
        /// Along the lips, 0 at the left corner to 1 at the right.
        public let u: Double
        /// How full the lips are at `u`: 0 at the corners, 1 in the middle.
        public let shape: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
            u = (x - HalftoneLips.margin) / HalftoneLips.length
            shape = u < 0 || u > 1 ? 0 : pow(sin(Double.pi * u), 0.75)
        }

        /// How long ago the voice that opens this dot's lips was heard.
        public var delay: Double { abs(u - 0.5) * HalftoneLips.lag }
    }

    /// The screen: columns `spacing / sqrt 2` apart, rows `spacing * sqrt 2` apart within a column, every odd column
    /// shifted half a row. Dots outside the lips' length are dropped.
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
                let dot = Dot(x: x, y: y)
                if abs(y) <= reach, dot.u >= 0, dot.u <= 1 { dots.append(dot) }
            }
            index += 1
            x = margin + Double(index) * column
        }
        return dots
    }()

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func unit(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// The light along the seam while the words are being finished.
    public enum Seam: Equatable, Sendable {
        /// A light running from the left corner to the right, once per 1/1.4 s, at `time`.
        case running(time: Double)
        /// Reduce Motion: a dim seam that does not move.
        case still
    }

    /// How much of the dot the lips cover, 0 to 1. `voice` is the level at the dot's `delay`, times how far the bar is
    /// listening. `spin` is how far the words are being finished: the lips close and the seam lights.
    public static func coverage(of dot: Dot, voice: Double, spin: Double, seam: Seam) -> Double {
        let gap = (0.8 + 9.5 * voice) * dot.shape * (1 - 0.85 * spin)
        let thick = 0.8 + 2.6 * dot.shape
        let y = abs(dot.y)
        var covered = smoothstep(unit((y - gap / 2) / 1.1 + 0.5)) * smoothstep(unit((gap / 2 + thick - y) / 1.1 + 0.5))
        guard spin > 0 else { return covered }
        let along: Double
        switch seam {
        case .running(let time):
            let pass = (time * 1.4).truncatingRemainder(dividingBy: 1)
            along = 0.8 * exp(-pow(dot.u - pass, 2) / 0.01)
        case .still:
            along = stillSeam
        }
        covered = max(covered, spin * along * exp(-y * y / 6) * dot.shape)
        return covered
    }

    /// The dot's radius for a coverage, or nil when it is too small to draw.
    public static func radius(coverage: Double) -> Double? {
        let radius = largestRadius * max(0, coverage).squareRoot()
        return radius < smallestRadius ? nil : radius
    }
}
