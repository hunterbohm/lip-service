import Foundation

/// The keys the card takes while the app the user started in is still in front. Any other key reaches that app.
public enum CardKey: Equatable, Sendable {
    case returnKey, escape, number(Int), up, down, delete, character(Character)

    /// Return, Escape, the arrows and Delete with no modifier held, or one printable character typed with no Command,
    /// Control or Option. `characters` is read only for a key that could be a character.
    public init?(keyCode: Int, flags: UInt64, characters: () -> String?) {
        let held = Modifiers(flags: flags)
        guard held.isDisjoint(with: [.command, .control, .option]) else { return nil }
        if let key = Self.named[keyCode] {
            guard !held.contains(.shift) else { return nil }
            self = key
            return
        }
        // Function and arrow keys type characters from the private use area, and Tab is a control character.
        guard let typed = characters(), typed.count == 1, let character = typed.first,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        if let digit = character.wholeNumberValue, (1...9).contains(digit) { self = .number(digit) } else { self = .character(character) }
    }

    private static let named: [Int: CardKey] = [36: .returnKey, 76: .returnKey, KeyInput.escapeKeyCode: .escape, 126: .up, 125: .down, 51: .delete]
}

/// The agent question shown in the card, answered by its number or a click.
public struct PermissionPrompt: Equatable, Sendable {
    /// How long the question shows before a number key answers it, so a digit the user was typing into the app as it
    /// appeared does not answer it. A click answers at once.
    public static let readDelay = 0.8

    /// The agent's options with the "always" ones moved last, so 1 is never a standing approval.
    public var request: PermissionRequest
    public var answerableAt = Instant(seconds: 0)

    public init(_ request: PermissionRequest) {
        self.request = request
        self.request.options = request.options.enumerated()
            .sorted { ($0.element.kind.hasSuffix("_always") ? 1 : 0, $0.offset) < ($1.element.kind.hasSuffix("_always") ? 1 : 0, $1.offset) }
            .map(\.element)
    }
}

