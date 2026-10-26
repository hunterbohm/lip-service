import Foundation

/// The user's vocabulary file, parsed. One term per line, its exact spelling first. Misheard spellings that
/// survive boosting go after a colon, comma-separated. `@min-similarity` is the boosting threshold.
///
///     # Comments and blank lines are ignored.
///     @min-similarity 0.7
///     Figma
///     Siobhan: shivon, chevonne
public struct Vocabulary: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public var text: String
        public var aliases: [String]
        public init(text: String, aliases: [String] = []) { (self.text, self.aliases) = (text, aliases) }
    }

    public struct Issue: Equatable, Sendable {
        public var line: Int
        public var message: String
        public init(line: Int, message: String) { (self.line, self.message) = (line, message) }
    }

    public static let defaultMinSimilarity = 0.7
    public static let similarityRange = 0.5...1.0
    public var terms: [Term]
    public var minSimilarity: Double

    public init(terms: [Term], minSimilarity: Double = defaultMinSimilarity) {
        (self.terms, self.minSimilarity) = (terms, minSimilarity)
    }

    /// Never fails. A bad line becomes an Issue with its line number and is skipped, and the rest of the file
    /// still applies.
    public static func parse(_ text: String) -> (vocabulary: Vocabulary, issues: [Issue]) {
        var vocabulary = Vocabulary(terms: [])
        var issues: [Issue] = []
        var seen = Set<String>()
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let issue: (String) -> Void = { issues.append(Issue(line: index + 1, message: $0)) }
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("@") {
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts[0] == "@min-similarity" else { issue("unknown setting \(parts[0])"); continue }
                guard parts.count == 2, let value = Double(parts[1]), similarityRange.contains(value) else {
                    issue("@min-similarity needs one number from 0.5 to 1.0")
                    continue
                }
                vocabulary.minSimilarity = value
                continue
            }

            let halves = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let term = halves[0].trimmingCharacters(in: .whitespaces)
            let aliases = halves.count == 2
                ? halves[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                : []
            if term.isEmpty { issue("a term is missing before the colon"); continue }
            if aliases.contains("") { issue("an empty misheard spelling for \(term)"); continue }
            if !seen.insert(term.lowercased()).inserted { issue("\(term) is listed twice"); continue }
            vocabulary.terms.append(Term(text: term, aliases: aliases))
        }
        return (vocabulary, issues)
    }

    /// The terms the engine bakeoff measured, with the misheard spellings it found. The self-test and the bench use
    /// them, so a user's vocabulary cannot move their results.
    public static let bakeoff = Vocabulary(terms: [
        Term(text: "Hermes"), Term(text: "ProfitPilot"), Term(text: "Nective"), Term(text: "HubSpot"),
        Term(text: "Beehiiv", aliases: ["behive", "beehive", "bee hive"]), Term(text: "Obsidian"), Term(text: "TaskNotes"),
        Term(text: "Tailscale"), Term(text: "Claude"), Term(text: "Codex"), Term(text: "Granola"),
        Term(text: "Infisical", aliases: ["in physical", "infisical"]), Term(text: "Executor"),
    ])

    /// Seeds the user's file on first launch.
    public static let bundledDefault = """
        # One term per line, spelled the way it should appear.
        # After a colon, misheard spellings to replace with the term, separated by commas.
        # @min-similarity is how close a heard word must sound before boosting swaps in a term (0.5 to 1.0).
        # Examples. Delete the # at the start of a line to use it.
        # Figma
        # Siobhan: shivon, chevonne
        @min-similarity 0.7

        """
}

/// Port of `bench/cleanup.py deterministic()`. Parity is a generated test (scripts/make-cleanup-fixtures.sh).
public struct Cleanup: Sendable {
    /// Weekdays and months. "May" is left out because it is usually the verb.
    public static let calendarNames = ("Monday Tuesday Wednesday Thursday Friday Saturday Sunday January February "
        + "March April June July August September October November December").split(separator: " ").map(String.init)

    private let properNouns: [(Pattern, String)]

    public init(properNouns: [String]) {
        self.properNouns = properNouns.map { noun in
            (Pattern("(?i)\\b" + NSRegularExpression.escapedPattern(for: noun) + "\\b"),
             NSRegularExpression.escapedTemplate(for: noun))
        }
    }

    private static let filler = Pattern("(?i),?\\s*\\b(um+|uh+|erm|er|ah|hmm+|mm+)\\b\\s*,?")
    private static let youKnow = Pattern("(?i)(,\\s*|^\\s*)(you know|i mean)(,\\s*|\\s*$)")
    private static let loneI = Pattern("\\bi\\b")
    private static let spaceBeforePunctuation = Pattern("\\s+([,.;:!?])")
    private static let repeatedPunctuation = Pattern("([,;:])\\1+")
    private static let whitespace = Pattern("\\s+")
    private static let leadingPunctuation = Pattern("^[,;:.\\s]+")
    private static let sentenceStart = Pattern("(^|[.!?]\\s+)([a-z])")
    private static let sentenceBreak = Pattern("[.!?]\\s+")
    private static let questionStart = Pattern(
        "(?i)^(do|does|did|can|could|would|will|is|are|was|were|should|what|why|how|when|where|who|which|have|has)\\b")

