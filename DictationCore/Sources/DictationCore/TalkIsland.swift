import Foundation

/// The island a live talk shows at the top of the screen, in the style of the iPhone's Dynamic Island. On a screen with
/// a notch it grows out of the notch, with ears on either side; elsewhere it floats just below the top edge. Compact, it
/// shows a floating globe of dots on the left and the voice on the right. When another app's bar, such as a tiling window manager's,
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

        /// A screen without a notch: the island floats, a little bigger than the bar a dictation shows.
        public static let plain = Screen(hasNotch: false, notchWidth: 0, barHeight: 44)
    }

    /// How far the island sits below the top of a screen without a notch, or below another app's bar.
    public static let floatingGap = 6.0
    /// How far the island's top corners curve out into the screen edge around a notch.
    public static let earCurve = 9.0
    /// The corner radius when open.
    public static let openRadius = 32.0
    /// The bottom corner radius when compact under a notch.
    public static let notchRadius = 14.0
    /// The widest the island opens, so the panel that holds it never resizes.
    public static let widest = 600.0

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

    /// Each ear's width: the room for the globe on the left and the voice on the right. Around a notch, a step the
    /// agent is on widens both, for its app's icon and a word or two on the right and the time on the left.
    public static func earWidth(_ screen: Screen, step: Bool = false) -> Double { screen.hasNotch ? (step ? 132 : 54) : 62 }
    /// The width between the ears: the notch, or room for a word of status, or for a step's icon and a word or two.
    public static func centerWidth(_ screen: Screen, step: Bool = false) -> Double { screen.hasNotch ? screen.notchWidth : (step ? 196 : 132) }
    public static func compactWidth(_ screen: Screen, step: Bool = false) -> Double {
        centerWidth(screen, step: step) + 2 * earWidth(screen, step: step)
    }
    public static func openWidth(_ screen: Screen) -> Double { min(widest, max(compactWidth(screen) + 170, 500)) }

    /// How long the island stays open on one step, or on plain thinking, before it folds down to its closed look, which
    /// then carries the step's icon and a word or two. A new step opens it again.
    public static let settleAfter = 20.0

    /// Whether the agent has been on the same thing long enough for the island to fold down. A question it waits on you
    /// for, which is an activity without a step, never folds.
    public static func isSettled(_ bar: TalkBar, at now: Instant) -> Bool {
        guard bar.phase == .thinking, let since = bar.since, bar.step != nil || bar.activity == nil else { return false }
        return now - since >= settleAfter
    }

    /// Whether the closed island shows the step the agent is on.
    public static func showsStep(_ bar: TalkBar) -> Bool { bar.phase == .thinking && bar.step != nil }

    /// Whether the island is open for the talk now, with the pointer over it or not. `settled` folds a long wait down.
    public static func isOpen(_ bar: TalkBar, hovering: Bool, settled: Bool = false) -> Bool {
        if hovering || bar.endingSoon { return true }
        switch bar.phase {
        case .thinking: return !settled && (!bar.line.isEmpty || bar.activity != nil)
        case .speaking: return !bar.line.isEmpty
        case .ringing: return true
        case .connecting, .listening, .hearing: return false
        }
    }

    /// The timer shows once a step has run this long, in seconds, so quick steps stay quiet.
    public static let timerFrom = 5.0

    /// "0:42", "2:14", "1:02:05".
    public static func elapsed(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        let tail = (rest < 10 ? "0" : "") + String(rest)
        return hours > 0 ? "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(tail)" : "\(minutes):\(tail)"
    }

    /// What the globe's colours say: blues while you can talk, violet and pink while the agent thinks, amber while it
    /// speaks, greys while the talk connects, and a dim red while you are muted.
    public enum Mood: Equatable, Sendable { case connecting, you, thinking, speaking, ringing, muted }

    /// The mood for a talk, with muting taken into account: muted shows only while the turn is yours.
    public static func mood(_ bar: TalkBar) -> Mood { bar.showsMuted ? .muted : mood(bar.phase) }

    public static func mood(_ phase: TalkBar.Phase) -> Mood {
        switch phase {
        case .connecting: .connecting
        case .listening, .hearing: .you
        case .thinking: .thinking
        case .speaking: .speaking
        case .ringing: .ringing
        }
    }

    public typealias RGB = (red: Double, green: Double, blue: Double)

    /// The globe's three colours, which turn around it.
    public static func orbColors(_ mood: Mood) -> [RGB] {
        switch mood {
        case .connecting: [(0.55, 0.55, 0.55), (0.9, 0.9, 0.9), (0.4, 0.4, 0.4)]
        case .you: [(0.2, 0.85, 1), (0.25, 0.45, 1), (0.4, 1, 0.85)]
        case .thinking: [(0.62, 0.4, 1), (0.95, 0.4, 0.85), (0.35, 0.45, 1)]
        case .speaking: [(1, 0.72, 0.25), (1, 0.45, 0.35), (1, 0.88, 0.5)]
        case .ringing: [(0.25, 0.9, 0.45), (0.15, 0.7, 0.5), (0.6, 1, 0.55)]
        case .muted: [(1, 0.4, 0.4), (0.6, 0.3, 0.32), (0.85, 0.5, 0.5)]
        }
    }

    /// The island's rim: the globe's leading colour, lightened halfway to white so it reads as light. It turns with the
    /// mood, so the edge says who has the turn even at a glance.
    public static func edgeColor(_ mood: Mood) -> RGB {
        let lead = orbColors(mood)[0]
        return ((lead.red + 1) / 2, (lead.green + 1) / 2, (lead.blue + 1) / 2)
    }

    /// How solid the rim is along the top, where it is brightest, and down the sides, where it is faintest.
    public static let edgeBrightest = 0.75
    public static let edgeFaintest = 0.5
    /// The rim's width in points.
    public static let edgeWidth = 1.0
    /// How solid the glow around the island is, in the rim's colour, and how far it reaches in points.
    public static let glowOpacity = 0.4
    public static let glowReach = 9.0

    /// How much the rim stands out from a black window, as a contrast ratio, where it is `opacity` solid. An edge needs
    /// 3 to be seen (WCAG 1.4.11); a white hairline a quarter solid, which the island had, is under 2.
    public static func edgeContrast(_ mood: Mood, opacity: Double = edgeFaintest) -> Double {
        let color = edgeColor(mood)
        func linear(_ channel: Double) -> Double {
            let value = channel * opacity
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        return (luminance + 0.05) / 0.05
    }

    /// How to end the talk, beside the button that ends it.
    public static let endHint = "Double-tap Left Control or say goodbye to end"
    /// The mute button's tooltip, which names its shortcut.
    public static func muteHelp(muted: Bool) -> String { "\(muted ? "Unmute" : "Mute") your microphone (\(LiveTalkKey.muteName))" }

    /// How fast the globe's colours turn, in radians a second: quick while the agent works, slow while it waits on you.
    public static func orbSpeed(_ mood: Mood) -> Double {
        switch mood {
        case .thinking, .connecting, .ringing: 2.4
        case .speaking: 1.2
        case .you: 0.6
        case .muted: 0.2
        }
    }

    /// The globe's scale: it swells with the voice, and breathes while the agent works.
    public static func orbScale(level: Double, mood: Mood, time: Double) -> Double {
        let breathe = mood == .thinking || mood == .connecting || mood == .ringing ? 0.07 * sin(time * 4.5) : 0
        return 1 + min(max(level, 0), 1) * 0.22 + breathe
    }

    /// The globe's size in points: about three fifths of the header, so black shows above and below it as it floats and
    /// swells.
    public static func globeSize(_ screen: Screen) -> Double { min(26, (screen.barHeight * 0.6).rounded()) }

    /// Dots across the globe, so each is a few pixels: the globe reads as a grid of dots, not a solid ball.
    public static let globeGrid = 11
    /// How high the globe floats up and down, in points, and how many times a second.
    public static let globeBob = 1.2

    /// One dot of the globe, on a grid over the unit square the globe fills. `size` is the dot's diameter as a share of
    /// its cell, in a few steps like the characters of ASCII art. `tint` is where its colour sits among the mood's three,
    /// 0 to 3, so the colours turn around the globe as it spins.
    public struct GlobeDot: Equatable, Sendable {
        public var column: Int
        public var row: Int
        public var size: Double
        public var brightness: Double
        public var tint: Double
    }

    /// The tilted, spinning globe at `time`, lit from the upper left, with land brighter than sea. The voice brightens
    /// every dot and sends ripples out from the middle; the mood sets how fast it turns. Cells outside the disc, and dots
    /// too faint to see, are left out.
    public static func globeDots(time: Double, level: Double, mood: Mood, grid: Int = globeGrid) -> [GlobeDot] {
        let level = min(max(level, 0), 1)
        let spin = time * orbSpeed(mood) * 0.35
        let tilt = 0.41
        let light = (x: -0.45, y: 0.55, z: 0.7)
        let lightLength = (light.x * light.x + light.y * light.y + light.z * light.z).squareRoot()
        var dots: [GlobeDot] = []
        for row in 0..<grid {
            for column in 0..<grid {
                let x = (Double(column) + 0.5) / Double(grid) * 2 - 1
                let y = 1 - (Double(row) + 0.5) / Double(grid) * 2
                let r2 = x * x + y * y
                guard r2 <= 1 else { continue }
                let z = (1 - r2).squareRoot()
                // The point on the globe under this cell, turned back by the tilt, as latitude and longitude.
                let tiltedY = y * cos(tilt) - z * sin(tilt)
                let tiltedZ = y * sin(tilt) + z * cos(tilt)
                let latitude = asin(max(-1, min(1, tiltedY)))
                let longitude = atan2(x, tiltedZ) + spin
                let land = globeLand(latitude: latitude, longitude: longitude)
                let lit = max(0, (x * light.x + y * light.y + z * light.z) / lightLength)
                let ripple = level * 0.35 * max(0, sin(r2.squareRoot() * 9 - time * 11))
                let brightness = min(1, (land ? 1 : 0.55) * (0.6 + 0.4 * lit) * (0.9 + 0.2 * level) + ripple)
                let size = globeStep(0.35 + 0.65 * brightness)
                guard brightness > 0.06 else { continue }
                let turn = (longitude / (2 * Double.pi)).truncatingRemainder(dividingBy: 1)
                dots.append(GlobeDot(column: column, row: row, size: size, brightness: brightness, tint: (turn < 0 ? turn + 1 : turn) * 3))
            }
        }
        return dots
    }

    /// Made-up continents: a few waves over latitude and longitude, so land drifts past as the globe turns.
    static func globeLand(latitude: Double, longitude: Double) -> Bool {
        let wave = sin(3 * longitude + 1.3 * sin(2 * latitude)) * cos(2 * latitude + 0.5)
            + 0.6 * sin(5 * longitude - 2 * latitude + 1) * cos(3 * latitude)
        return wave > 0.15
    }

    /// Dot sizes come in four steps, as an ASCII ramp has a few characters.
    static func globeStep(_ size: Double) -> Double {
        let steps = [0.45, 0.62, 0.8, 0.95]
        return steps.last { $0 <= size } ?? steps[0]
    }

    /// The globe swells half as much as the orb did, since it nearly fills the header already.
    public static func globeScale(level: Double, mood: Mood, time: Double) -> Double { 1 + (orbScale(level: level, mood: mood, time: time) - 1) / 2 }

    /// How far the globe floats above its place at `time`, in points.
    public static func globeFloat(time: Double) -> Double { globeBob * sin(time * 1.6) }

    /// The longest line the island shows as a notice, in characters; anything longer stays a card.
    public static let noticeLongest = 240
    /// How many lines the island keeps, newest first.
    public static let noticeMost = 2

    /// How long a new notice holds the island open, in seconds: a line long enough to read, a result long enough to
    /// take in, and one with buttons long enough to decide.
    public static func noticeHold(_ content: IslandNotice.Content) -> Double {
        switch content {
        case .text: 6
        case .callBack: 8
        case .rich(let card): card.actions.isEmpty ? 14 : 30
        }
    }

    /// How long a notice stays, to be read again under the pointer.
    public static func noticeLife(_ content: IslandNotice.Content) -> Double {
        if case .rich = content { 600 } else { 120 }
    }

    /// The island's notices with a new one added, newest first. One with the same key takes the old one's place, so
    /// flights that come in again update the card they are on. One result is kept at a time, with one line beside it,
    /// since a result takes most of the island; without a result, `noticeMost` lines.
    public static func adding(_ content: IslandNotice.Content, to notices: [IslandNotice], at now: Instant) -> [IslandNotice] {
        let new = IslandNotice(content: content, added: now)
        var all = notices.filter { now - $0.added < noticeLife($0.content) && $0.key != new.key && !(new.isRich && $0.isRich) }
        all.insert(new, at: 0)
        let lines = all.contains(where: \.isRich) ? 1 : noticeMost
        var kept: [IslandNotice] = []
        for notice in all where notice.isRich || kept.filter({ !$0.isRich }).count < lines { kept.append(notice) }
        return kept
    }

    /// What the agent put on screen, as a notice inside the island, when it is a short line such as what it just did:
    /// "PP-3 · ProfitPilot outreach · due Nov 9". Links, images, visuals, code and long text stay cards. Nil for those.
    public static func notice(_ card: ShowCard) -> String? {
        guard case .text(let raw) = card else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: \.isNewline).map { Speech.collapse(String($0)) }
        guard !text.isEmpty, text.count <= noticeLongest, lines.count <= 3, !looksLikeCode(text, lines: lines.count) else { return nil }
        // A link written in Markdown needs its address, which a card keeps.
        guard text.firstMatch(of: /\[[^\]]+\]\([^)]+\)/) == nil else { return nil }
        // Only bold marks around words go; every other character is kept as the agent wrote it.
        return lines.map { $0.replacing(/\*\*([^*]+)\*\*/) { String($0.1) } }.joined(separator: "\n")
    }

    /// Code or a command reads better on a card: marks that prose seldom uses, a command's flags or `&&`, a prompt
    /// sign, a line that starts with a common command or runs a script, or a fence. Over several lines, brackets and
    /// semicolons count too.
    static func looksLikeCode(_ text: String, lines: Int) -> Bool {
        if text.contains(where: { "{}<>$`|\\=".contains($0) }) || text.contains("&&") || text.hasPrefix("$ ") { return true }
        if text.firstMatch(of: /(^|\s)--?[A-Za-z]/) != nil { return true }
        // A line that starts with a command, or runs a script: `git status`, `npm install`, `python script.py`.
        let programs: Set<String> = ["git", "npm", "npx", "yarn", "pnpm", "bun", "node", "deno", "python", "python3", "pip",
                                     "pip3", "uv", "swift", "xcodebuild", "brew", "cd", "ls", "cat", "curl", "wget", "ssh",
                                     "scp", "make", "cargo", "go", "docker", "kubectl", "echo", "rm", "mv", "cp", "mkdir",
                                     "touch", "chmod", "sudo", "open", "ruby", "gem", "bundle", "rails", "gh", "hermes",
                                     "t3-run", "kb", "launchctl", "defaults", "tail", "grep", "rg", "sed", "awk", "export"]
        let scripts = /(^|\s)(~|\.{0,2})\/?[\w.\/-]*\.(py|sh|js|mjs|ts|rb|swift|pl)(\s|$)/
        for line in text.split(whereSeparator: \.isNewline) {
            let first = line.split(separator: " ").first.map(String.init) ?? ""
            if programs.contains(first) || first.hasPrefix("./") || first.hasPrefix("~/") { return true }
            if line.firstMatch(of: scripts) != nil { return true }
        }
        return lines > 1 && text.contains(where: { "();".contains($0) })
    }

    /// What the right ear shows.
    public enum Ear: Equatable, Sendable {
        /// Five bars that move with the voice, white for yours and amber for the agent's.
        case voice(agent: Bool)
        /// Three dots that rise in turn.
        case working
        /// A crossed-out microphone: you are muted.
        case muted
    }

    /// The right ear for a talk, with muting taken into account.
    /// Muted, the ear shows the crossed-out microphone, except while the agent speaks: its voice is still playing.
    public static func ear(_ bar: TalkBar) -> Ear { bar.showsMuted && bar.phase != .speaking ? .muted : ear(bar.phase) }

    public static func ear(_ phase: TalkBar.Phase) -> Ear {
        switch phase {
        case .connecting, .thinking, .ringing: .working
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
        case .listening, .hearing: bar.muted ? "Muted" : "Listening"
        case .thinking, .speaking: bar.agent.name
        case .ringing: "\(bar.agent.name) is calling"
        }
    }
}
