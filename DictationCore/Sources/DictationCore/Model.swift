/// One dictation's audio: 16 kHz mono, in memory only. Nothing in the app writes it to disk.
public struct Recording: Sendable {
    public static let sampleRate = 16_000.0
    public var samples: [Float]
    /// Key-up, or the press that stopped hands-free. Latency counts from here.
    public var releasedAt: Instant

    public init(samples: [Float], releasedAt: Instant) {
        self.samples = samples
        self.releasedAt = releasedAt
    }

    public var seconds: Double { Double(samples.count) / Self.sampleRate }
}

/// One piece of the speech model's output and when it was heard, in seconds from the start of the audio.
public struct TimedToken: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { (self.text, self.start, self.end) = (text, start, end) }
}

public struct Dictation: Equatable, Sendable {
    /// The only thing inserted.
    public var text: String
    public var raw: String
    /// Nil when vocabulary is off or the rescorer changed nothing.
    public var boosted: String?
    /// Release until the worker started the job. Long only behind a model load.
    public var waited: Double
    public var decode: Double
    public var rescore: Double
    public var finish: Double
    /// Names from the screen boosted on top of the vocabulary.
    public var screenTerms: Int
    /// The decoder's pieces of `raw`, with their times. Empty when the model gave none.
    public var tokens: [TimedToken]

    public init(text: String, raw: String, boosted: String?, waited: Double, decode: Double, rescore: Double,
                finish: Double, screenTerms: Int = 0, tokens: [TimedToken] = []) {
        (self.text, self.raw, self.boosted) = (text, raw, boosted)
        (self.waited, self.decode, self.rescore, self.finish) = (waited, decode, rescore, finish)
        self.screenTerms = screenTerms
        self.tokens = tokens
    }
}

public enum LoadPhase: Equatable, Sendable {
    case downloading(fraction: Double)
    /// Silent during each blocking CoreML compile, about 41 s on the first launch.
    case compiling
    /// The CTC model behind vocabulary boosting. FluidAudio reports no progress for it.
    case preparingVocabulary
}

public enum EngineStatus: Equatable, Sendable {
    case loading(LoadPhase)
    case ready(boosting: Boosting)
    /// Queued dictations stay in memory until Retry succeeds.
    case failed(String)

    public enum Boosting: Equatable, Sendable { case on(terms: Int), off, unavailable(String) }
}

public enum BarEdge: String, CaseIterable, Codable, Sendable {
    case bottom, top, left, right

    /// On a side edge the idle pill stands upright.
    public var isSide: Bool { self == .left || self == .right }

    /// Where a body of this size sits in `area`, `inset` points in from this edge. Along the top and bottom it is
    /// centered. On a side it is vertically centered and flush with that side, so it grows away from it.
    public func place(width: Double, height: Double, in area: BarRect, inset: Double) -> BarRect {
        let centeredX = (area.midX - width / 2).rounded(), centeredY = (area.midY - height / 2).rounded()
        return switch self {
        case .bottom: BarRect(x: centeredX, y: area.minY + inset, width: width, height: height)
        case .top: BarRect(x: centeredX, y: area.maxY - inset - height, width: width, height: height)
        case .left: BarRect(x: area.minX + inset, y: centeredY, width: width, height: height)
        case .right: BarRect(x: area.maxX - inset - width, y: centeredY, width: width, height: height)
        }
    }

    /// A toast attached to `body`: above it, or below it on the top edge, aligned the way the body is.
    public func placeToast(width: Double, height: Double, against body: BarRect, gap: Double) -> BarRect {
        let x = switch self {
        case .left: body.minX
        case .right: body.maxX - width
        case .top, .bottom: (body.midX - width / 2).rounded()
        }
        return BarRect(x: x, y: self == .top ? body.minY - gap - height : body.maxY + gap, width: width, height: height)
    }

    /// The edge whose snap spot, the middle of that edge of `area`, is nearest to the point.
    public static func nearest(x: Double, y: Double, in area: BarRect) -> BarEdge {
        allCases.min { a, b in a.distanceSquared(x: x, y: y, in: area) < b.distanceSquared(x: x, y: y, in: area) }!
    }

    private func distanceSquared(x: Double, y: Double, in area: BarRect) -> Double {
        let spot = switch self {
        case .bottom: (area.midX, area.minY)
        case .top: (area.midX, area.maxY)
        case .left: (area.minX, area.midY)
        case .right: (area.maxX, area.midY)
        }
        return (x - spot.0) * (x - spot.0) + (y - spot.1) * (y - spot.1)
    }
}

