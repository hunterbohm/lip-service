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

    /// How long to wait for more text before `finish`ing the words waiting, or nil to wait for more. The words end a
    /// sentence, though the space after it hasn't come, as when the agent pauses after "Sure." or answers "366." A number
    /// such as "3." might go on to "3.5", so after a digit the wait is longer, and a decimal's next digit arrives well
    /// within it.
    public var sentenceEndWait: Double? {
        let text = buffer.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, ".!?…".contains(last), let before = text.dropLast().last else { return nil }
        return last == "." && before.isNumber ? 0.6 : 0.15
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

/// One short line for what the agent started doing, from the tool's title and kind as ACP reports them: "Running t3-run
/// status", "Loading media-request skill", "Checking Gmail", "Reading plan.md". A title is often the tool's name, a colon
/// and a preview of its arguments, as Hermes sends them. Only a few safe words of the arguments are kept: a command's
/// program and subcommand, a skill's or file's name, a web host, and a short search. Quoted text, flags, values, paths and
/// anything that looks like a key are left out, so a secret or a message body is never shown or said.
public enum ToolLine {
    /// The longest line, in characters. A longer subject is cut with an ellipsis.
    public static let longest = 48

    private static let byTitle: [(String, String)] = [
        ("t3_thread_launch", "Starting a thread in T3 Code"), ("t3_project", "Looking through your T3 projects"),
        ("t3_thread", "Checking your T3 threads"),
        ("gmail", "Checking Gmail"), ("calendar", "Checking your calendar"), ("event", "Checking your calendar"),
        ("email", "Checking your email"), ("mail", "Checking your email"), ("inbox", "Checking your email"),
        ("session_search", "Searching your past talks"), ("memory", "Checking what it remembers"), ("remember", "Checking what it remembers"),
        ("weather", "Checking the weather"),
        ("web_search", "Digging around"), ("web search", "Digging around"), ("search the web", "Digging around"),
        ("browser", "Clicking through pages"), ("browse", "Clicking through pages"), ("fetch", "Doing some reading"), ("web", "Digging around"),
        ("send", "Sending that"), ("message", "Checking your messages"), ("slack", "Checking Slack"),
        ("notion", "Checking Notion"), ("github", "Checking GitHub"), ("linear", "Checking Linear"), ("stripe", "Checking Stripe"),
        ("cron", "Managing scheduled jobs"), ("schedule", "Managing scheduled jobs"),
        ("delegat", "Checking with another agent"), ("agent", "Checking with another agent"), ("vision", "Looking at an image"), ("image", "Working on an image"),
        ("todo", "Updating the to-do list"), ("task", "Checking your tasks"),
        ("skills_list", "Thinking it through"), ("skill_manage", "Updating a skill"), ("skill", "Thinking it through"),
        ("search", "Digging around"), ("grep", "Digging around"), ("find", "Digging around"),
        ("read", "Doing some reading"), ("write", "Jotting it down"), ("edit", "Making some edits"), ("patch", "Making some edits"),
        ("terminal", "Running a few commands"), ("bash", "Running a few commands"), ("shell", "Running a few commands"), ("execute", "Running a few commands"),
        ("code_execution", "Running a few commands"), ("python", "Running a few commands"),
    ]

    private static let byKind: [String: String] = [
        "read": "Doing some reading", "edit": "Making some edits", "delete": "Deleting a file", "move": "Moving files over", "search": "Digging around",
        "execute": "Running a few commands", "think": "Thinking it through", "fetch": "Doing some reading", "switch_mode": "Changing modes",
    ]

    /// Apps a command or tool can be checking, by a word it uses, their names, and the app whose icon stands for them.
    static let services: [(word: String, name: String, app: StepApp)] = [
        ("gmail", "Gmail", .gmail), ("calendar", "your calendar", .calendar), ("gcal", "your calendar", .calendar),
        ("drive", "Google Drive", .drive), ("sheets", "Google Sheets", .sheets), ("slack", "Slack", .slack),
        ("notion", "Notion", .notion), ("stripe", "Stripe", .stripe), ("linear", "Linear", .linear),
        ("discord", "Discord", .discord), ("imessage", "iMessage", .messages), ("obsidian", "Obsidian", .obsidian),
    ]

    /// The phrase for a permission the agent asks for. The kind decides it when the agent gives one, so a title that
    /// sounds harmless can't dress up a command or a deletion as something else.
    public static func permissionPhrase(title: String, kind: String?) -> String {
        // A question needs the exact thing it asks about, not a status line's loose words.
        if kind == "execute" { return "Running a command" }
        if let kind, let phrase = byKind[kind] { return phrase }
        return generic(title: title, kind: nil)
    }

    public static func phrase(title: String, kind: String?) -> String {
        let (tool, preview) = split(title)
        let name = tool.lowercased()
        if let line = specific(tool: name, preview: preview, kind: kind) { return fit(line) }
        return generic(title: title, kind: kind)
    }

    /// The fixed phrase from the tool's name or kind alone. Only the first word or two of a title is matched, since the
    /// rest of it is often the tool's arguments.
    static func generic(title: String, kind: String?) -> String {
        let name = title.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "(" }).prefix(2).joined(separator: " ")
        if let match = byTitle.first(where: { name.contains($0.0) }) { return match.1 }
        if let kind, let phrase = byKind[kind] { return phrase }
        return "Chipping away"
    }

    /// The SF Symbol the island shows beside a line, from its first words.
    public static func symbol(_ line: String) -> String {
        let rules: [(String, String)] = [
            ("Running", "terminal"), ("Digging around", "magnifyingglass"), ("Doing some reading", "doc.text"),
            ("Jotting it down", "square.and.pencil"), ("Making some edits", "pencil"), ("Clicking through pages", "safari"),
            ("Checking with another agent", "person.2"), ("Checking your notes", "note.text"), ("Thinking back", "clock.arrow.circlepath"),
            ("Checking GitHub", "chevron.left.forwardslash.chevron.right"),
            ("Setting up a call back", "phone.arrow.up.right"), ("Calling you back", "phone"),
            ("Loading", "book.closed"), ("Looking through its skills", "books.vertical"), ("Updating a skill", "book.closed"),
            ("Checking Gmail", "envelope"), ("Checking your email", "envelope"), ("Checking your calendar", "calendar"),
            ("Checking your messages", "message"), ("Checking iMessage", "message"), ("Sending", "paperplane"),
            ("Searching the web", "globe"), ("Opening", "safari"), ("Using the browser", "safari"), ("Looking at a web page", "safari"),
            ("Searching your past talks", "clock.arrow.circlepath"), ("Checking what it remembers", "brain"),
            ("Searching", "magnifyingglass"), ("Reading", "doc.text"), ("Writing", "square.and.pencil"), ("Editing", "pencil"),
            ("Making an edit", "pencil"), ("Asking a helper", "person.2"), ("Looking at an image", "eye"), ("Working on an image", "photo"),
            ("Managing scheduled jobs", "clock"), ("Checking the weather", "cloud.sun"), ("Starting a thread", "plus.bubble"),
            ("Checking your T3", "bubble.left.and.bubble.right"), ("Looking through your T3", "folder"),
            ("Updating the to-do list", "checklist"), ("Checking your tasks", "checklist"), ("Thinking", "sparkle"),
        ]
        return rules.first { line.hasPrefix($0.0) }?.1 ?? "sparkle"
    }

    // MARK: Reading a title

    /// "terminal: t3-run status" is the tool `terminal` and the preview `t3-run status`; a Claude Code title such as
    /// "`git status`" is a command, and "Read /path/file" a tool and its target.
    static func split(_ title: String) -> (tool: String, preview: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("`"), title.dropFirst().contains("`") {
            return ("bash", String(title.dropFirst().prefix { $0 != "`" }))
        }
        if let colon = title.range(of: ": "), title[..<colon.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }) {
            return (String(title[..<colon.lowerBound]), String(title[colon.upperBound...]))
        }
        let first = title.prefix { !$0.isWhitespace }
        if ["read", "write", "edit", "fetch"].contains(first.lowercased()) {
            return (String(first), title.dropFirst(first.count).trimmingCharacters(in: .whitespaces))
        }
        return (title, "")
    }

    static func specific(tool: String, preview: String, kind: String?) -> String? {
        let preview = preview.trimmingCharacters(in: .whitespaces)
        switch tool {
        case "terminal", "bash", "shell", "execute", "run_command":
            return command(preview)
        case "skill_view", "skill":
            return "Thinking it through"
        case "read_file", "read":
            return preview.lowercased().contains("/vault/") ? "Checking your notes" : "Doing some reading"
        case "write_file", "write":
            return "Jotting it down"
        case "patch", "edit":
            return "Making some edits"
        case "web_search", "search_files", "grep":
            return "Digging around"
        case "web_extract", "fetch":
            return "Doing some reading"
        case let name where name.hasPrefix("browser"):
            return "Clicking through pages"
        case "execute_code":
            return "Running a few commands"
        case "delegate_task":
            return "Checking with another agent"
        case "tool_call":
            // Hermes's tool bridge names what it does in a word or two: "Scheduling".
            return words(preview, most: 3).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        default:
            if kind == "execute", !preview.isEmpty { return command(preview) }
            if let service = services.first(where: { tool.contains($0.word) }) { return "Checking \(service.name)" }
            return nil
        }
    }

    /// What a command is for, in plain words, as Grok Bot's status line says it: never the command itself. An app it
    /// checks, such as Gmail, is named, and so is a call back it sets up; anything else is "Running a few commands".
    static func command(_ text: String) -> String? {
        let tokens = commandTokens(text)
        guard let first = tokens.first else { return nil }
        let program = String(first.split(separator: "/").last ?? "").lowercased()
        if program == "call-me-back" { return tokens.dropFirst().first == "done" ? "Calling you back" : "Setting up a call back" }
        if let service = service(tokens) { return "Checking \(service.name)" }
        if program == "hermes" { return tokens.dropFirst().first == "send" ? "Sending you a message" : "Checking with another agent" }
        if let line = byProgram[program] { return line }
        return "Running a few commands"
    }

    /// Programs that stand for something Hunter knows, and what using them is.
    private static let byProgram: [String: String] = [
        "t3-run": "Checking T3 Code", "t3": "Checking T3 Code", "gh": "Checking GitHub",
        "obsidian": "Checking your notes", "obsidian-cli": "Checking your notes", "stripe": "Checking Stripe",
        "stripe-invoices": "Checking Stripe", "kb": "Thinking back", "curl": "Doing some reading", "ssh": "Running a few commands",
    ]

    /// What a step says when the one before it said the same, so a run of commands reads as progress, not a stutter.
    public static let progress = ["Chipping away", "Making progress", "Getting it done"]

    /// A command's words from its program on: `cd somewhere &&` and wrappers like `sudo`, `timeout 60`, `infisical run --`
    /// and `KEY=value` are skipped.
    static func commandTokens(_ text: String) -> [String] {
        var tokens = text.replacingOccurrences(of: "\n", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first == "$" { tokens.removeFirst() }
        // `cd somewhere && git status` runs git.
        while let index = tokens.firstIndex(where: { $0 == "&&" || $0 == ";" }), index < 4, tokens.first == "cd" {
            tokens.removeFirst(index + 1)
        }
        let wrappers: Set<String> = ["sudo", "env", "time", "nohup", "exec", "command", "caffeinate", "uv", "npx", "bunx"]
        while let first = tokens.first {
            if wrappers.contains(first) || isAssignment(first) {
                tokens.removeFirst()
            } else if first == "timeout" || first == "nice" {
                tokens.removeFirst()
                if let next = tokens.first, next.allSatisfy({ $0.isNumber || $0 == "s" || $0 == "m" || $0 == "-" || $0 == "n" }) { tokens.removeFirst() }
            } else if first == "infisical", tokens.dropFirst().first == "run", let dashes = tokens.firstIndex(of: "--") {
                tokens.removeFirst(dashes + 1)
            } else if first == "run", tokens.count > 1 {
                tokens.removeFirst()
            } else {
                break
            }
        }
        return tokens
    }

    /// The app a command checks, from its first few words before any quoted one: `gog gmail search`, or a tool's dotted
    /// path such as `tools.google.gmail.search`. Flags and file paths are not read, and `drive.py` is a file, not Drive.
    static func service(_ tokens: [String]) -> (word: String, name: String, app: StepApp)? {
        let head = tokens.prefix(6).map { $0.lowercased() }
        let quoted = head.firstIndex { $0.hasPrefix("'") || $0.hasPrefix("\"") || $0.hasPrefix("<") } ?? head.count
        let words = head[..<quoted].filter { !$0.hasPrefix("-") && !$0.contains("/") }.flatMap { token -> [String] in
            let parts = token.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
            return parts.count > 2 ? parts : [token]
        }
        return services.first { words.contains($0.word) }
    }

    /// "productivity/executor-connected-accounts" is the skill `executor-connected-accounts`.
    static func skillName(_ text: String) -> String? {
        let name = text.components(separatedBy: " → ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        let bare = last.split(separator: ":").last.map(String.init) ?? last
        return isWord(bare) ? bare : nil
    }

    /// The file's name, without its folders: "plan.md". Nil when it isn't a plain name.
    static func fileName(_ text: String) -> String? {
        let path = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return isWord(name) ? name : nil
    }

    /// The host of the first web address: "mail.google.com".
    static func host(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /https?:\/\/([A-Za-z0-9.-]+)/) else { return nil }
        let host = String(match.1).lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Up to `most` plain words, for a search: letters, digits and a few marks, nothing that looks like a key. A quote
    /// anywhere means the words may be a quoted value, so none are kept.
    static func words(_ text: String, most: Int) -> String? {
        guard !text.contains(where: { "'\"`‘’“”".contains($0) }) else { return nil }
        let all = text.split(whereSeparator: \.isWhitespace)
        let kept = all.prefix(most).map(String.init)
        guard !kept.isEmpty, kept.allSatisfy({ $0.count <= 24 && $0.allSatisfy { $0.isLetter || $0.isNumber || "-.&".contains($0) } }),
              !kept.contains(where: looksLikeKey) else { return nil }
        return kept.joined(separator: " ") + (all.count > most ? "…" : "")
    }

    /// A short name: letters, digits, dot, dash, underscore and plus, starting with a letter or digit.
    static func isWord(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber, text.count <= 40, !looksLikeKey(text) else { return false }
        return text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "._-+".contains($0) }
    }

    static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        return token[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !token[..<equals].isEmpty
    }

    /// A long run of letters and digits with no vowels' rhythm, or a known key prefix: kept off the screen.
    static func looksLikeKey(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["sk-", "ghp_", "gho_", "xox", "pk_", "rk_", "akia", "ya29", "eyj"].contains(where: lower.hasPrefix) { return true }
        let run = text.filter { $0.isLetter || $0.isNumber }
        return run.count >= 20 && run.contains(where: \.isNumber) && run.contains(where: \.isLetter)
    }

    /// At most `longest` characters, cut at a word with an ellipsis.
    static func fit(_ line: String) -> String {
        guard line.count > longest else { return line }
        var cut = String(line.prefix(longest - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > longest / 2 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " .,-")) + "…"
    }
}

