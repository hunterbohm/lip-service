import Foundation

/// Spots Left Control tapped twice quickly on its own, which starts and ends a live talk. A tap is a press and a release
/// within `maxHold`, and the second press comes within `gap` of the first release. Any other key, any other modifier,
/// fn, or a click in between starts over, so Control held for a shortcut or a Control-click never counts.
public struct DoubleTapDetector: Equatable, Sendable {
    public static let leftControl = 59
    /// The device bit set only while Left Control is down, and the ones of the keys that must not be: Right Control and fn.
    static let leftControlMask: UInt64 = 0x0001
    static let othersMask: UInt64 = 0x2000 | 0x80_0000

    public enum Input: Equatable, Sendable { case down, up, other }

    public var maxHold = 0.3
    public var gap = 0.4
    private var downAt: Instant?
    private var lastTap: Instant?

    public init() {}

    /// What one key event means here. Nil for events that change nothing, such as another key let go.
    public static func input(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64) -> Input? {
        switch kind {
        case .keyDown: return .other
        case .keyUp: return nil
        case .flagsChanged:
            guard keyCode == leftControl else { return .other }
            var held = Modifiers(flags: flags)
            held.remove(.control)
            guard held.isEmpty, flags & othersMask == 0 else { return .other }
            return flags & leftControlMask != 0 ? .down : .up
        }
    }

    /// True when this input completes a double tap.
    public mutating func feed(_ input: Input, at time: Instant) -> Bool {
        switch input {
        case .other:
            (downAt, lastTap) = (nil, nil)
            return false
        case .down:
            if let lastTap, time - lastTap > gap { self.lastTap = nil }
            downAt = time
            return false
        case .up:
            guard let down = downAt, time - down <= maxHold else {
                (downAt, lastTap) = (nil, nil)
                return false
            }
            downAt = nil
            if let lastTap, down - lastTap <= gap {
                self.lastTap = nil
                return true
            }
            lastTap = time
            return false
        }
    }
}

public enum LiveTalkKey {
    /// "Left Control", as the settings and the hint name it.
    public static let name = "Left Control"

    /// Control-Option-M mutes and unmutes your microphone while a talk runs. M's key code is the same on every layout's
    /// physical key; while no talk runs the shortcut reaches the app in front as usual.
    public static let muteKeyCode = 46
    public static let muteModifiers: Modifiers = [.control, .option]
    public static let muteName = "⌃⌥M"

    /// Whether a key press is the mute shortcut: M with Control and Option and no other modifier.
    public static func isMute(keyCode: Int, flags: UInt64) -> Bool {
        keyCode == muteKeyCode && Modifiers(flags: flags) == muteModifiers
    }

    /// Why double-tapping Left Control can't start a talk with these keys, or nil when it can. A dictation key on Left
    /// Control alone already uses a double tap for hands-free dictation.
    public static func conflict(with keys: CaptureKeys) -> String? {
        guard let shortcut = keys.all.first(where: { $0.key == DoubleTapDetector.leftControl && $0.modifiers.isEmpty }) else { return nil }
        let use = switch keys.kind(of: shortcut) {
        case .dictate: "a dictation key"
        case .ghostwrite: "the Ghostwrite key"
        case .handOff: "the Hand off key"
        }
        return "Left Control is \(use), so double-tapping it can't start a live talk. Pick another key for that."
    }
}