/// A rectangle in screen points with the origin at the bottom left, as AppKit has it. DictationCore stays free of
/// CoreGraphics, so it has its own.
public struct BarRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Moved, not resized, to lie inside `area` as far as it fits.
    public func moved(into area: BarRect) -> BarRect {
        BarRect(x: min(max(x, area.minX), area.maxX - width), y: min(max(y, area.minY), area.maxY - height),
                width: width, height: height)
    }
}

public enum MicrophoneChoice: Equatable, Codable, Sendable {
    case systemDefault
    /// A CoreAudio device UID, which survives unplugging and reboots. The name is for display while it is absent.
    case device(uid: String, name: String)

    /// Where to capture from, given the UIDs of the inputs connected now.
    public func source(connected: [String]) -> MicrophoneSource {
        switch self {
        case .systemDefault: .systemDefault
        case .device(let uid, let name): connected.contains(uid) ? .device(uid: uid) : .fallback(missing: name)
        }
    }
}

public enum MicrophoneSource: Equatable, Sendable {
    case systemDefault
    case device(uid: String)
    /// The chosen device is not connected, so capture uses the system default.
    case fallback(missing: String)
}

/// An unplugged chosen microphone is mentioned once, then again only after it was seen connected or the choice
/// changed. Only a mention that showed counts, so a fn chord that ends before the bar does not use it up.
public struct MissingMicrophone: Sendable {
    private var shown: String?

    public init() {}

    /// The missing device to mention for a capture's source, if any.
    public mutating func toMention(for source: MicrophoneSource) -> String? {
        guard case .fallback(let missing) = source else {
            shown = nil
            return nil
        }
        return missing == shown ? nil : missing
    }

    public mutating func didMention(_ missing: String) { shown = missing }
}

/// Every switch the user sets, stored in UserDefaults as one JSON value. Keys missing from the stored value take
/// the defaults below, so a setting added later needs no migration.
public struct Settings: Equatable, Codable, Sendable {
    /// The keys held to dictate. Never empty, and no two alike.
    public var hotkeys: [Shortcut] = [.fn, .rightControl]
    /// Pastes the last dictation again. Nil turns it off.
    public var pasteLast: Shortcut? = .pasteLast
    public var vocabularyEnabled = true
    public var microphone = MicrophoneChoice.systemDefault
    public var sounds = true
    public var barEdge = BarEdge.bottom
    public var hideBarWhenIdle = true
    public var keepHistory = true
    public var showMenuBarIcon = true
    /// Adds a space before inserted text that follows a word, and lowercases its first word mid-sentence.
    public var smartSpacing = true
    /// The style and Return rule for each group of apps, picked by the app in front at release.
    public var profiles = AppProfiles.defaults
    public var snippets: [Snippet] = []
    /// Mutes the Mac's sound while you talk, once the start cue has played.
    public var muteWhileDictating = false
    /// Boosts names read from the front window at key-down, for that dictation only.
    public var screenNames = true
    /// Adds a word to the dictionary when the user corrects one word of a dictation.
    public var learnFixes = true
    /// Adds paragraphs, lists and quotes with the formatting model, when it is installed.
    public var smartFormatting = true
    /// Held, the agent writes a draft from what you say. Nil turns Ghostwrite off.
    public var ghostwriteKey: Shortcut? = Shortcut(key: 63, modifiers: [.control])
    /// Held, what you say goes to the agent's own app as a task. Nil turns Hand off off.
    public var handOffKey: Shortcut? = Shortcut(key: 63, modifiers: [.option])
    public var agents = AgentSettings()
    /// Sends one anonymous report a day, the first time you use the app. See the README's Privacy section.
    public var sendUsageCount = true
    /// Asks GitHub once a day for the newest release and says so when it is newer. It installs nothing.
    public var checkForUpdates = true

    public init() {}