/// One step of the agent's turn, as the island shows it.
public struct TalkStep: Equatable, Sendable, Identifiable {
    /// "Checking Gmail".
    public var line: String
    /// The app it uses, when one is known, for its icon.
    public var app: StepApp?
    /// The tool call's id, when the agent gives one.
    public var call: String?
    /// The tool said it failed, so the step never shows as done.
    public var failed: Bool
    /// Counts the steps of a turn, so each row keeps its place as others come and go.
    public var id: Int

    public init(line: String, app: StepApp? = nil, call: String? = nil, failed: Bool = false, id: Int = 0) {
        (self.line, self.app, self.call, self.failed, self.id) = (line, app, call, failed, id)
    }
}

/// The steps the island shows, in order, each up for at least `hold` seconds so it can be read. When steps come faster
/// than that, they wait their turn; past `most` waiting, the oldest waiting ones are skipped, so the island never lags
/// far behind what the agent is doing. The steps that were shown stay behind it as a short trail.
public struct StepQueue: Sendable {
    public static let hold = 0.9
    public static let most = 3
    /// How many earlier steps stay under the one on the island.
    public static let trailMost = 3
    /// The step on the island now, and when it went up.
    public private(set) var step: TalkStep?
    public private(set) var since: Instant?
    /// The steps shown before it, oldest first.
    public private(set) var trail: [TalkStep] = []
    private var waiting: [TalkStep] = []
    private var count = 0
    /// The words of the last new step, before any were swapped for progress.
    private var lastOffered: String?

