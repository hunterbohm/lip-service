import Foundation

/// A voice on this Mac, run by FluidAudio: which of its speech models, and which of that model's voices.
public struct OnMacVoice: Equatable, Hashable, Codable, Sendable, Identifiable {
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// Kokoro 82M, on the Neural Engine.
        case kokoro
        /// PocketTTS small with Gradium's Phonon 31M English voices, from FluidAudio 0.18.3. Its pack is pinned and checked
        /// like the speech models.
        case phonon
    }

    public var model: Model
    public var voice: String

    public init(model: Model, voice: String) { (self.model, self.voice) = (model, voice) }

    public var id: String { "\(model.rawValue):\(voice)" }

    /// Phonon's American male voice Preston, Hunter's pick.
    public static let preston = OnMacVoice(model: .phonon, voice: "en_us_Preston")
    /// Kokoro's American male voice.
    public static let michael = OnMacVoice(model: .kokoro, voice: "am_michael")
    public static let standard = preston

    /// Phonon's voices in the pinned pack. scripts/pin-models.py lists the same ones, and only these are downloaded.
    public static let phononVoices: [OnMacVoice] = ["en_us_Preston", "en_us_Easton", "en_us_Miles", "en_us_Harper", "en_us_Zoey",
                                                     "en_gb_Hugh", "en_gb_Freya"].map { OnMacVoice(model: .phonon, voice: $0) }

    /// The voices the settings offer. Any other Kokoro voice works too, set through `setup apply` or by hand.
    public static let offered: [OnMacVoice] = phononVoices + [
        michael, OnMacVoice(model: .kokoro, voice: "am_adam"), OnMacVoice(model: .kokoro, voice: "am_eric"),
        OnMacVoice(model: .kokoro, voice: "af_heart"), OnMacVoice(model: .kokoro, voice: "af_bella"),
        OnMacVoice(model: .kokoro, voice: "bm_george"), OnMacVoice(model: .kokoro, voice: "bf_emma"),
    ]

    /// "Preston (American, Phonon)", "Michael (American, Kokoro)".
    public var title: String {
        switch model {
        case .kokoro:
            let parts = voice.split(separator: "_", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 2 else { return voice }
            let accent = parts[0].first == "b" ? "British" : "American"
            return "\(parts[1].capitalized) (\(accent), Kokoro)"
        case .phonon:
            let parts = voice.split(separator: "_", maxSplits: 2)
            guard parts.count == 3, parts[0] == "en" else { return voice }
            let accent = parts[1] == "gb" ? "British" : "American"
            return "\(parts[2]) (\(accent), Phonon)"
        }
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

/// What the island at the top of the screen shows during a talk.
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

    /// What is happening, in a few words.
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