    /// The Ghostwrite and Hand off keys do nothing until an agent is set up, so they stay ordinary keys until then.
    public var captureKeys: CaptureKeys {
        let live = !agents.agents.isEmpty
        return CaptureKeys(dictation: hotkeys, ghostwrite: live ? ghostwriteKey : nil, handOff: live ? handOffKey : nil)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        /// One element that does not read drops only itself.
        func elements<T: Decodable>(_ key: CodingKeys, _ fallback: [T]) -> [T] {
            (try? container.decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements ?? fallback
        }
        let hotkeys = elements(.hotkeys, defaults.hotkeys).reduce(into: [Shortcut]()) { if !$0.contains($1) { $0.append($1) } }
        self.hotkeys = hotkeys.isEmpty ? defaults.hotkeys : hotkeys
        // Present and null means the user turned it off. Absent means a value stored before the setting existed.
        pasteLast = container.contains(.pasteLast) ? value(.pasteLast, Shortcut?.none) : defaults.pasteLast
        vocabularyEnabled = value(.vocabularyEnabled, defaults.vocabularyEnabled)
        microphone = value(.microphone, defaults.microphone)
        sounds = value(.sounds, defaults.sounds)
        barEdge = value(.barEdge, defaults.barEdge)
        hideBarWhenIdle = value(.hideBarWhenIdle, defaults.hideBarWhenIdle)
        keepHistory = value(.keepHistory, defaults.keepHistory)
        showMenuBarIcon = value(.showMenuBarIcon, defaults.showMenuBarIcon)
        smartSpacing = value(.smartSpacing, defaults.smartSpacing)
        profiles = value(.profiles, defaults.profiles)
        snippets = elements(.snippets, defaults.snippets)
        muteWhileDictating = value(.muteWhileDictating, defaults.muteWhileDictating)
        screenNames = value(.screenNames, defaults.screenNames)
        learnFixes = value(.learnFixes, defaults.learnFixes)
        smartFormatting = value(.smartFormatting, defaults.smartFormatting)
        // A dictation key saved before the agent keys existed may be one of their defaults. It stays a dictation key.
        ghostwriteKey = (container.contains(.ghostwriteKey) ? value(.ghostwriteKey, Shortcut?.none) : defaults.ghostwriteKey)
            .flatMap { hotkeys.contains($0) ? nil : $0 }
        handOffKey = (container.contains(.handOffKey) ? value(.handOffKey, Shortcut?.none) : defaults.handOffKey)
            .flatMap { hotkeys.contains($0) ? nil : $0 }
        agents = value(.agents, defaults.agents)
        sendUsageCount = value(.sendUsageCount, defaults.sendUsageCount)
        checkForUpdates = value(.checkForUpdates, defaults.checkForUpdates)
    }

    private enum CodingKeys: String, CodingKey {
        case hotkeys, pasteLast, vocabularyEnabled, microphone, sounds, barEdge, hideBarWhenIdle, keepHistory, showMenuBarIcon
        case smartSpacing, profiles, snippets, muteWhileDictating, screenNames, learnFixes, smartFormatting, ghostwriteKey, handOffKey, agents
        case sendUsageCount, checkForUpdates
    }

    /// Written out by hand so a paste shortcut turned off is stored as null. The synthesized encoder leaves a nil out,
    /// and the default would come back.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkeys, forKey: .hotkeys)
        try container.encode(pasteLast, forKey: .pasteLast)
        try container.encode(vocabularyEnabled, forKey: .vocabularyEnabled)
        try container.encode(microphone, forKey: .microphone)
        try container.encode(sounds, forKey: .sounds)
        try container.encode(barEdge, forKey: .barEdge)
        try container.encode(hideBarWhenIdle, forKey: .hideBarWhenIdle)
        try container.encode(keepHistory, forKey: .keepHistory)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(smartSpacing, forKey: .smartSpacing)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(snippets, forKey: .snippets)
        try container.encode(muteWhileDictating, forKey: .muteWhileDictating)
        try container.encode(screenNames, forKey: .screenNames)
        try container.encode(learnFixes, forKey: .learnFixes)
        try container.encode(smartFormatting, forKey: .smartFormatting)
        try container.encode(ghostwriteKey, forKey: .ghostwriteKey)
        try container.encode(handOffKey, forKey: .handOffKey)
        try container.encode(agents, forKey: .agents)
        try container.encode(sendUsageCount, forKey: .sendUsageCount)
        try container.encode(checkForUpdates, forKey: .checkForUpdates)
    }

    /// Adds a dictation key, or puts it in place of `replacing`. Why it can't, or nil when it did.
    public mutating func setHotkey(_ shortcut: Shortcut, replacing old: Shortcut? = nil) -> String? {
        if let problem = shortcut.problem { return problem }
        if shortcut == pasteLast { return "\(shortcut.title) already pastes your last dictation." }
        if shortcut != old, hotkeys.contains(shortcut) { return "\(shortcut.title) is already a dictation key." }
        if let use = agentKeyUse(shortcut) { return "\(shortcut.title) is already \(use)." }
        if let old, let index = hotkeys.firstIndex(of: old) { hotkeys[index] = shortcut } else { hotkeys.append(shortcut) }
        return nil
    }