    public init() {}

    public var shown: String? { step?.line }

    /// Whether a step of tool call `call` was offered and is still known.
    public func has(call: String) -> Bool { step?.call == call || waiting.contains { $0.call == call } || trail.contains { $0.call == call } }

    /// A tool call that says more about itself, as some agents do once they know the file or the command, changes its
    /// own step instead of adding one. A new call is a new step even in the same words, so its timer, its failure and
    /// the island's reopening are its own; only a call with no id is told from the last one by its words.
    public mutating func offer(_ line: String, app: StepApp? = nil, call: String? = nil) {
        if let call {
            // A call that says the same about itself again keeps the progress words it was given.
            let before = lastOffered
            let kept = { (shown: String) in ToolLine.progress.contains(shown) && line == before }
            if step?.call == call {
                if let shown = step?.line, !kept(shown) { step?.line = line }
                step?.app = app
                return
            }
            if let index = waiting.firstIndex(where: { $0.call == call }) {
                if !kept(waiting[index].line) { waiting[index].line = line }
                waiting[index].app = app
                return
            }
            if trail.contains(where: { $0.call == call }) { return }
        } else if line == (waiting.last ?? step)?.line {
            return
        }
        count += 1
        var line = line
        // A new call in the same words as the last says progress instead, each in turn, so the trail doesn't stutter.
        if line == lastOffered {
            let shown = (waiting.last ?? step)?.line ?? ""
            line = ToolLine.progress[ToolLine.progress.firstIndex(of: shown).map { ($0 + 1) % ToolLine.progress.count } ?? 0]
        } else {
            lastOffered = line
        }
        waiting.append(TalkStep(line: line, app: app, call: call, id: count))
        if waiting.count > Self.most { waiting.removeFirst(waiting.count - Self.most) }
    }