/// The turn-taking numbers, in seconds unless named otherwise. Audio comes in blocks of `block` seconds of 16 kHz mono.
public struct TalkTiming: Equatable, Sendable {
    public var block = 0.03
    /// The room's level is read from this many blocks at the start of a talk.
    public var calibrationBlocks = 20
    /// Loud blocks in a row that start your turn.
    public var startBlocks = 3
    /// Loud blocks in a row, above the agent's own voice from the speakers, that cut in on the agent.
    public var cutInBlocks = 6
    /// Quiet that ends your turn.
    public var endOfTurn = 0.8
    /// Quiet after which your words so far are transcribed, while the rest of `endOfTurn` runs out, so the text is ready
    /// when the turn ends. Early enough to leave time for the transcription, about 0.1 s, and a preview still running.
    public var transcribeAfter = 0.5
    public var longestTurn = 90.0
    /// A turn shorter than this is a click or a knock, and is dropped. A quick "no" or "bye" is longer, so it stays a
    /// turn; a cough that is transcribed to nothing or to noise is dropped after transcription.
    public var shortestTurn = 0.2
    /// Blocks kept from before your turn started, so its first syllable is not cut off.
    public var prerollBlocks = 10
    /// After the agent starts speaking, its first syllables from the speakers can't cut in on it.
    public var grace = 0.6
    public var idleWarning = 100.0
    public var idleEnd = 120.0

    public init() {}
}

/// The levels that count as you talking, and as you talking over the agent. Without echo cancellation the agent's own
/// voice comes back from the speakers, so cutting in needs twice the margin.
public struct TalkThresholds: Equatable, Sendable {
    public var start: Float
    public var cutIn: Float

    /// RMS on the -1 to 1 scale. The floors are 250 and 900 on the 16-bit scale, as the prototype tuned them.
    public init(floor: Float) {
        start = max(floor * 3, 250 / 32768)
        cutIn = max(floor * 6, 900 / 32768)
    }

    /// The room's level: the middle of the readings, capped so talking straight away can't set it too high.
    public static func floor(of levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 50 / 32768 }
        return min(levels.sorted()[levels.count / 2], 400 / 32768)
    }
}

/// One turn of yours, as audio.
public struct TalkUtterance: Equatable, Sendable {
    public var samples: [Float]
    /// The end of the last loud block, which is when you stopped talking.
    public var speechEnd: Instant
    /// When the quiet after it was long enough to end the turn.
    public var turnEnd: Instant
}

/// Listens to the microphone through a talk and decides when you start and stop a turn and when you talk over the agent.
/// Pure: the app feeds it blocks with their times and acts on what it returns.
public struct TalkEar: Sendable {
    public enum Event: Equatable, Sendable {
        /// You started a turn.
        case began
        /// You paused for `transcribeAfter`: your words so far, to transcribe while the turn may still end. The turn is
        /// still yours.
        case paused(TalkUtterance)
        /// You talked again after a pause, so what `paused` gave is not the whole turn.
        case resumed
        /// Your turn ended.
        case ended(TalkUtterance)
        /// Something too short to be a turn, such as a cough.
        case dropped
        /// You talked over the agent: stop it. Your turn is under way.
        case cutIn
        case idleWarning
        case idleEnded

        /// A turn starts with this event, and the block it came with is already in `heard`.
        public var startsTurn: Bool { self == .began || self == .cutIn }
    }

    private enum Phase: Equatable, Sendable {
        case calibrating
        case waiting(quietSince: Instant, warned: Bool)
        /// `paused` is set once `paused` was sent for the quiet since `lastLoud`.
        case hearing(startedAt: Instant, lastLoud: Instant, paused: Bool)
        /// Your turn is over and the agent has it. `graceUntil` holds off a cut-in while its first words echo back.
        case agent(graceUntil: Instant, speaking: Bool)
    }

    public let timing: TalkTiming
    public private(set) var thresholds = TalkThresholds(floor: 50 / 32768)
    private var phase = Phase.calibrating
    private var levels: [Float] = []
    private var preroll: [[Float]] = []
    private var loud = 0
    public private(set) var heard: [Float] = []

    /// Blocks still to drop before the room is read: the talk's start sound, which the microphone hears from the speakers.
    private var cueBlocks: Int

    /// `cue` is how long the start sound plays, in seconds. The room is read once it has passed, with a little to spare
    /// for the sound starting late, so the sound is never taken for the room.
    public init(timing: TalkTiming = TalkTiming(), cue: Double = 0) {
        self.timing = timing
        cueBlocks = cue > 0 ? Int(((cue + 0.1) / timing.block).rounded(.up)) : 0
    }