    private func agentKeyUse(_ shortcut: Shortcut) -> String? {
        if shortcut == ghostwriteKey { return "the Ghostwrite key" }
        if shortcut == handOffKey { return "the Hand off key" }
        return nil
    }

    /// Sets the Ghostwrite or Hand off key. Why it can't, or nil when it did. Nil turns that key off.
    public mutating func setAgentKey(_ kind: CaptureKind, _ shortcut: Shortcut?) -> String? {
        if let shortcut {
            if let problem = shortcut.problem { return problem }
            if hotkeys.contains(shortcut) { return "\(shortcut.title) is already a dictation key." }
            if shortcut == pasteLast { return "\(shortcut.title) already pastes your last dictation." }
            if kind == .ghostwrite, shortcut == handOffKey { return "\(shortcut.title) is already the Hand off key." }
            if kind == .handOff, shortcut == ghostwriteKey { return "\(shortcut.title) is already the Ghostwrite key." }
        }
        switch kind {
        case .ghostwrite: ghostwriteKey = shortcut
        case .handOff: handOffKey = shortcut
        case .dictate: break
        }
        return nil
    }

    /// Removing the last dictation key is refused, so the app can always be reached by voice.
    public mutating func removeHotkey(_ shortcut: Shortcut) {
        guard hotkeys.count > 1 else { return }
        hotkeys.removeAll { $0 == shortcut }
    }

    /// Why the paste shortcut can't be this, or nil when it is set. Nil turns it off.
    public mutating func setPasteLast(_ shortcut: Shortcut?) -> String? {
        if let shortcut {
            if let problem = shortcut.problem { return problem }
            if shortcut.isModifierKey { return "Pasting needs a key with modifiers, such as ⌃⌘V." }
            if hotkeys.contains(shortcut) { return "\(shortcut.title) is already a dictation key." }
            if let use = agentKeyUse(shortcut) { return "\(shortcut.title) is already \(use)." }
        }
        pasteLast = shortcut
        return nil
    }
}

/// Everything the user configured: the settings from UserDefaults, and the terms, their aliases, and the
/// similarity from the vocabulary file.
public struct Configuration: Equatable, Sendable {
    public var settings: Settings
    public var vocabulary: Vocabulary
    public var issues: [Vocabulary.Issue]

    public init(settings: Settings, vocabulary: Vocabulary, issues: [Vocabulary.Issue]) {
        (self.settings, self.vocabulary, self.issues) = (settings, vocabulary, issues)
    }

    public var activeVocabulary: Vocabulary? { settings.vocabularyEnabled ? vocabulary : nil }
}

/// What a toast on the bar says. The Coordinator owns the current one.
public enum BarNotice: Equatable, Sendable {
    /// Insertion could not happen. The text is on the clipboard.
    case copied(CopyReason)
    case failed(String)
    /// The chosen microphone is not connected, so capture uses the system default.
    case microphoneMissing(chosen: String, using: String)
    /// Paste Last Transcript before anything was dictated.
    case nothingToPaste
    /// A dictation waits on a model that failed to load.
    case modelFailed(String)
    /// fn is a dictation key, but Keyboard > Press fn key to is not Do Nothing, so macOS also acts on it.
    case fnKeySetting
    /// A word learned from the user's fix went into the dictionary.
    case learned(String)
    /// The user's own agent changed the setup through `Dictation setup apply`.
    case setupApplied(by: String, changes: Int)

    public var title: String {
        switch self {
        case .copied: "Copied. Press ⌘V to paste."
        case .failed(let message): message
        case .microphoneMissing(let chosen, _): "\(chosen) isn't connected"
        case .nothingToPaste: "Nothing to paste yet"
        case .modelFailed: "The speech model didn't load"
        case .fnKeySetting: "macOS also acts on fn"
        case .learned(let word): "Learned \(word)"
        case .setupApplied(let by, _): "\(by) set up Lip Service"
        }
    }

    /// The second line: why, or what happens next.
    public var detail: String? {
        switch self {
        case .copied(let reason): reason.explanation
        case .failed: nil
        case .microphoneMissing(_, let using): "Using \(using) until it's back."
        case .nothingToPaste: "Dictate something first."
        case .modelFailed(let reason): reason
        case .fnKeySetting: "Set Keyboard > Press fn key to > Do Nothing."
        case .learned: "Added to your dictionary from your fix."
        case .setupApplied(_, let changes): changes == 1 ? "1 change. Open Lip Service to see it." : "\(changes) changes. Open Lip Service to see them."
        }
    }

