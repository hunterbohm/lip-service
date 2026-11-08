import Foundation

/// A voice on this Mac, run by FluidAudio: which of its speech models, and which of that model's voices.
public struct OnMacVoice: Equatable, Hashable, Codable, Sendable, Identifiable {
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// Kokoro 82M, on the Neural Engine.
        case kokoro
        /// PocketTTS small with the Phonon voices, from FluidAudio 0.18.3.
        case pocketPhonon
    }

    public var model: Model
    public var voice: String

    public init(model: Model, voice: String) { (self.model, self.voice) = (model, voice) }

    public var id: String { "\(model.rawValue):\(voice)" }

    /// Kokoro's American male voice.
    public static let michael = OnMacVoice(model: .kokoro, voice: "am_michael")
    public static let standard = michael

    /// The voices the settings offer. Any other voice the model has works too, set through `setup apply` or by hand.
    public static let offered: [OnMacVoice] = [
        michael, OnMacVoice(model: .kokoro, voice: "am_adam"), OnMacVoice(model: .kokoro, voice: "am_eric"),
        OnMacVoice(model: .kokoro, voice: "af_heart"), OnMacVoice(model: .kokoro, voice: "af_bella"),
        OnMacVoice(model: .kokoro, voice: "bm_george"), OnMacVoice(model: .kokoro, voice: "bf_emma"),
    ]

    /// "Michael (American, Kokoro)".
    public var title: String {
        let parts = voice.split(separator: "_", maxSplits: 1)
        guard model == .kokoro, parts.count == 2, parts[0].count == 2 else { return voice }
        let accent = parts[0].first == "b" ? "British" : "American"
        return "\(parts[1].capitalized) (\(accent), Kokoro)"
    }
}

/// Where the talk's voice comes from.
public enum TalkVoiceChoice: Equatable, Codable, Sendable {
    /// Made on this Mac. Nothing leaves it.
    case onMac(OnMacVoice)
    /// A voice server: `POST {url}/speak` with JSON `{text, voice, format: "wav"}` answers with a WAV. For a Mac that
    /// can't run a voice itself, or a voice that lives on another machine.
    case server(url: String, voice: String)

    public var title: String {
        switch self {
        case .onMac(let voice): voice.title
        case .server(let url, let voice):
            (voice.isEmpty ? "" : voice + " on ") + (URL(string: url)?.host ?? (url.isEmpty ? "a voice server" : url))
        }
    }

    /// The `/speak` address, or nil for a server address that isn't one.
    public static func speakURL(_ base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false
        else { return nil }
        if !components.path.hasSuffix("/speak") {
            components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/speak"
        }
        return components.url
    }
}

public struct LiveTalkSettings: Equatable, Codable, Sendable {
    /// Double-tapping Left Control starts a talk. It still needs an agent.
    public var enabled = true
    /// Who you talk with, or nil for the default agent.
    public var agentID: String?
    public var voice = TalkVoiceChoice.onMac(.standard)

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LiveTalkSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        agentID = (try? container.decodeIfPresent(String.self, forKey: .agentID)) ?? defaults.agentID
        voice = (try? container.decodeIfPresent(TalkVoiceChoice.self, forKey: .voice)) ?? defaults.voice
    }

    /// The agent a talk goes to: the one picked, if it is still set up, or the default one.
    public func agent(in settings: AgentSettings) -> AgentConnection? { settings.agent(id: agentID) ?? settings.current }
}

/// What the bar shows during a talk.
public struct TalkBar: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Starting the agent, its session and the voice.
        case connecting
        /// Waiting for you to talk.
        case listening
        /// You are talking.
        case hearing
        /// Your turn is with the agent, which hasn't said anything yet.
        case thinking
        /// The agent's voice is playing.
        case speaking
    }

    public var agent: BarAgent
    public var phase: Phase
    /// Your words while you talk, or the piece of the reply the voice is saying.
    public var line: String
    /// What the agent is doing, such as "Checking your calendar", until it speaks.
    public var activity: String?
    /// No one has talked for a while, and the talk ends soon.
    public var endingSoon: Bool

    public init(agent: BarAgent, phase: Phase, line: String = "", activity: String? = nil, endingSoon: Bool = false) {
        (self.agent, self.phase, self.line, self.activity, self.endingSoon) = (agent, phase, line, activity, endingSoon)
    }

    /// Who the glow follows.
    public var speaker: TalkGlow.Speaker {
        switch phase {
        case .hearing: .you
        case .speaking: .agent
        case .connecting, .listening, .thinking: .nobody
        }
    }

    /// The words the bar prints in white, or nil when it shows a status instead.
    public var words: String? {
        switch phase {
        case .hearing, .speaking: line.isEmpty ? nil : line
        case .connecting, .listening, .thinking: nil
        }
    }

    /// The status in grey when there are no words to show.
    public var status: String {
        if let activity, phase == .thinking || phase == .speaking && line.isEmpty { return activity }
        return switch phase {
        case .connecting: "Connecting to \(agent.name)…"
        case .listening: endingSoon ? "Still there? Ending soon" : "Listening"
        case .hearing: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "\(agent.name) is talking"
        }
    }
}

