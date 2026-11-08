import Foundation

/// A piece of the agent's streamed reply: words to say, or something to put on screen.
public enum ReplyPiece: Equatable, Sendable {
    case speech(String)
    case show(String)
}

/// Splits a streamed reply into speech and `<show>…</show>` blocks. A tag can arrive split across chunks, so a tail
/// that could be the start of one waits for the next chunk.
public struct ShowSplitter: Sendable {
    private var buffer = ""
    private var inShow = false
    private static let open = "<show>", close = "</show>"

    public init() {}

    public mutating func feed(_ text: String) -> [ReplyPiece] {
        buffer += text
        return drain(final: false)
    }

    public mutating func finish() -> [ReplyPiece] { drain(final: true) }

    private mutating func drain(final: Bool) -> [ReplyPiece] {
        var out: [ReplyPiece] = []
        while true {
            if inShow {
                if let range = buffer.range(of: Self.close, options: .caseInsensitive) {
                    let body = buffer[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { out.append(.show(body)) }
                    buffer = String(buffer[range.upperBound...])
                    inShow = false
                    continue
                }
                if final {
                    let body = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { out.append(.show(body)) }
                    buffer = ""
                }
                return out
            }
            if let range = buffer.range(of: Self.open, options: .caseInsensitive) {
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty { out.append(.speech(before)) }
                buffer = String(buffer[range.upperBound...])
                inShow = true
                continue
            }
            let keep = final ? 0 : Self.partialTagLength(buffer)
            let emit = String(buffer.dropLast(keep))
            if !emit.isEmpty { out.append(.speech(emit)) }
            buffer = String(buffer.suffix(keep))
            return out
        }
    }

    /// How many trailing characters could be the start of `<show>`.
    static func partialTagLength(_ text: String) -> Int {
        let lower = text.lowercased()
        for count in stride(from: min(open.count - 1, lower.count), through: 1, by: -1) where open.hasPrefix(String(lower.suffix(count))) {
            return count
        }
        return 0
    }
}

/// Cuts the reply's spoken words into pieces for the voice, so it can start on the first few words. The first piece
/// ends at the first sentence end, or at the first clause boundary, such as a comma, once `firstWords` words have come. Every later piece is a whole
/// sentence, or, when a sentence runs long, ends at a comma. A boundary counts only once the space after it has
/// arrived, so "3.5" or "1,000" are never cut.
public struct SpeechChunker: Sendable {
    public var firstWords = 3
    /// A later piece shorter than this joins the next one, so "OK." does not get a clip of its own.
    public var shortest = 12
    /// A sentence still open at this length is cut at its last clause boundary.
    public var longest = 220

    private var buffer = ""
    private var spokeFirst = false

    public init() {}

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let cut = nextCut() {
            let piece = Speech.collapse(String(buffer[..<cut]))
            buffer = String(buffer[cut...])
            if !piece.isEmpty {
                out.append(piece)
                spokeFirst = true
            }
        }
        return out
    }

    public mutating func finish() -> [String] {
        let rest = Speech.collapse(buffer)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    /// The words waiting end a sentence, though the space after it hasn't come, as when the agent pauses after "Sure."
    /// The caller may `finish` them after a short wait. A number such as "3." might go on to "3.5", so it doesn't count.
    public var endsOnSentence: Bool {
        let text = buffer.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, ".!?…".contains(last) else { return false }
        let before = text.dropLast().last
        return before.map { !$0.isNumber } ?? false
    }

    /// Where the next piece ends, just past its punctuation, or nil to wait for more.
    private func nextCut() -> String.Index? {
        let marks = Self.boundaries(in: buffer)
        if !spokeFirst {
            return marks.first { mark in mark.endsSentence || Self.words(in: buffer[..<mark.index]) >= firstWords }?.index
        }
        if let sentence = marks.first(where: { $0.endsSentence && buffer.distance(from: buffer.startIndex, to: $0.index) >= shortest }) {
            return sentence.index
        }
        guard buffer.count > longest else { return nil }
        return marks.last { mark in
            let length = buffer.distance(from: buffer.startIndex, to: mark.index)
            return length >= shortest * 4 && length <= longest
        }?.index
    }

    private struct Boundary {
        let index: String.Index
        let endsSentence: Bool
    }

    /// Each place just after a run of punctuation that is followed by whitespace. Closing quotes and brackets stay with
    /// their sentence.
    private static func boundaries(in text: String) -> [Boundary] {
        var out: [Boundary] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let sentence = ".!?…".contains(character), clause = ",;:—".contains(character)
            guard sentence || clause else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            var endsSentence = sentence
            while end < text.endIndex, ".!?…,;:—\"')]”’".contains(text[end]) {
                if ".!?…".contains(text[end]) { endsSentence = true }
                end = text.index(after: end)
            }
            if end < text.endIndex, text[end].isWhitespace { out.append(Boundary(index: end, endsSentence: endsSentence)) }
            index = end
        }
        return out
    }