    public var isHearing: Bool { if case .hearing = phase { true } else { false } }

    /// Skips reading the room, for a test clip that starts talking at once.
    public mutating func assume(floor: Float, at time: Instant) {
        thresholds = TalkThresholds(floor: floor)
        phase = .waiting(quietSince: time, warned: false)
    }

    public static func rms(_ block: [Float]) -> Float {
        guard !block.isEmpty else { return 0 }
        return (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot()
    }

    /// One block of audio that ends at `time`.
    public mutating func hear(_ block: [Float], at time: Instant) -> Event? {
        let level = Self.rms(block)
        switch phase {
        case .calibrating:
            if cueBlocks > 0 {
                cueBlocks -= 1
                return nil
            }
            levels.append(level)
            remember(block)
            guard levels.count >= timing.calibrationBlocks else { return nil }
            thresholds = TalkThresholds(floor: TalkThresholds.floor(of: levels))
            phase = .waiting(quietSince: time, warned: false)
            return nil
        case .waiting(let quietSince, let warned):
            remember(block)
            loud = level > thresholds.start ? loud + 1 : 0
            if loud >= timing.startBlocks {
                begin(at: time)
                return .began
            }
            let quiet = time - quietSince
            if quiet > timing.idleEnd { return .idleEnded }
            if !warned, quiet > timing.idleWarning {
                phase = .waiting(quietSince: quietSince, warned: true)
                return .idleWarning
            }
            return nil
        case .hearing(let startedAt, var lastLoud, var paused):
            heard += block
            var event: Event?
            if level > thresholds.start {
                lastLoud = time
                if paused { (paused, event) = (false, .resumed) }
            }
            let length = Double(heard.count) / Recording.sampleRate
            guard time - lastLoud > timing.endOfTurn || length > timing.longestTurn else {
                // A pause long enough to transcribe, in a turn long enough to keep.
                if !paused, time - lastLoud > timing.transcribeAfter, lastLoud - startedAt >= timing.shortestTurn {
                    paused = true
                    event = .paused(TalkUtterance(samples: heard, speechEnd: lastLoud, turnEnd: time))
                }
                phase = .hearing(startedAt: startedAt, lastLoud: lastLoud, paused: paused)
                return event
            }
            let utterance = TalkUtterance(samples: heard, speechEnd: lastLoud, turnEnd: time)
            heard = []
            // The preroll and the quiet at the end are not speech, so the length that counts is from the first loud block
            // to the last.
            if lastLoud - startedAt < timing.shortestTurn {
                phase = .waiting(quietSince: time, warned: false)
                preroll = []
                return .dropped
            }
            phase = .agent(graceUntil: time + 0.3, speaking: false)
            preroll = []
            loud = 0
            return .ended(utterance)
        case .agent(let graceUntil, let speaking):
            remember(block)
            guard time >= graceUntil else { return nil }
            loud = level > (speaking ? thresholds.cutIn : thresholds.start) ? loud + 1 : 0
            guard loud >= timing.cutInBlocks else { return nil }
            begin(at: time, after: timing.cutInBlocks)
            return .cutIn
        }
    }

    /// The agent's voice started playing. Until it finishes, only talk louder than its echo cuts in.
    public mutating func agentSpeaking(at time: Instant) {
        guard case .agent(_, false) = phase else { return }
        phase = .agent(graceUntil: time + timing.grace, speaking: true)
        loud = 0
    }

    /// The agent is working on a turn without speaking, such as after you answered its question.
    public mutating func agentWorking(at time: Instant) {
        phase = .agent(graceUntil: time + 0.3, speaking: false)
        loud = 0
    }

    /// You muted the microphone. Nothing is heard until `unmuted`. A turn of yours under way is dropped, not sent: you
    /// muted to say something the agent shouldn't hear. Returns true when a turn was dropped.
    public mutating func muted(at time: Instant) -> Bool {
        guard case .hearing = phase else { return false }
        heard = []
        preroll = []
        loud = 0
        phase = .waiting(quietSince: time, warned: false)
        return true
    }

    /// You unmuted at `time`. The quiet before the talk ends counts from now, so time spent muted never ends the talk,
    /// and nothing from before the mute starts your next turn.
    public mutating func unmuted(at time: Instant) {
        preroll = []
        loud = 0
        if case .waiting = phase { phase = .waiting(quietSince: time, warned: false) }
    }

    /// The agent finished its turn and everything it said has played. What the microphone heard meanwhile was its echo.
    public mutating func agentDone(at time: Instant) {
        guard case .agent = phase else { return }
        phase = .waiting(quietSince: time, warned: false)
        preroll = []
        loud = 0
    }

    private mutating func remember(_ block: [Float]) {
        preroll.append(block)
        if preroll.count > timing.prerollBlocks { preroll.removeFirst(preroll.count - timing.prerollBlocks) }
    }

    /// Starts your turn, which began `blocks` loud blocks ago: the ones it took to tell it was you.
    private mutating func begin(at time: Instant, after blocks: Int? = nil) {
        heard = preroll.flatMap { $0 }
        preroll = []
        loud = 0
        phase = .hearing(startedAt: time + -Double(blocks ?? timing.startBlocks) * timing.block, lastLoud: time, paused: false)
    }
}

/// What your words mean to the talk itself, apart from what they say to the agent.
public enum TalkWords {
    /// Said on their own, these end the talk.
    public static let goodbyes: [String] = [
        "goodbye", "good bye", "bye", "bye bye", "bye now", "end call", "end the call", "hang up", "thats all", "that is all",
        "stop talking", "end talk", "end the talk", "were done", "we are done", "im done",
    ]
    /// Words that may come before a goodbye, such as "okay, thanks, bye".
    static let fillers: Set<String> = ["ok", "okay", "alright", "all", "right", "thanks", "thank", "you", "great", "cool", "well", "so", "then",
                                      "for", "now", "perfect", "good", "awesome"]
    /// What the speech model can make of breathing or a click.
    public static let noise: Set<String> = ["", "uh", "um", "hmm", "mm", "mhm", "ah", "oh", "huh"]