    /// Starting the next dictation clears a notice, except one this kind. A word is learned at the start of the next
    /// dictation, so its notice must outlast that start to be seen at all.
    public var outlastsNextDictation: Bool {
        if case .learned = self { true } else { false }
    }

    public var tone: NoticeTone {
        switch self {
        case .copied, .nothingToPaste, .learned, .setupApplied: .info
        case .microphoneMissing, .fnKeySetting: .warning
        case .failed, .modelFailed: .failure
        }
    }

    /// The toast's one button, when it has one.
    public var action: BarToastAction? {
        switch self {
        case .modelFailed: .retryModel
        case .fnKeySetting: .openKeyboardSettings
        case .learned: .undoLearned
        case .setupApplied: .undoSetup
        default: nil
        }
    }
}

/// The color of a notice's icon: green for information, amber for something degraded, red for a failure.
public enum NoticeTone: Equatable, Sendable { case info, warning, failure }

extension CopyReason {
    var explanation: String {
        switch self {
        case .notTrusted: "Turn on Accessibility for Lip Service to paste at the cursor."
        case .secureInput: "A password field doesn't allow pasting."
        case .focusMoved: "Focus moved before your words were ready."
        case .waitedTooLong: "Your words took more than 10 seconds."
        case .keystrokeFailed: "The paste keystroke didn't go through."
        case .noTextField: "There was no text box where you started."
        }
    }
}

public enum BarToastAction: Equatable, Sendable {
    case retryModel
    case openKeyboardSettings
    case undoLearned
    case undoSetup

    public var title: String {
        switch self {
        case .retryModel: "Retry"
        case .openKeyboardSettings: "Open Settings"
        case .undoLearned, .undoSetup: "Undo"
        }
    }
}

/// What the bar shows: a body at the chosen edge and, attached to it, an optional toast.
public struct BarState: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case hidden
        /// The small pill that stays when the bar is not hidden while idle.
        case idle
        /// `words` is the live preview, empty until the first one arrives.
        case listening(words: String, handsFree: Bool)
        /// Released. The last words stay, dimmed, until the text is inserted. `waitingOn` is set while the
        /// dictation waits for the model.
        case transcribing(words: String, waitingOn: LoadPhase?)
        case preparing(LoadPhase)
        /// The agent is on it: "Hermes is writing…", "Ready". `busy` while something is under way rather than waiting
        /// on the user, and only then does the print move.
        case working(status: String, busy: Bool)
    }

    public var body: Body
    public var toast: BarNotice?
    /// Who a Ghostwrite or Hand off capture is for, shown on the bar beside the print.
    public var agent: BarAgent?

    public init(body: Body, toast: BarNotice? = nil, agent: BarAgent? = nil) {
        self.body = body
        self.toast = toast
        self.agent = agent
    }

    /// Listening wins, then dictations in flight, then model loading, then idle. A dictation stuck behind a
    /// failed model is a toast with Retry, which outranks any other notice.
    /// `agent` is set while a Ghostwrite or Hand off capture runs, and `working` while the agent is on it.
    public static func derive(hotkey: HotkeyMachine, words: String, pending: Int, engine: EngineStatus,
                              notice: BarNotice?, showsIdle: Bool, agent: BarAgent? = nil, working: String? = nil,
                              busy: Bool = false) -> BarState {
        let body: Body
        if hotkey.showsListening {
            body = .listening(words: words, handsFree: hotkey.isHandsFree)
        } else if let working {
            body = .working(status: working, busy: busy)
        } else if pending > 0, case .loading(let phase) = engine {
            body = .transcribing(words: words, waitingOn: phase)
        } else if pending > 0, case .ready = engine {
            body = .transcribing(words: words, waitingOn: nil)
        } else if case .loading(let phase) = engine {
            body = .preparing(phase)
        } else {
            body = showsIdle ? .idle : .hidden
        }
        if pending > 0, case .failed(let reason) = engine { return BarState(body: body, toast: .modelFailed(reason), agent: agent) }
        return BarState(body: body, toast: notice, agent: agent)
    }
}

/// The agent's round mark and name, as the bar and the card show them.
public struct BarAgent: Equatable, Sendable {
    public var initial: String
    public var name: String
    public init(initial: String, name: String) { (self.initial, self.name) = (initial, name) }
}
