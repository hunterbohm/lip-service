import Foundation

/// The glow around the recording bar's capsule: a soft rim in shades of blue that turns slowly, a blurred halo of the
/// same blues past it, and a bright beam that runs around the rim, deep blue at its tail and near white at its head.
/// The rim, halo and beam brighten with the voice, so the bar stands out on a dark window. This holds the sizes, the
/// colours and the beam's place at a time; the view only draws them.
public enum HaloGlow {
    /// Room the halo needs past the capsule's outline on every side, for the rim and its blur, in points.
    public static let reach = 48.0
    /// The rim's width, drawn just outside the outline so the capsule never covers it. A blurred copy twice as wide
    /// under it softens its edges.
    public static let rimWidth = 3.0
    /// How fast the rim's blues turn around the capsule, in radians a second.
    public static let turnRate = 1.6
    /// How fast the beam runs along the rim, in points a second, so it laps a short bar sooner than a long one
    /// without changing speed.
    public static let speed = 260.0
    /// The beam's length along the rim, from its faint tail to its bright head, and the slices it is drawn in.
    public static let tail = 140.0
    public static let slices = 40
    /// The share of the light that stays on when the voice is silent, and what the voice adds to it.
    public static let restingLight = 0.4

    public typealias RGB = (red: Double, green: Double, blue: Double)
    /// The blues the rim and halo turn through, evenly spaced around the capsule: navy, blue, sky, blue, deep blue.
    public static let rimColors: [RGB] = [rgb(0x1E3A8A), rgb(0x2563EB), rgb(0x38BDF8), rgb(0x3B82F6), rgb(0x1E40AF)]
    /// The beam's colour at its tail and at its head.
    public static let beamTail = rgb(0x2563EB)
    public static let beamHead = rgb(0xBAF0FF)

    /// A piece of the beam: the share of the rim's length it runs over, from 0 to 1 along the rim, how far along the
    /// beam it is (0 at the tail, 1 at the head), and how bright it is.
    public struct Slice: Equatable, Sendable {
        public let from: Double
        public let to: Double
        public let along: Double
        public let light: Double
    }

    /// The length of the rim's centre line around a capsule `capsuleWidth` by `capsuleHeight`.
    public static func perimeter(capsuleWidth: Double, capsuleHeight: Double) -> Double {
        let width = capsuleWidth + rimWidth, height = capsuleHeight + rimWidth
        return 2 * max(width - height, 0) + .pi * height
    }

    /// The angle the rim's blues start at, at `time`, in radians.
    public static func turn(at time: Double) -> Double { (time * turnRate).truncatingRemainder(dividingBy: 2 * .pi) }

    /// The beam at `time`, as slices from its tail to its head, each brighter than the last. A slice that crosses the
    /// rim's start is split in two, so every `from` is below its `to`.
    public static func beam(at time: Double, perimeter: Double) -> [Slice] {
        guard perimeter > 0 else { return [] }
        let head = (time * speed).truncatingRemainder(dividingBy: perimeter)
        let length = min(tail, perimeter), step = length / Double(slices)
        var out: [Slice] = []
        for index in 0..<slices {
            let along = Double(index + 1) / Double(slices)
            let light = pow(along, 1.6)
            let start = wrap(head - length + Double(index) * step, perimeter) / perimeter
            let end = start + step / perimeter
            if end <= 1 {
                out.append(Slice(from: start, to: end, along: along, light: light))
            } else {
                out.append(Slice(from: start, to: 1, along: along, light: light))
                out.append(Slice(from: 0, to: end - 1, along: along, light: light))
            }
        }
        return out
    }

    /// The beam's colour `along` its length, 0 at the tail and 1 at the head.
    public static func beamColor(along: Double) -> RGB {
        let k = min(max(along, 0), 1)
        return (beamTail.red + (beamHead.red - beamTail.red) * k, beamTail.green + (beamHead.green - beamTail.green) * k,
                beamTail.blue + (beamHead.blue - beamTail.blue) * k)
    }

    /// How brightly the glow is lit, 0 to 1. `glow` is the voice's glow level, 0 to 1.
    public static func light(glow: Double) -> Double { restingLight + (1 - restingLight) * min(max(glow, 0), 1) }

    /// The rim's opacity, the halo's opacity, and the halo's blur radius in points, for a light.
    public static func rimOpacity(light: Double) -> Double { 0.75 + 0.25 * light }
    public static func haloOpacity(light: Double) -> Double { 0.3 + 0.35 * light }
    public static func haloRadius(light: Double) -> Double { 8 + 6 * light }
    /// The beam's brightness as a share of each slice's, for a light.
    public static func beamOpacity(light: Double) -> Double { 0.7 + 0.3 * light }

    private static func rgb(_ hex: Int) -> RGB {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func wrap(_ value: Double, _ period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}