    /// Lowercase letters, digits and single spaces. Apostrophes go, so "that's" reads "thats".
    public static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == "'" || scalar == "’" { return nil }
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func isNoise(_ text: String) -> Bool { noise.contains(normalize(text)) }

    /// Whether the whole turn is a goodbye, allowing the agent's name and a few fillers around it.
    public static func isGoodbye(_ text: String, agentNames: [String] = []) -> Bool {
        var words = normalize(text).split(separator: " ").map(String.init)
        let names = Set(agentNames.flatMap { normalize($0).split(separator: " ").map(String.init) })
        words.removeAll { names.contains($0) }
        guard !words.isEmpty, words.count <= 7 else { return false }
        let line = words.joined(separator: " ")
        for phrase in goodbyes {
            guard line == phrase || line.hasSuffix(" " + phrase) || line.hasPrefix(phrase + " ") || line.contains(" " + phrase + " ") else { continue }
            let rest = line.replacingOccurrences(of: phrase, with: " ").split(separator: " ").map(String.init)
            if rest.allSatisfy(fillers.contains) { return true }
        }
        return false
    }

    /// A spoken answer to the agent's question about a tool: true to allow, false to refuse, nil for anything else.
    public static func answer(_ text: String) -> Bool? {
        let line = normalize(text)
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "allow", "allow it", "go ahead", "do it", "ok", "okay", "yes please",
                                "please do", "go for it", "approve", "approved"]
        let no: Set<String> = ["no", "nope", "deny", "dont", "do not", "stop", "cancel", "no thanks", "dont do it", "refuse", "nah"]
        if yes.contains(line) { return true }
        if no.contains(line) { return false }
        return nil
    }
}
