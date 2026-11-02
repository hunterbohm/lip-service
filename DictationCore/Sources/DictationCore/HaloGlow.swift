import Foundation

/// The glow around the recording bar's capsule: a ring of small blue dots on a hex grid that light up with the voice.
/// The light starts at the print and spreads out, so a dot far from the print lights later and fainter. This holds the
/// dots of one capsule size and how strongly each one is lit; the view only draws them.
public enum HaloGlow {
    /// Dots are drawn this far past the capsule's outline, at most, in points.
    public static let reach = 26.0
    /// Dots closer to the outline than this are left out, so the capsule's edge stays clear.
    public static let gap = 2.0
    /// Distance between neighbouring dots in a row, the distance between rows, and how far odd rows shift.
    public static let spacing = 5.0
    public static let rowSpacing = 5.0 * 0.866
    public static let rowShift = 2.5
    /// How far a dot's light fades with its distance from the outline, past `gap`.
    public static let edgeFalloff = 11.0
    /// How far it fades with its distance from the print, measured with y stretched by `stretch`.
    public static let printFalloff = 520.0
    public static let stretch = 1.6
    /// Seconds the voice takes to travel one point from the print.
    public static let secondsPerPoint = 1.0 / 900
    /// Distance from the capsule's left edge to the print glyph, which is the bar's padding. The light centres on the
    /// glyph's middle.
    public static let printInset = 18.0
    /// The share of a dot's light that stays on when the voice is silent, and what the voice adds to it.
    public static let restingLight = 0.12
    /// A dot dimmer than this is not drawn.
    public static let faintest = 0.015
    public static let smallestRadius = 0.4
    public static let radiusGain = 1.1
    public static let faintestOpacity = 0.05
    public static let opacityGain = 0.62
    /// The dots' colour, #5A84F0.
    public static let color = (red: 0x5A / 255.0, green: 0x84 / 255.0, blue: 0xF0 / 255.0)

    /// A dot of the grid. `x` runs from the capsule's left edge and `y` from its top edge, down, so both are negative
    /// above and left of it.
    public struct Dot: Equatable, Sendable {
        public let x: Double
        public let y: Double
        /// How long ago the voice that lights this dot was heard: the further from the print, the older.
        public let delay: Double
        /// How much of the light survives at this dot, from its distance to the outline and to the print. It never changes.
        public let weight: Double
    }

    /// The grid for a capsule `capsuleWidth` by `capsuleHeight`, which moves with the capsule's top-left corner. Dots that
    /// are inside the capsule, within `gap` of it, past `reach`, or too weak ever to show are left out.
    public static func dots(capsuleWidth: Double, capsuleHeight: Double) -> [Dot] {
        let radius = capsuleHeight / 2
        let printX = printInset + HalftonePrint.width / 2, printY = radius
        var dots: [Dot] = []
        var row = 0
        var y = -reach
        while y <= capsuleHeight + reach {
            let shift = row % 2 == 1 ? rowShift : 0
            var column = 0
            var x = -reach + shift
            while x <= capsuleWidth + reach {
                let beyondEnds = max(radius - x, 0, x - (capsuleWidth - radius))
                let edge = hypot(beyondEnds, y - printY) - radius
                if edge >= gap && edge <= reach {
                    let far = hypot(x - printX, stretch * (y - printY))
                    let weight = exp(-pow((edge - gap) / edgeFalloff, 2)) * exp(-far / printFalloff)
                    if weight >= faintest { dots.append(Dot(x: x, y: y, delay: far * secondsPerPoint, weight: weight)) }
                }
                column += 1
                x = -reach + shift + Double(column) * spacing
            }
            row += 1
            y = -reach + Double(row) * rowSpacing
        }
        return dots
    }

    /// How brightly the dot is lit, 0 to 1. `glow` is the glow level at the dot's `delay`, 0 to 1.
    public static func strength(of dot: Dot, glow: Double) -> Double {
        (restingLight + (1 - restingLight) * glow) * dot.weight
    }

    /// The dot's radius in points for a strength.
    public static func radius(strength: Double) -> Double { smallestRadius + radiusGain * strength }

    /// The dot's opacity for a strength, before the halo as a whole fades in or out.
    public static func opacity(strength: Double) -> Double { faintestOpacity + opacityGain * strength }
}