/// The draft card. Listening, transcribing and thinking show on the bar; the card itself opens with the first words
/// of the draft, or earlier for a question or a failure.
///
///     phase                     event                         next                    effects
///     ready, streaming          listen                        listening(over: draft)
///     listening, transcribing   chunk, finished               the draft under it moves on
///     listening                 released                      transcribing(over)
///     listening, transcribing   cancelled                     back to the draft, or discarded
///     transcribing              heard(words)                  thinking(draft)         send(words)
///     transcribing              heard("")                     back to the draft, or discarded
///     thinking, streaming       chunk                         streaming(text so far)
///     thinking, streaming       finished                      ready(cleaned)          paste, when Type directly
///     thinking, streaming       asked(question)               permission
///     permission                number or click               back to where it was    answer(option)
///     thinking .. permission    failed(reason)                failed(reason, words)
///     failed                    retry                         thinking                send(words)
///     failed                    copy                          copied                  copy(words)
///     ready                     return                        typed                   type(text)
///     (any open)                escape                        discarded               cancel
///
/// A key event the card does not `take` changes nothing.
public struct DraftCard: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The key is held: for the first request, or for a change spoken over the draft, which keeps streaming in.
        indirect case listening(over: Phase?)
        indirect case transcribing(over: Phase?)
        case thinking(draft: String?)
        case streaming(String)
        case ready(String)
        indirect case permission(PermissionPrompt, resume: Phase)
        case failed(String)
        case typed, copied, discarded
    }

    public enum Event: Equatable, Sendable {
        case listen, released, heard(String), chunk(String), finished, asked(PermissionPrompt), answered(String?)
        case failed(String), retry, copy, key(CardKey), cancelled
    }

    public enum Effect: Equatable, Sendable {
        /// A new request on the first send, a change in the same session after that.
        case send(words: String, isChange: Bool)
        case answer(PermissionRequest, optionID: String?)
        case type(String)
        case copy(String)
        case cancel
    }

    public var phase: Phase
    /// Every request said so far, the first one first. Kept through a failure, for Copy and Retry.
    public var requests: [String] = []
    public var typesDirectly: Bool
    private var reply = ""

    public init(typesDirectly: Bool) {
        phase = .listening(over: nil)
        self.typesDirectly = typesDirectly
    }

    public var isOpen: Bool {
        switch phase {
        case .typed, .copied, .discarded: false
        default: true
        }
    }

    /// The card shows from the first draft text, a question or a failure. Before that the bar says it.
    public var showsCard: Bool {
        switch phase {
        case .listening(let over), .transcribing(let over): over != nil
        case .thinking(let draft): draft != nil
        case .streaming: !typesDirectly
        case .ready, .permission, .failed: true
        case .typed, .copied, .discarded: false
        }
    }

    /// The draft as the card shows it now.
    public var text: String? {
        switch phase {
        case .listening(let over), .transcribing(let over): over.flatMap { DraftCard(phase: $0).text }
        case .thinking(let draft): draft
        case .streaming(let text), .ready(let text): text
        case .permission(_, let resume): DraftCard(phase: resume).text
        default: nil
        }
    }

    /// Whether the request has words yet: a change said over a draft keeps the first request.
    public var words: String { requests.joined(separator: "\n") }

    /// Whether a capture key held now speaks a change to this draft: only while its text shows, ready or still
    /// streaming, and only with the app it was written for in front. Otherwise the key dictates as usual.
    public func takesChange(frontmost: Int32?, target: Int32?) -> Bool {
        guard let target, frontmost == target else { return false }
        return isChangeable
    }

    private var isChangeable: Bool {
        switch phase {
        case .ready: true
        case .streaming: !typesDirectly
        default: false
        }
    }

    /// Whether the card acts on this key now. Only these keys are kept from the app in front.
    public func takes(_ key: CardKey, at now: Instant) -> Bool {
        switch (phase, key) {
        case (_, .escape): isOpen
        case (.ready, .returnKey): true
        case (.failed, .returnKey): !requests.isEmpty
        case (.permission(let prompt, _), .number(let number)):
            prompt.request.options.indices.contains(number - 1) && now >= prompt.answerableAt
        default: false
        }
    }

    private init(phase: Phase) {
        self.phase = phase
        typesDirectly = false
    }

    public mutating func handle(_ event: Event, at now: Instant = .now) -> [Effect] {
        if case .key(let key) = event, !takes(key, at: now) { return [] }
        switch (phase, event) {
        case (_, .key(.escape)):
            if case .permission(let prompt, _) = phase {
                phase = .discarded
                return [.answer(prompt.request, optionID: prompt.request.rejection?.id), .cancel]
            }
            phase = .discarded
            return [.cancel]

        case (_, .listen) where isChangeable:
            phase = .listening(over: phase)
            return []
        // The draft underneath keeps going while a change is said over it, and what happens to it waits there: a
        // question it asks, or its failure, which the change then retries.
        case (.listening(let over?), .chunk), (.listening(let over?), .finished), (.listening(let over?), .asked),
             (.listening(let over?), .failed):
            phase = .listening(over: continuing(over, with: event, at: now))
            return []
        case (.transcribing(let over?), .chunk), (.transcribing(let over?), .finished), (.transcribing(let over?), .asked),
             (.transcribing(let over?), .failed):
            phase = .transcribing(over: continuing(over, with: event, at: now))
            return []
        case (.listening(let over), .released):
            phase = .transcribing(over: over)
            return []
        case (.listening(let over), .cancelled), (.transcribing(let over), .cancelled):
            phase = over ?? .discarded
            return []
        case (.transcribing(let over), .heard(let words)):
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else {
                phase = over ?? .discarded
                return []
            }
            requests.append(words)
            // A question still waiting under the change is declined, since the change replaces the turn that asked it.
            var effects: [Effect] = [], waiting = over
            while case .permission(let prompt, let resume) = waiting {
                effects.append(.answer(prompt.request, optionID: prompt.request.rejection?.id))
                waiting = resume
            }
            return effects + startThinking(draft: over.flatMap { DraftCard(phase: $0).text })

        case (.thinking, .chunk(let text)), (.streaming, .chunk(let text)):
            reply += text
            phase = .streaming(ReplyCleanup.clean(reply))
            return []
        case (.thinking, .finished), (.streaming, .finished):
            let cleaned = ReplyCleanup.clean(reply)
            guard !cleaned.isEmpty else {
                phase = .failed("The agent sent back nothing.")
                return []
            }
            guard typesDirectly else {
                phase = .ready(cleaned)
                return []
            }
            phase = .typed
            return [.type(cleaned)]

        // An agent can keep streaming while it asks: the text goes into the draft under the question.
        case (.permission(let prompt, let resume), .chunk), (.permission(let prompt, let resume), .finished):
            phase = .permission(prompt, resume: continuing(resume, with: event, at: now))
            return []
        case (.permission(let prompt, let resume), .key(.number(let number))):
            guard prompt.request.options.indices.contains(number - 1) else { return [] }
            phase = resume
            return [.answer(prompt.request, optionID: prompt.request.options[number - 1].id)]
        case (.permission(let prompt, let resume), .answered(let optionID)):
            phase = resume
            return [.answer(prompt.request, optionID: optionID)]
        case (_, .asked(var prompt)) where isOpen:
            prompt.answerableAt = now + PermissionPrompt.readDelay
            phase = .permission(prompt, resume: phase)
            return []

        case (_, .failed(let reason)) where isOpen:
            phase = .failed(reason)
            return []
        case (.failed, .retry), (.failed, .key(.returnKey)):
            guard !requests.isEmpty else { return [] }
            return startThinking(draft: nil, isChange: false)
        case (.failed, .copy):
            phase = .copied
            return [.copy(words)]

        case (.ready(let text), .key(.returnKey)):
            phase = .typed
            return [.type(text)]
        default:
            return []
        }
    }

    /// The draft a change is being spoken over keeps streaming in underneath it.
    private mutating func continuing(_ over: Phase, with event: Event, at now: Instant) -> Phase {
        var draft = self
        draft.phase = over
        _ = draft.handle(event, at: now)
        reply = draft.reply
        return draft.phase
    }

    private mutating func startThinking(draft: String?, isChange: Bool? = nil) -> [Effect] {
        reply = ""
        phase = .thinking(draft: draft)
        let change = isChange ?? (draft != nil && requests.count > 1)
        return [.send(words: change ? requests.last! : requests.joined(separator: "\n"), isChange: change)]
    }
}