    private static func words(in text: Substring) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}

public enum Speech {
    public static func collapse(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Text for the voice: no code, no markdown, and a web address becomes "a link".
    public static func spoken(_ text: String) -> String {
        var line = text.replacing(/```[\s\S]*?```/, with: " ")
        line = line.replacing(/\[([^\]]+)\]\([^)]+\)/) { String($0.1) }
        line = line.replacing(/https?:\/\/\S+/, with: "a link")
        line = line.replacing(/[*_`#>|]+/, with: "")
        return collapse(line)
    }

    /// The same words for the bar: markdown marks gone, links kept.
    public static func caption(_ text: String) -> String {
        var line = text.replacing(/```[\s\S]*?```/, with: " ")
        line = line.replacing(/\[([^\]]+)\]\([^)]+\)/) { String($0.1) }
        line = line.replacing(/[*_`#>|]+/, with: "")
        return collapse(line)
    }
}

/// What a `<show>` block holds.
public enum ShowCard: Equatable, Sendable {
    case link(URL)
    case image(URL)
    case text(String)
    /// A self-contained web page or fragment the agent drew: a chart, diagram, table or other visual.
    case html(String)

    public static func classify(_ body: String) -> ShowCard {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.firstMatch(of: /^```html\s*\n([\s\S]*?)\n?```$/) { return .html(String(match.1)) }
        if text.hasPrefix("<"), text.firstMatch(of: /(?i)<\/[a-z]+>|<svg|<!doctype/) != nil { return .html(text) }
        // A markdown image or link around one address counts as that address.
        if let match = text.firstMatch(of: /^!?\[[^\]]*\]\((\S+)\)$/) { text = String(match.1) }
        if !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "svg"]
            return images.contains(url.pathExtension.lowercased()) ? .image(url) : .link(url)
        }
        return .text(text)
    }
}

/// One plain line for what the agent started doing, from the tool's title and kind as ACP reports them. The words are
/// fixed phrases: a tool's arguments, which can hold commands or private text, are never read out or shown.
public enum ToolLine {
    private static let byTitle: [(String, String)] = [
        ("calendar", "Checking your calendar"), ("event", "Checking your calendar"),
        ("gmail", "Checking your email"), ("email", "Checking your email"), ("mail", "Checking your email"), ("inbox", "Checking your email"),
        ("session_search", "Searching your past talks"), ("memory", "Checking what it remembers"), ("remember", "Checking what it remembers"),
        ("weather", "Checking the weather"),
        ("web_search", "Searching the web"), ("web search", "Searching the web"), ("search the web", "Searching the web"),
        ("browser", "Looking at a web page"), ("browse", "Looking at a web page"), ("fetch", "Looking at a web page"), ("web", "Searching the web"),
        ("send", "Sending that"), ("message", "Checking your messages"), ("slack", "Checking Slack"),
        ("notion", "Checking Notion"), ("github", "Checking GitHub"), ("linear", "Checking Linear"),
        ("todo", "Updating the to-do list"), ("task", "Checking your tasks"), ("cron", "Checking schedules"), ("schedule", "Checking schedules"),
        ("delegat", "Asking a helper"), ("agent", "Asking a helper"), ("vision", "Looking at an image"), ("image", "Working on an image"),
        ("skill", "Using one of its skills"), ("search", "Searching"), ("grep", "Searching"), ("find", "Searching"),
        ("read", "Reading a file"), ("write", "Writing a file"), ("edit", "Making an edit"),
        ("terminal", "Running a command"), ("bash", "Running a command"), ("shell", "Running a command"), ("execute", "Running a command"),
        ("code_execution", "Running some code"), ("python", "Running some code"),
    ]

    private static let byKind: [String: String] = [
        "read": "Reading a file", "edit": "Making an edit", "delete": "Deleting a file", "move": "Moving files", "search": "Searching",
        "execute": "Running a command", "think": "Thinking it over", "fetch": "Looking at a web page", "switch_mode": "Changing modes",
    ]

    /// Only the first word or two of a title is matched, since the rest of it is often the tool's arguments.
    public static func phrase(title: String, kind: String?) -> String {
        let name = title.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "(" }).prefix(2).joined(separator: " ")
        if let match = byTitle.first(where: { name.contains($0.0) }) { return match.1 }
        if let kind, let phrase = byKind[kind] { return phrase }
        return "Working on it"
    }
}