    public func apply(_ text: String) -> String {
        var t = " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        t = Self.filler.replace(t, template: " ")
        t = Self.youKnow.replace(t) { match in
            let opensWithComma = !match(1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let closesWithComma = !match(3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return opensWithComma && closesWithComma ? ", " : " "
        }
        for (pattern, noun) in properNouns { t = pattern.replace(t, template: noun) }
        t = Self.loneI.replace(t, template: "I")
        t = Self.spaceBeforePunctuation.replace(t, template: "$1")
        t = Self.repeatedPunctuation.replace(t, template: "$1")
        t = Self.whitespace.replace(t, template: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        t = Self.leadingPunctuation.replace(t, template: "")
        t = Self.sentenceStart.replace(t) { match in match(1) + match(2).uppercased() }
        guard let end = t.last, !".!?".contains(end) else { return t }
        let lastSentence = Self.sentenceBreak.split(t).last ?? t
        while let end = t.last, ",;:".contains(end) { t.removeLast() }
        return t + (Self.questionStart.matches(lastSentence) ? "?" : ".")
    }
}

public struct AliasRules: Sendable {
    private let pattern: Pattern?
    private let canonical: [String: String]

    public init(terms: [Vocabulary.Term]) {
        var canonical: [String: String] = [:]
        for term in terms {
            for alias in term.aliases { canonical[Self.key(alias)] = term.text }
        }
        self.canonical = canonical
        guard !canonical.isEmpty else {
            pattern = nil
            return
        }
        let longestFirst = canonical.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let alternatives = longestFirst.map { alias in
            alias.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        pattern = Pattern("(?i)(?<!\\w)(?:" + alternatives.joined(separator: "|") + ")(?!\\w)")
    }

    private static func key(_ alias: String) -> String {
        alias.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whole-word, case-insensitive, longest alias first. Surrounding punctuation and suffixes such as 's stay.
    public func apply(_ text: String) -> String {
        guard let pattern else { return text }
        return pattern.replace(text) { match in canonical[Self.key(match(0))] ?? match(0) }
    }
}

/// FluidAudio's rescorer drops trailing punctuation from a replaced span ("profit pilot, put" becomes
/// "ProfitPilot put").
public enum PunctuationRestore {
    private static let trailingMarks: Set<Character> = [",", ".", ";", ":", "!", "?"]

    /// Aligns raw and boosted words on unchanged words (longest common subsequence over lowercased letters and
    /// digits). Each gap between anchors is one replacement. If its last raw word ends in punctuation and its
    /// last boosted word does not, the punctuation moves over.
    public static func restore(raw: String, boosted: String) -> String {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var words = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        var previous = (raw: 0, boosted: 0)
        for anchor in commonWords(rawWords.map(key), words.map(key)) + [(rawWords.count, words.count)] {
            if anchor.0 > previous.raw, anchor.1 > previous.boosted {
                let marks = String(rawWords[anchor.0 - 1].reversed().prefix { trailingMarks.contains($0) }.reversed())
                if !marks.isEmpty, let last = words[anchor.1 - 1].last, !trailingMarks.contains(last) {
                    words[anchor.1 - 1] += marks
                }
            }
            previous = (anchor.0 + 1, anchor.1 + 1)
        }
        return words.joined(separator: " ")
    }

    private static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Index pairs of one longest common subsequence, in order.
    private static func commonWords(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var (i, j) = (0, 0)
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                (i, j) = (i + 1, j + 1)
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}

/// Everything between the engine's words and the inserted text. The engine holds one and calls it for every
/// dictation, so the app, self-test, and bench share one order.
public struct TextFinisher: Sendable {
    private let aliases: AliasRules
    private let cleanup: Cleanup

    /// Nil when vocabulary is off, which drops aliases and term casing. Calendar casing and cleanup still run.
    public init(vocabulary: Vocabulary?) {
        let terms = vocabulary?.terms ?? []
        aliases = AliasRules(terms: terms)
        cleanup = Cleanup(properNouns: terms.map(\.text) + Cleanup.calendarNames)
    }

    public func finish(raw: String, boosted: String?) -> String {
        let restored = boosted.map { PunctuationRestore.restore(raw: raw, boosted: $0) } ?? raw
        return cleanup.apply(aliases.apply(restored))
    }
}

/// A compiled ICU pattern with the few operations the text rules need. ICU matches Python's `re` on the
/// constructs these rules use, which the cleanup parity fixtures check. NSRegularExpression is immutable and
/// documented as safe to share across threads.
struct Pattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        do { regex = try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("bad pattern \(pattern): \(error)") }
    }

    func replace(_ text: String, template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
    }

    /// `transform` receives a group accessor: group n's text, or "" when the group did not take part.
    func replace(_ text: String, with transform: (_ group: (Int) -> String) -> String) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += transform { n in
                let range = match.range(at: n)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }

    func split(_ text: String) -> [String] {
        let source = text as NSString
        var pieces: [String] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        return pieces + [source.substring(from: cursor)]
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
