import Foundation

/// The island a live talk shows at the top of the screen, in the style of the iPhone's Dynamic Island. On a screen with
/// a notch it grows out of the notch, with ears on either side; elsewhere it floats just below the top edge. Compact, it
/// shows a living orb on the left and the voice on the right. When another app's bar, such as a tiling window manager's,
/// covers the top of the screen, it floats just below that bar instead, with or without a notch. It opens up when there
/// is something to read: your words while the agent thinks, the sentence the agent is saying, a warning that the talk
/// ends soon, or your pointer over it, which also shows the button that ends the talk. This holds its shape, sizes,
/// colours, place and when it opens; the view only draws it.
public enum TalkIsland {
    /// The screen the island sits on: whether it has a notch, how wide the notch is, and how tall the strip beside it is.
    public struct Screen: Equatable, Sendable {
        public var hasNotch: Bool
        public var notchWidth: Double
        public var barHeight: Double

        public init(hasNotch: Bool, notchWidth: Double, barHeight: Double) {
            (self.hasNotch, self.notchWidth, self.barHeight) = (hasNotch, notchWidth, barHeight)
        }

        /// A screen without a notch: the island floats, as tall as a menu bar.
        public static let plain = Screen(hasNotch: false, notchWidth: 0, barHeight: 34)
    }

    /// How far the island sits below the top of a screen without a notch, or below another app's bar.
    public static let floatingGap = 6.0
    /// How far the island's top corners curve out into the screen edge around a notch.
    public static let earCurve = 9.0
    /// The corner radius when open.
    public static let openRadius = 30.0
    /// The bottom corner radius when compact under a notch.
    public static let notchRadius = 12.0
    /// The widest the island opens, so the panel that holds it never resizes.
    public static let widest = 560.0

    /// Where the island sits on its screen: the look it takes, and how far below the top edge of the screen its top is.
    public struct Placement: Equatable, Sendable {
        public var screen: Screen
        public var drop: Double

        public init(screen: Screen, drop: Double) { (self.screen, self.drop) = (screen, drop) }
    }

    /// How much of the top of a screen another app's bar must cover, in points, before the island moves out from under it.
    public static let barTolerance = 1.0

    /// Where the island sits on a screen of `frame`, in AppKit's coordinates, given `clear`: that frame less the strips
    /// other apps' bars cover. With nothing covering the top, a notch grows the island out of itself and a plain screen
    /// floats it `floatingGap` below the top. With another app's bar across the top, the island floats `floatingGap`
    /// below that bar in the plain look, even around a notch, since the bar hides the notch's edge, but never higher than
    /// the strip of the notch.
    public static func placement(frame: BarRect, screen: Screen, clear: BarRect) -> Placement {
        let covered = frame.maxY - clear.maxY
        guard covered > barTolerance else { return Placement(screen: screen, drop: screen.hasNotch ? 0 : floatingGap) }
        let notch = screen.hasNotch ? screen.barHeight : 0
        return Placement(screen: .plain, drop: max(covered, notch) + floatingGap)
    }

    /// Each ear's width: the room for the orb on the left and the voice on the right.
    public static func earWidth(_ screen: Screen) -> Double { screen.hasNotch ? 46 : 44 }
    /// The width between the ears: the notch, or room for a word of status.
    public static func centerWidth(_ screen: Screen) -> Double { screen.hasNotch ? screen.notchWidth : 96 }
    public static func compactWidth(_ screen: Screen) -> Double { centerWidth(screen) + 2 * earWidth(screen) }
    public static func openWidth(_ screen: Screen) -> Double { min(widest, max(compactWidth(screen) + 160, 470)) }

    /// Whether the island is open for the talk now, with the pointer over it or not.
    public static func isOpen(_ bar: TalkBar, hovering: Bool) -> Bool {
        if hovering || bar.endingSoon { return true }
        switch bar.phase {
        case .thinking: return !bar.line.isEmpty || bar.activity != nil
        case .speaking: return !bar.line.isEmpty
        case .connecting, .listening, .hearing: return false
        }
    }

    /// What the orb's colours say: blues while you can talk, violet and pink while the agent thinks, amber while it
    /// speaks, and greys while the talk connects.
    public enum Mood: Equatable, Sendable { case connecting, you, thinking, speaking }

    public static func mood(_ phase: TalkBar.Phase) -> Mood {
        switch phase {
        case .connecting: .connecting
        case .listening, .hearing: .you
        case .thinking: .thinking
        case .speaking: .speaking
        }
    }

    public typealias RGB = (red: Double, green: Double, blue: Double)

    /// The orb's three colours, which turn around it.
    public static func orbColors(_ mood: Mood) -> [RGB] {
        switch mood {
        case .connecting: [(0.55, 0.55, 0.55), (0.9, 0.9, 0.9), (0.4, 0.4, 0.4)]
        case .you: [(0.2, 0.85, 1), (0.25, 0.45, 1), (0.4, 1, 0.85)]
        case .thinking: [(0.62, 0.4, 1), (0.95, 0.4, 0.85), (0.35, 0.45, 1)]
        case .speaking: [(1, 0.72, 0.25), (1, 0.45, 0.35), (1, 0.88, 0.5)]
        }
    }

    /// How fast the orb's colours turn, in radians a second: quick while the agent works, slow while it waits on you.
    public static func orbSpeed(_ mood: Mood) -> Double {
        switch mood {
        case .thinking, .connecting: 2.4
        case .speaking: 1.2
        case .you: 0.6
        }
    }

    /// The orb's scale: it swells with the voice, and breathes while the agent works.
    public static func orbScale(level: Double, mood: Mood, time: Double) -> Double {
        let breathe = mood == .thinking || mood == .connecting ? 0.07 * sin(time * 4.5) : 0
        return 1 + min(max(level, 0), 1) * 0.22 + breathe
    }

    /// What the right ear shows.
    public enum Ear: Equatable, Sendable {
        /// Five bars that move with the voice, white for yours and amber for the agent's.
        case voice(agent: Bool)
        /// Three dots that rise in turn.
        case working
    }

    public static func ear(_ phase: TalkBar.Phase) -> Ear {
        switch phase {
        case .connecting, .thinking: .working
        case .listening, .hearing: .voice(agent: false)
        case .speaking: .voice(agent: true)
        }
    }

    /// The five voice bars' shape, tallest in the middle.
    public static let barShape: [Double] = [0.55, 0.85, 1, 0.8, 0.5]
    public static let barTallest = 22.0

    /// The height of voice bar `index` for a level, at `time`.
    public static func barHeight(index: Int, level: Double, time: Double) -> Double {
        let wobble = (sin(time * 8 + Double(index) * 1.4) + 1) / 2
        let height = 4 + min(max(level, 0), 1) * 18 * (0.45 + 0.55 * wobble) * barShape[index % barShape.count]
        return min(barTallest, height)
    }

    /// How far working dot `index` has risen, 0 to 1, at `time`.
    public static func dotLift(index: Int, time: Double) -> Double { (sin(time * 6 - Double(index) * 0.7) + 1) / 2 }

    /// The header's words: the status on a screen without a notch, where there is room between the ears.
    public static func headline(_ bar: TalkBar) -> String {
        switch bar.phase {
        case .connecting: "Connecting"
        case .listening, .hearing: "Listening"
        case .thinking, .speaking: bar.agent.name
        }
    }
}
