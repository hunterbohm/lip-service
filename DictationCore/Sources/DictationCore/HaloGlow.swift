import Foundation

/// The glow around the recording bar's capsule: a blue rim hugging the outline, a soft blue haze past it, and a bright
/// glimmer that runs around the rim at a steady speed. The rim and haze brighten with the voice, so the bar stands out
/// on a dark window. This holds the sizes and the glimmer's place at a time; the view only draws them.
public enum HaloGlow {
    /// Room the halo needs past the capsule's outline on every side, for the rim and its haze, in points.
    public static let reach = 26.0
    /// The rim's width, drawn just outside the outline so the capsule never covers it.
    public static let rimWidth = 3.0
    /// How fast the glimmer runs along the rim, in points a second, so it laps a short bar sooner than a long one
    /// without changing speed.
    public static let speed = 300.0
    /// The glimmer's length along the rim, from its faint tail to its bright head, and the slices it is drawn in.
    public static let tail = 150.0
    public static let slices = 24
    /// The share of the light that stays on when the voice is silent, and what the voice adds to it.
    public static let restingLight = 0.4
    /// The rim's colour, #5A84F0, and the glimmer's, #C8DCFF.
    public static let color = (red: 0x5A / 255.0, green: 0x84 / 255.0, blue: 0xF0 / 255.0)
    public static let glimmerColor = (red: 0xC8 / 255.0, green: 0xDC / 255.0, blue: 0xFF / 255.0)

    /// A piece of the glimmer: the share of the rim's length it runs over, from 0 to 1 along the rim, and how bright it is.
    public struct Slice: Equatable, Sendable {
        public let from: Double
        public let to: Double
        public let light: Double
    }

    /// The length of the rim's centre line around a capsule `capsuleWidth` by `capsuleHeight`.
    public static func perimeter(capsuleWidth: Double, capsuleHeight: Double) -> Double {
        let width = capsuleWidth + rimWidth, height = capsuleHeight + rimWidth
        return 2 * max(width - height, 0) + .pi * height
    }

    /// The glimmer at `time`, as slices from its tail to its head, each brighter than the last. A slice that crosses
    /// the rim's start is split in two, so every `from` is below its `to`.
    public static func glimmer(at time: Double, perimeter: Double) -> [Slice] {
        guard perimeter > 0 else { return [] }
        let head = (time * speed).truncatingRemainder(dividingBy: perimeter)
        let length = min(tail, perimeter), step = length / Double(slices)
        var out: [Slice] = []
        for index in 0..<slices {
            let light = pow(Double(index + 1) / Double(slices), 2)
            let start = wrap(head - length + Double(index) * step, perimeter) / perimeter
            let end = start + step / perimeter
            if end <= 1 {
                out.append(Slice(from: start, to: end, light: light))
            } else {
                out.append(Slice(from: start, to: 1, light: light))
                out.append(Slice(from: 0, to: end - 1, light: light))
            }
        }
        return out
    }

    /// How brightly the halo is lit, 0 to 1. `glow` is the voice's glow level, 0 to 1.
    public static func light(glow: Double) -> Double { restingLight + (1 - restingLight) * min(max(glow, 0), 1) }

    /// The rim's opacity, the haze's opacity, and the haze's blur radius in points, for a light.
    public static func rimOpacity(light: Double) -> Double { 0.35 + 0.5 * light }
    public static func hazeOpacity(light: Double) -> Double { 0.12 + 0.33 * light }
    public static func hazeRadius(light: Double) -> Double { 6 + 9 * light }

    private static func wrap(_ value: Double, _ period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}