    /// Tool call `call` failed: its step says so, wherever it is. False when no step of that call is known.
    @discardableResult
    public mutating func fail(call: String) -> Bool {
        guard has(call: call) else { return false }
        if step?.call == call { step?.failed = true }
        for index in waiting.indices where waiting[index].call == call { waiting[index].failed = true }
        for index in trail.indices where trail[index].call == call { trail[index].failed = true }
        return true
    }

    /// The next step to show now, or how long to wait before asking again, or neither when none is waiting.
    public mutating func next(at time: Instant) -> (line: String?, wait: Double?) {
        guard !waiting.isEmpty else { return (nil, nil) }
        if let since, time - since < Self.hold { return (nil, Self.hold - (time - since)) }
        if let step {
            trail.append(step)
            if trail.count > Self.trailMost { trail.removeFirst(trail.count - Self.trailMost) }
        }
        let next = waiting.removeFirst()
        (step, since) = (next, time)
        return (next.line, nil)
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
        on a dark background that is already set. For flights, a task, a meeting or an email, put JSON in <show> and I get \
        a live card: {"type":"flights","from":"AUS","to":"SFO","date":"Fri, Nov 14","options":[{"airline":"United",\
        "depart":"7:05 AM","arrive":"9:00 AM","duration":"3h 55m","price":"$214","best":true,"url":"https://..."}],\
        "actions":["Hold the 7:05"]}, or {"type":"task","id":"PP-3","title":"...","status":"Task added","due":"today"}, \
        {"type":"event","title":"...","date":"2026-11-12","time":"2:00 PM","where":"..."} or {"type":"email","from":"...",\
        "subject":"...","time":"..."}, alone or several in a JSON list. A "url" opens when I click the row. Each action is a \
        button, and its label comes back as my next words. Show flights again as more come in: the new card replaces the last. \
        When we're done with what you put on my screen, or the talk moves on to something else, send <show>clear</show> and \
        it all goes away.
        """

    /// Whether a `<show>` block asks to take everything the agent showed off the screen: `clear`, alone.
    public static func isClear(_ body: String) -> Bool {
        let word = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word == "clear" || word == "clear." || word == "clear screen"
    }

    public static func message(_ words: String, extra: String) -> String {
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return "(\(note)\(extra.isEmpty ? "" : " " + extra)) \(words)"
    }
}

/// How a talk answers the agent's requests to use a tool. Reading, searching and thinking go ahead, as in voice notes.
/// Anything else is asked. A spoken yes may allow only fetching a page and starting a T3 Code thread; running a command,
/// editing, deleting, moving or anything unnamed needs Allow clicked on the card, so a misheard word or a voice in the room
/// can't approve it. Either way only "allow once" is ever picked, never "always".
public enum TalkPermission {
    public enum Decision: Equatable, Sendable {
        /// Answer at once with this option, or with no option, which the agent takes as cancelled.
        case answer(String?)
        /// Ask. `byVoice` is whether a spoken yes may allow it.
        case ask(byVoice: Bool)
    }

    public static let automatic: Set<String> = ["read", "search", "think"]
    public static let spokenYes: Set<String> = ["fetch"]

    public static func decide(_ request: PermissionRequest) -> Decision {
        // T3 Code's tools, which a talk with Claude Code may carry. Listing and reading go ahead; starting a thread asks
        // for a spoken yes or a click. Any other tool of the server falls through to the rules below.
        if let tool = T3Talk.tool(of: request) {
            if T3Talk.readingTools.contains(tool) { return .answer(allowOnce(request) ?? request.rejection?.id) }
            if tool == T3Talk.launchThread, allowOnce(request) != nil { return .ask(byVoice: true) }
        }
        if let kind = request.toolKind, automatic.contains(kind) { return .answer(allowOnce(request) ?? request.rejection?.id) }
        guard allowOnce(request) != nil else { return .answer(request.rejection?.id) }
        return .ask(byVoice: request.toolKind.map(spokenYes.contains) ?? false)
    }

    /// The option an answer picks: "allow once" for a yes, the agent's refusal for a no.
    public static func choice(_ request: PermissionRequest, allowed: Bool) -> String? {
        allowed ? allowOnce(request) : request.rejection?.id
    }

    private static func allowOnce(_ request: PermissionRequest) -> String? { request.options.first { $0.kind == "allow_once" }?.id }
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
