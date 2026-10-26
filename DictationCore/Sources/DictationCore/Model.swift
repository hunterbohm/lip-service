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

    public init(text: String, raw: String, boosted: String?, waited: Double, decode: Double, rescore: Double,
                finish: Double) {
        (self.text, self.raw, self.boosted) = (text, raw, boosted)
        (self.waited, self.decode, self.rescore, self.finish) = (waited, decode, rescore, finish)
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
/// the defaults below, so a setting added later needs no migration. The defaults match Hunter's Willow setup.
public struct Settings: Equatable, Codable, Sendable {
    /// Never empty. Kept in `HotkeyChoice.allCases` order.
    public var hotkeys: [HotkeyChoice] = [.fn, .rightControl]
    public var vocabularyEnabled = true
    public var microphone = MicrophoneChoice.systemDefault
    public var sounds = true
    public var barEdge = BarEdge.bottom
    public var hideBarWhenIdle = true
    public var keepHistory = true
    public var showMenuBarIcon = true
    /// Adds a space before inserted text that follows a word, and lowercases its first word mid-sentence.
    public var smartSpacing = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let hotkeys = value(.hotkeys, defaults.hotkeys)
        self.hotkeys = hotkeys.isEmpty ? defaults.hotkeys : HotkeyChoice.allCases.filter(hotkeys.contains)
        vocabularyEnabled = value(.vocabularyEnabled, defaults.vocabularyEnabled)
        microphone = value(.microphone, defaults.microphone)
        sounds = value(.sounds, defaults.sounds)
        barEdge = value(.barEdge, defaults.barEdge)
        hideBarWhenIdle = value(.hideBarWhenIdle, defaults.hideBarWhenIdle)
        keepHistory = value(.keepHistory, defaults.keepHistory)
        showMenuBarIcon = value(.showMenuBarIcon, defaults.showMenuBarIcon)
        smartSpacing = value(.smartSpacing, defaults.smartSpacing)
    }

    /// Turning off the last hotkey is refused, so the app can always be reached by voice.
    public mutating func setHotkey(_ choice: HotkeyChoice, on: Bool) {
        let next = on ? hotkeys + [choice] : hotkeys.filter { $0 != choice }
        guard !next.isEmpty else { return }
        hotkeys = HotkeyChoice.allCases.filter(next.contains)
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

    public var title: String {
        switch self {
        case .copied: "Copied. Press ⌘V to paste."
        case .failed(let message): message
        case .microphoneMissing(let chosen, _): "\(chosen) isn't connected"
        case .nothingToPaste: "Nothing to paste yet"
        case .modelFailed: "The speech model didn't load"
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
        }
    }

    public var tone: NoticeTone {
        switch self {
        case .copied, .nothingToPaste: .info
        case .microphoneMissing: .warning
        case .failed, .modelFailed: .failure
        }
    }

    /// The toast's one button, when it has one.
    public var action: BarToastAction? {
        if case .modelFailed = self { .retryModel } else { nil }
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
        }
    }
}

public enum BarToastAction: Equatable, Sendable {
    case retryModel

    public var title: String { "Retry" }
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
    }

    public var body: Body
    public var toast: BarNotice?

    public init(body: Body, toast: BarNotice? = nil) {
        self.body = body
        self.toast = toast
    }

    /// Listening wins, then dictations in flight, then model loading, then idle. A dictation stuck behind a
    /// failed model is a toast with Retry, which outranks any other notice.
    public static func derive(hotkey: HotkeyMachine, words: String, pending: Int, engine: EngineStatus,
                              notice: BarNotice?, showsIdle: Bool) -> BarState {
        let body: Body
        if hotkey.showsListening {
            body = .listening(words: words, handsFree: hotkey.isHandsFree)
        } else if pending > 0, case .loading(let phase) = engine {
            body = .transcribing(words: words, waitingOn: phase)
        } else if pending > 0, case .ready = engine {
            body = .transcribing(words: words, waitingOn: nil)
        } else if case .loading(let phase) = engine {
            body = .preparing(phase)
        } else {
            body = showsIdle ? .idle : .hidden
        }
        if pending > 0, case .failed(let reason) = engine { return BarState(body: body, toast: .modelFailed(reason)) }
        return BarState(body: body, toast: notice)
    }
}