/// The hand-off card: what it heard, where it goes, and a short countdown in which Esc stops it. Picking a T3 Code
/// project replaces the countdown, since picking is the confirmation.
public struct HandOffCard: Equatable, Sendable {
    public static let countdown = 5.0

    public struct Project: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var environment: String?
        public var environmentName: String?
        public var updatedAt: Date?
        public init(id: String, name: String, environment: String? = nil, environmentName: String? = nil, updatedAt: Date? = nil) {
            (self.id, self.name, self.environment, self.environmentName, self.updatedAt) = (id, name, environment, environmentName, updatedAt)
        }
    }

    public enum Phase: Equatable, Sendable {
        case confirming(until: Instant)
        case loadingProjects
        case picking(projects: [Project], query: String, selected: Int)
        case sending
        /// The agent's own reply streaming in, for the reply-in-card destination.
        case replying(String)
        /// That reply, finished. It stays until Escape, so it can be read and copied.
        case replied(text: String, note: String)
        case sent(note: String)
        case cancelled
        case failed(String)
    }

    public enum Event: Equatable, Sendable {
        case tick(Instant), projects([Project]), key(CardKey), pick(Project), chunk(String), sent(note: String), failed(String)
    }

    public enum Effect: Equatable, Sendable {
        case send(project: Project?)
        case cancel
    }

    public var phase: Phase
    public var words: String
    public var destination: String

    public var picksProject: Bool

    public init(words: String, destination: String, picksProject: Bool, now: Instant) {
        (self.words, self.destination, self.picksProject) = (words, destination, picksProject)
        phase = picksProject ? .loadingProjects : .confirming(until: now + Self.countdown)
    }

    public var isOpen: Bool {
        switch phase {
        case .cancelled: false
        default: true
        }
    }

    /// Projects matching the typed filter, most recently used first and then by name.
    public static func filter(_ projects: [Project], query: String) -> [Project] {
        let sorted = projects.sorted { a, b in
            switch (a.updatedAt, b.updatedAt) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? sorted : sorted.filter { $0.name.localizedStandardContains(query) }
    }

    public var visibleProjects: [Project] {
        if case .picking(let projects, let query, _) = phase { return Self.filter(projects, query: query) }
        return []
    }

    /// Whether the card acts on this key now. Only these keys are kept from the app in front.
    public func takes(_ key: CardKey) -> Bool {
        switch (phase, key) {
        case (.picking, _): true
        case (.confirming, .returnKey): true
        case (.confirming, .escape), (.loadingProjects, .escape), (.failed, .escape), (.replied, .escape): true
        default: false
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        if case .key(let key) = event, !takes(key) { return [] }
        switch (phase, event) {
        case (.confirming, .key(.escape)), (.loadingProjects, .key(.escape)), (.picking, .key(.escape)),
             (.failed, .key(.escape)):
            phase = .cancelled
            return [.cancel]
        case (.replied, .key(.escape)):
            // Already sent, so closing cancels nothing.
            phase = .cancelled
            return []
        case (.confirming(let until), .tick(let now)) where now >= until:
            phase = .sending
            return [.send(project: nil)]
        case (.confirming, .key(.returnKey)):
            phase = .sending
            return [.send(project: nil)]

        case (.loadingProjects, .projects(let projects)):
            guard !projects.isEmpty else {
                phase = .failed("T3 Code has no projects to start a thread in.")
                return []
            }
            phase = .picking(projects: projects, query: "", selected: 0)
            return []
        case (.picking(let projects, let query, let selected), .key(let key)):
            let shown = Self.filter(projects, query: query)
            switch key {
            case .up: phase = .picking(projects: projects, query: query, selected: max(0, selected - 1))
            case .down: phase = .picking(projects: projects, query: query, selected: min(max(0, shown.count - 1), selected + 1))
            case .character(let character): phase = .picking(projects: projects, query: query + String(character), selected: 0)
            case .delete: phase = .picking(projects: projects, query: String(query.dropLast()), selected: 0)
            case .returnKey:
                guard shown.indices.contains(selected) else { return [] }
                phase = .sending
                return [.send(project: shown[selected])]
            case .number(let number):
                phase = .picking(projects: projects, query: query + String(number), selected: 0)
            case .escape: break
            }
            return []
        case (.picking, .pick(let project)):
            phase = .sending
            return [.send(project: project)]

        case (.sending, .chunk(let text)):
            phase = .replying(text)
            return []
        case (.replying(let sofar), .chunk(let text)):
            phase = .replying(sofar + text)
            return []
        case (.sending, .sent(let note)):
            phase = .sent(note: note)
            return []
        case (.replying(let text), .sent(let note)):
            phase = .replied(text: text, note: note)
            return []
        case (_, .failed(let reason)) where isOpen:
            phase = .failed(reason)
            return []
        default:
            return []
        }
    }
}