/// The glow around the bar in a talk. It is the dictation glow's rim, halo and beam, made to read differently: the light
/// breathes slowly, your turn is teal with the beam running clockwise at dictation's speed, the agent's turn is violet
/// with the beam running the other way, and while no one talks the beam slows to a dim drift. Neither color is
/// dictation's blue, so a talk never looks like a dictation.
public enum TalkGlow {
    public enum Speaker: Equatable, Sendable { case you, agent, nobody }

    /// One slow breath, in seconds.
    public static let breathPeriod = 4.8
    public static let yourRimColors: [HaloGlow.RGB] = [rgb(0x134E4A), rgb(0x0D9488), rgb(0x5EEAD4), rgb(0x14B8A6), rgb(0x115E59)]
    public static let yourBeamTail = rgb(0x0D9488)
    public static let yourBeamHead = rgb(0xCCFBF1)
    public static let agentRimColors: [HaloGlow.RGB] = [rgb(0x3B0764), rgb(0x7C3AED), rgb(0xC4B5FD), rgb(0x8B5CF6), rgb(0x4C1D95)]
    public static let agentBeamTail = rgb(0x7C3AED)
    public static let agentBeamHead = rgb(0xF3E8FF)

    /// 0 to 1 and back over one breath, starting at the bottom.
    public static func breath(at time: Double) -> Double { 0.5 - 0.5 * cos(2 * .pi * time / breathPeriod) }

    /// How lit the glow is: a resting breath, raised by the voice of whoever is talking.
    public static func light(breath: Double, voice: Double, speaker: Speaker) -> Double {
        let resting = 0.08 + 0.36 * breath
        guard speaker != .nobody else { return resting }
        return resting + (1 - resting) * min(max(voice, 0), 1)
    }

    /// The beam's speed along the rim, in points a second: dictation's while you talk, backward for the agent, and a slow
    /// drift while no one talks.
    public static func beamSpeed(_ speaker: Speaker) -> Double {
        switch speaker {
        case .you: HaloGlow.speed
        case .agent: -HaloGlow.speed * 0.8
        case .nobody: 70
        }
    }

    /// The share of the beam's light that shows: dimmer while no one talks.
    public static func beamOpacity(_ speaker: Speaker) -> Double { speaker == .nobody ? 0.45 : 1 }

    /// The rim's colors `mix` of the way from yours, 0, to the agent's, 1.
    public static func rimColors(mix: Double) -> [HaloGlow.RGB] {
        zip(yourRimColors, agentRimColors).map { blend($0, $1, mix) }
    }

    public static func beamColor(along: Double, mix: Double) -> HaloGlow.RGB {
        let k = min(max(along, 0), 1)
        let tail = blend(yourBeamTail, agentBeamTail, mix), head = blend(yourBeamHead, agentBeamHead, mix)
        return blend(tail, head, k)
    }

    /// Which way the colors lean for a speaker: yours, the agent's, or between while no one talks, leaning to whoever
    /// spoke last.
    public static func mix(for speaker: Speaker, last: Speaker) -> Double {
        switch speaker {
        case .you: 0
        case .agent: 1
        case .nobody: last == .agent ? 0.7 : 0.3
        }
    }

    /// Where the beam's head is, carried forward from frame to frame so a change of speed never makes it jump.
    public struct BeamClock: Equatable, Sendable {
        public private(set) var head = 0.0
        private var last: Double?
        public private(set) var speed = 0.0

        public init() {}

        /// Moves the head on to `time`, easing the speed toward `target` over about a third of a second.
        public mutating func advance(to time: Double, target: Double) -> Double {
            defer { last = time }
            guard let last else {
                speed = target
                return head
            }
            let step = min(max(time - last, 0), 0.1)
            speed += (target - speed) * (1 - exp(-step / 0.3))
            head += speed * step
            return head
        }
    }

    /// The beam with its head `head` points along the rim, any distance, either way.
    public static func beam(head: Double, perimeter: Double, backward: Bool) -> [HaloGlow.Slice] {
        guard perimeter > 0 else { return [] }
        // Running backward, the beam is the forward one in a mirrored rim, so its tail trails on the other side.
        let position = backward ? -head : head
        let slices = HaloGlow.beam(at: wrapped(position, perimeter) / HaloGlow.speed, perimeter: perimeter)
        guard backward else { return slices }
        return slices.map { HaloGlow.Slice(from: 1 - $0.to, to: 1 - $0.from, along: $0.along, light: $0.light) }
    }

    private static func wrapped(_ value: Double, _ period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }

    static func blend(_ a: HaloGlow.RGB, _ b: HaloGlow.RGB, _ k: Double) -> HaloGlow.RGB {
        let k = min(max(k, 0), 1)
        return (a.red + (b.red - a.red) * k, a.green + (b.green - a.green) * k, a.blue + (b.blue - a.blue) * k)
    }

    private static func rgb(_ hex: Int) -> HaloGlow.RGB {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