/// Decides which tool starts get a spoken line: each tool call once, and at most one line every `spacing` seconds.
public struct ToolAnnouncer: Sendable {
    public var spacing = 4.0
    private var seen: Set<String> = []
    private var lastAt: Instant?
    private var lastPhrase: String?

    public init() {}

    /// The line to say and show, or nil to stay quiet. `id` is the tool call's id; one without an id is new each time.
    public mutating func announce(id: String?, title: String, kind: String?, at time: Instant) -> String? {
        if let id {
            guard seen.insert(id).inserted else { return nil }
        }
        if let lastAt, time - lastAt < spacing { return nil }
        let phrase = ToolLine.phrase(title: title, kind: kind)
        // The same phrase again soon after says nothing new.
        if phrase == lastPhrase, let lastAt, time - lastAt < spacing * 3 { return nil }
        (lastAt, lastPhrase) = (time, phrase)
        return phrase
    }
}

/// What goes to the agent each turn: a short note on how to answer a spoken talk, the agent's own extra, and your words.
/// The note rides in the message, not in a system prompt, so an agent that caches its prompt keeps its cache.
public enum TalkPrompt {
    public static let note = """
        Voice call through Lip Service: I hear your reply spoken aloud. Answer in short spoken sentences, and say the answer \
        first. No markdown, lists or links in what you say. To put something on my screen, like a link, an image URL, a list, \
        code or numbers, wrap it in <show></show>: I see it, and it is not read out. For a chart, diagram, timeline or table, \
        put one self-contained HTML snippet in <show> instead: inline CSS and SVG, about 500px wide, labels kept inside it, \
        on a dark background that is already set.
        """

    public static func message(_ words: String, extra: String) -> String {
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return "(\(note)\(extra.isEmpty ? "" : " " + extra)) \(words)"
    }
}

/// The steps of one turn, timed from when you stopped talking, for the log and the end-to-end test.
public struct TurnClock: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        /// The quiet after your words was long enough to end your turn.
        case turnEnd = "turn end"
        case transcribed
        case firstText = "first text"
        /// The first piece of the reply was ready to say.
        case firstPiece = "first piece"
        case firstAudio = "first audio"
    }

    public let speechEnd: Instant
    public private(set) var marks: [Step: Instant] = [:]

    public init(speechEnd: Instant) { self.speechEnd = speechEnd }

    /// Records a step the first time it happens.
    public mutating func mark(_ step: Step, at time: Instant) {
        if marks[step] == nil { marks[step] = time }
    }

    public func seconds(_ step: Step) -> Double? { marks[step].map { $0 - speechEnd } }

    /// "turn end 0.81 s, transcribed 0.96 s, first text 3.20 s, first piece 3.31 s, first audio 3.55 s after speech end"
    public var summary: String {
        let parts = Step.allCases.compactMap { step in seconds(step).map { step.rawValue + String(format: " %.2f s", $0) } }
        return parts.joined(separator: ", ") + " after speech end"
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        for step in Step.allCases {
            if let value = seconds(step) { object[step.rawValue.replacingOccurrences(of: " ", with: "_")] = .number((value * 1000).rounded() / 1000) }
        }
        return .object(object)
    }
}

/// WAV in and out, for a voice server's answers and the end-to-end test's recordings: 16-bit or 32-bit float PCM. Read as
/// mono, the channels averaged.
public enum WAVFile {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(bytes)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The samples and the sample rate, or nil when this is not a PCM WAV this can read.
    public static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var index = 12, rate = 0, channels = 1, bits = 16, format = 1
        while index + 8 <= bytes.count {
            let id = bytes[index..<index + 4]
            let size = min(u32(index + 4), bytes.count - index - 8)
            if id.elementsEqual("fmt ".utf8), size >= 16 {
                format = u16(index + 8)
                channels = max(1, u16(index + 10))
                rate = u32(index + 12)
                bits = u16(index + 22)
                // WAVE_FORMAT_EXTENSIBLE keeps the real format in its sub-format GUID.
                if format == 0xFFFE, size >= 26 { format = u16(index + 32) }
            } else if id.elementsEqual("data".utf8) {
                guard rate > 0, (format == 1 && bits == 16) || (format == 3 && bits == 32) else { return nil }
                let width = bits / 8, frames = size / (width * channels)
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let at = index + 8 + (frame * channels + channel) * width
                        if format == 1 {
                            sum += Float(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) / 32768
                        } else {
                            sum += Float(bitPattern: UInt32(u32(at)))
                        }
                    }
                    samples[frame] = sum / Float(channels)
                }
                return (samples, rate)
            }
            index += 8 + size + (size & 1)
        }
        return nil
    }
}
