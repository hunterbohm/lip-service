import Foundation

/// Smart formatting: a model reads the finished dictation once and scores each word for a paragraph or line break
/// before it, a list item starting at it, a quote opening before or closing after it, being dropped (spoken counting
/// words and commands), its final punctuation, and its capital. The rules here turn those scores into text. They
/// only add breaks, list markers and quotes, change punctuation and capitals, and drop words, so the words that stay
/// are the heard words, in order.
///
/// Everything here is a port of the training code's `labels.py` and `train.py` encoding, and the parity fixtures
/// check it against them.

/// `formatter.json`, written next to the model by the training export.
public struct FormatterConfig: Codable, Equatable, Sendable {
    public struct PauseToken: Codable, Equatable, Sendable {
        public var seconds: Double
        public var id: Int
    }

    /// The confidence each change needs, and the shortest dictation that may get breaks other than list items. A
    /// bulleted item also needs `bullet`, unless "bullet" was said before it; a model without one has no extra bar.
    public struct Cut: Codable, Equatable, Sendable {
        public var brk: Double
        public var item: Double
        public var quote: Double
        public var drop: Double
        public var minWordsForBreaks: Int
        public var bullet: Double?

        public init(brk: Double, item: Double, quote: Double, drop: Double, minWordsForBreaks: Int, bullet: Double? = nil) {
            (self.brk, self.item, self.quote, self.drop, self.minWordsForBreaks) = (brk, item, quote, drop, minWordsForBreaks)
            self.bullet = bullet
        }
    }

    public var maxTokens: Int
    public var start: Int
    public var end: Int
    public var pad: Int
    /// Keyed by ProfileGroup raw value, plus "unknown".
    public var appTokens: [String: Int]
    /// Longest first.
    public var pauseTokens: [PauseToken]
    public var cut: Cut
    public var model: String
}

/// The scores for one word, each a probability per class.
public struct WordScores: Equatable, Sendable {
    public var brk: [Double]
    public var item: [Double]
    public var qo: [Double]
    public var qc: [Double]
    public var drop: [Double]
    public var punct: [Double]
    public var cap: [Double]

    public static let widths = [3, 3, 2, 2, 2, 7, 2]
    public static let width = widths.reduce(0, +)
    /// No change anywhere: what a word the model did not see gets.
    public static let unchanged = WordScores(logits: [Float](repeating: 0, count: width), mostLikelyFirst: true)

    public init(brk: [Double], item: [Double], qo: [Double], qc: [Double], drop: [Double], punct: [Double], cap: [Double]) {
        (self.brk, self.item, self.qo, self.qc, self.drop, self.punct, self.cap) = (brk, item, qo, qc, drop, punct, cap)
    }

    /// Softmax per head over one token's `width` logits.
    public init<C: Collection>(logits: C) where C.Element == Float {
        self.init(logits: Array(logits), mostLikelyFirst: false)
    }

    private init(logits: [Float], mostLikelyFirst: Bool) {
        var heads: [[Double]] = []
        var offset = 0
        for width in Self.widths {
            if mostLikelyFirst {
                heads.append([1] + [Double](repeating: 0, count: width - 1))
            } else {
                let z = logits[offset..<offset + width].map(Double.init)
                let top = z.max() ?? 0
                let e = z.map { Foundation.exp($0 - top) }
                let sum = e.reduce(0, +)
                heads.append(e.map { $0 / sum })
            }
            offset += width
        }
        self.init(brk: heads[0], item: heads[1], qo: heads[2], qc: heads[3], drop: heads[4], punct: heads[5], cap: heads[6])
    }
}

/// What happens at one word.
public struct LayoutLabel: Equatable, Sendable {
    /// 0 none, 1 line break before, 2 paragraph break before.
    public var brk = 0
    /// 0 none, 1 numbered item starts here, 2 bulleted item starts here.
    public var item = 0
    public var quoteOpens = false
    public var quoteCloses = false
    public var drop = false
    /// Index into `SmartLayout.marks`.
    public var punct = 0
    public var capital = false

    public init(brk: Int = 0, item: Int = 0, quoteOpens: Bool = false, quoteCloses: Bool = false, drop: Bool = false,
                punct: Int = 0, capital: Bool = false) {
        (self.brk, self.item, self.quoteOpens, self.quoteCloses) = (brk, item, quoteOpens, quoteCloses)
        (self.drop, self.punct, self.capital) = (drop, punct, capital)
    }
}

public enum SmartLayout {
    public static let marks = ["", ",", ".", "?", "!", ":", ";"]
    static let counting: Set<String> = Set(("number one two three four five six seven eight nine ten first second third fourth "
        + "fifth sixth seventh eighth ninth tenth step 1 2 3 4 5 6 7 8 9 10").split(separator: " ").map(String.init))
        .union(numbers.keys)
    private static let openQuotes: Set<Character> = ["\"", "“"]
    private static let closeQuotes: Set<Character> = ["\"", "”"]
    private static let markSet: Set<Character> = [".", ",", "?", "!", ":", ";"]
    private static let iWords: Set<String> = ["i", "i'm", "i've", "i'll", "i'd"]

    /// The word with its quotes and trailing marks split off: (opens a quote, core, last mark, closes a quote).
    static func split(_ word: String) -> (opens: Bool, core: String, mark: String, closes: Bool) {
        var chars = Array(word)
        var opens = false
        while let first = chars.first, openQuotes.contains(first) {
            opens = true
            chars.removeFirst()
        }
        var tail: [Character] = []
        while let last = chars.last, closeQuotes.contains(last) || markSet.contains(last) {
            tail.insert(last, at: 0)
            chars.removeLast()
        }
        let closes = tail.contains { closeQuotes.contains($0) }
        let mark = tail.last { markSet.contains($0) }.map(String.init) ?? ""
        return (opens, String(chars), mark, closes)
    }

    /// Lowercased ASCII letters and digits only.
    static func key(_ core: String) -> String {
        String(core.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    public static func decide(words: [String], scores: [WordScores], cut: FormatterConfig.Cut) -> [LayoutLabel] {
        var labels = scores.map { s -> LayoutLabel in
            var label = LayoutLabel()
            if s.brk[1] + s.brk[2] >= cut.brk { label.brk = s.brk[2] >= s.brk[1] ? 2 : 1 }
            if s.item[1] + s.item[2] >= cut.item { label.item = s.item[1] >= s.item[2] ? 1 : 2 }
            label.quoteOpens = s.qo[1] >= cut.quote
            label.quoteCloses = s.qc[1] >= cut.quote
            label.drop = s.drop[1] >= cut.drop
            for k in s.punct.indices where s.punct[k] > s.punct[label.punct] { label.punct = k }
            label.capital = s.cap[1] >= 0.5
            return label
        }
        if words.count < cut.minWordsForBreaks {
            for i in labels.indices where labels[i].item == 0 { labels[i].brk = 0 }
        }
        let keys = words.map { key(split($0).core) }
        func saidBullet(_ i: Int) -> Bool {
            i > 0 && (keys[i - 1] == "bullet" || (keys[i - 1] == "point" && i > 1 && keys[i - 2] == "bullet"))
        }
        for i in labels.indices where labels[i].item == 2 && scores[i].item[2] < cut.bullet ?? 0 && !saidBullet(i) {
            if spokenCount(before: i, keys: keys, words: words, labels: labels)?.number != nil {
                labels[i].item = 1
            } else {
                labels[i].item = 0
                labels[i].brk = 0
            }
        }
        for i in labels.indices where labels[i].drop {
            let next = i + 1 < keys.count ? keys[i + 1] : "", previous = i > 0 ? keys[i - 1] : ""
            labels[i].drop = commandWords.contains(keys[i]) || commandPairs.contains([keys[i], next])
                || commandPairs.contains([previous, keys[i]])
        }
        var runs: [[Int]] = []
        var run: [Int] = []
        for i in labels.indices {
            if labels[i].item > 0 {
                run.append(i)
            } else if labels[i].brk > 0, !run.isEmpty {
                runs.append(run)
                run = []
            }
        }
        if !run.isEmpty { runs.append(run) }
        // A count that starts partway answers numbered questions, unless it carries on the list before it.
        var listedUpTo: Int?
        for run in runs {
            if run.count < 2 {
                labels[run[0]].item = 0
                labels[run[0]].brk = 0
                continue
            }
            let counts = run.map { spokenCount(before: $0, keys: keys, words: words, labels: labels) }
            let said = counts.map { $0?.number }
            if let first = said[0], first != 1, listedUpTo.map({ first != $0 + 1 }) ?? true {
                for (i, count) in zip(run, counts) { keepCountAsParagraph(at: i, count: count, labels: &labels) }
                continue
            }
            for count in counts { if let count { drop(count, labels: &labels) } }
            listedUpTo = said.reduce(0) { last, number in number ?? last + 1 }
        }
        for i in labels.indices where labels[i].drop {
            labels[i].quoteOpens = false
            labels[i].quoteCloses = false
        }
        var openAt: Int?
        for i in labels.indices where !labels[i].drop {
            if labels[i].brk > 0 || labels[i].item > 0, let open = openAt {
                labels[open].quoteOpens = false
                openAt = nil
            }
            if labels[i].quoteOpens {
                if let open = openAt { labels[open].quoteOpens = false }
                openAt = i
            }
            if labels[i].quoteCloses {
                if openAt == nil { labels[i].quoteCloses = false } else { openAt = nil }
            }
        }
        if let open = openAt { labels[open].quoteOpens = false }
        return labels
    }

    /// Spoken formatting commands the model may drop. Everything else stays, whatever its drop score.
    static let commandWords: Set<String> = ["unquote", "bullet"]
    static let commandPairs: Set<[String]> = [["new", "line"], ["new", "paragraph"], ["next", "line"], ["end", "quote"],
                                              ["close", "quote"], ["open", "quote"], ["bullet", "point"]]
    static let leadIns: Set<String> = ["and", "then", "next", "finally", "lastly", "also", "for"]

    static let countLeads: Set<String> = ["number", "step", "question"]
    static let units = "one two three four five six seven eight nine".split(separator: " ").map(String.init)
    static let tens = "twenty thirty forty fifty sixty seventy eighty ninety".split(separator: " ").map(String.init)
    static let numbers: [String: Int] = {
        var table: [String: Int] = [:]
        for (i, word) in "one two three four five six seven eight nine ten".split(separator: " ").enumerated() { table[String(word)] = i + 1 }
        for (i, word) in "first second third fourth fifth sixth seventh eighth ninth tenth".split(separator: " ").enumerated() { table[String(word)] = i + 1 }
        for n in 1..<100 { table[String(n)] = n }
        for (i, word) in "eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(separator: " ").enumerated() {
            table[String(word)] = i + 11
        }
        for (i, ten) in tens.enumerated() {
            table[ten] = 20 + 10 * i
            for (n, unit) in units.enumerated() { table[ten + unit] = 20 + 10 * i + n + 1 }
        }
        return table
    }()

    /// The spoken count in front of a list item: the word just before it when it is a number or ordinal ("Second,"),
    /// with "number", "step" or "question" before that (`start`), and a lead-in such as "and" before that. A count that
    /// ends a sentence ("order two.") belongs to the item before, unless a lead word that starts a phrase makes it a
    /// phrase of its own ("Number four.", but not "Order number two.").
    struct SpokenCount { var word: Int, start: Int, leadIn: Int?, number: Int? }

    private static func spokenCount(before item: Int, keys: [String], words: [String], labels: [LayoutLabel]) -> SpokenCount? {
        func open(_ k: Int) -> Bool {
            k >= 0 && labels[k].item == 0 && ![".", "?", "!", ":", ";"].contains(split(words[k]).mark)
        }
        let j = item - 1
        guard j >= 0, labels[j].item == 0, counting.contains(keys[j]) else { return nil }
        func afterEnd(_ k: Int) -> Bool { k == 0 || [".", "?", "!", ":", ";"].contains(split(words[k - 1]).mark) }
        func startsPhrase(_ k: Int) -> Bool { afterEnd(k) || (leadIns.contains(keys[k - 1]) && afterEnd(k - 1)) }
        // "twenty one" is one count.
        let first = units.contains(keys[j]) && open(j - 1) && tens.contains(keys[j - 1]) ? j - 1 : j
        let led = !countLeads.contains(keys[j]) && open(first - 1) && countLeads.contains(keys[first - 1])
        guard open(j) || (led && startsPhrase(first - 1)) else { return nil }
        let start = led ? first - 1 : first
        return SpokenCount(word: j, start: start, leadIn: open(start - 1) && leadIns.contains(keys[start - 1]) ? start - 1 : nil,
                           number: numbers[first < j ? keys[first] + keys[j] : keys[j]])
    }

    /// Drops the spoken count in front of a list item, and its lead-in.
    private static func drop(_ count: SpokenCount, labels: inout [LayoutLabel]) {
        for k in count.start...count.word { labels[k].drop = true }
        if let leadIn = count.leadIn { labels[leadIn].drop = true }
    }

    /// Counting that starts partway ("Number four ... Number five") answers numbered questions: the spoken count stays,
    /// as "Number four:", and starts a paragraph.
    private static func keepCountAsParagraph(at item: Int, count: SpokenCount?, labels: inout [LayoutLabel]) {
        labels[item].item = 0
        labels[item].brk = 0
        labels[item].capital = true
        guard let count else {
            labels[item].brk = 2
            return
        }
        if labels[count.word].punct <= 1 { labels[count.word].punct = marks.firstIndex(of: ":")! }
        labels[count.leadIn ?? count.start].brk = 2
    }

    public static func render(words: [String], labels: [LayoutLabel]) -> String {
        var out = ""
        var number = 0
        var inList = false
        var first = true
        var previousMark = ""
        var previousHeardMark = "."
        var spokenNumber: Int?
        for (word, label) in zip(words, labels) {
            let parts = split(word)
            let heardAfterStop = [".", "?", "!"].contains(previousHeardMark)
            previousHeardMark = parts.mark
            if label.drop {
                if let value = numbers[key(parts.core)] {
                    let afterTens = spokenNumber.map { (20...90).contains($0) && $0 % 10 == 0 } ?? false
                    spokenNumber = afterTens && value < 10 ? spokenNumber! + value : value
                }
                continue
            }
            if parts.core.isEmpty { continue }
            var brk = label.brk
            if label.item > 0, !first, brk == 0 { brk = 1 }
            var separator = first ? "" : [" ", "\n", "\n\n"][brk]
            if label.item > 0 {
                number = spokenNumber ?? (inList ? number + 1 : 1)
                inList = true
                separator += label.item == 1 ? "\(number). " : "- "
            } else if brk > 0 {
                inList = false
            }
            var core = parts.core
            let startsSentence = first || brk > 0 || label.item > 0 || [".", "?", "!"].contains(previousMark)
                || (label.quoteOpens && [",", ":"].contains(previousMark))
            let rest = String(core.dropFirst())
            let plainWord = rest == rest.lowercased() && !iWords.contains(core.lowercased())
            if startsSentence {
                core = core.prefix(1).uppercased() + rest
            } else if heardAfterStop, plainWord, !label.capital {
                core = core.prefix(1).lowercased() + rest
            }
            let mark = marks[label.punct]
            previousMark = mark
            out += separator + (label.quoteOpens ? "\"" : "") + core + mark + (label.quoteCloses ? "\"" : "")
            first = false
            spokenNumber = nil
        }
        return out
    }
}

/// GPT-2 style byte-level BPE, the way RoBERTa's tokenizer encodes one word with a space added in front.
public struct ByteLevelBPE: Sendable {
    private struct Pair: Hashable { var a: String, b: String }
    private let vocab: [String: Int]
    private let ranks: [Pair: Int]
    private let unknown: Int

    private static let byteEncoder: [Character] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var n = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + n)
            n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bytes, chars) { table[b] = Character(UnicodeScalar(c)!) }
        return table
    }()

    private static let pieces = Pattern("'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")

    /// `merges` is merges.txt without its header, one "a b" pair per line, in rank order.
    public init(vocab: [String: Int], merges: [String]) {
        self.vocab = vocab
        var ranks: [Pair: Int] = [:]
        for (rank, line) in merges.enumerated() {
            let halves = line.split(separator: " ", maxSplits: 1)
            guard halves.count == 2 else { continue }
            ranks[Pair(a: String(halves[0]), b: String(halves[1]))] = rank
        }
        self.ranks = ranks
        unknown = vocab["<unk>"] ?? 3
    }

    public func ids(word: String) -> [Int] {
        let text = word.first?.isWhitespace == true ? word : " " + word
        return Self.pieces.all(text).flatMap { piece in
            bpe(String(piece.utf8.map { Self.byteEncoder[Int($0)] })).map { vocab[$0] ?? unknown }
        }
    }

    private func bpe(_ token: String) -> [String] {
        var parts = token.map(String.init)
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(parts.count - 1) {
                if let rank = ranks[Pair(a: parts[i], b: parts[i + 1])], rank < (best?.rank ?? .max) { best = (rank, i) }
            }
            guard let best else { break }
            let (a, b) = (parts[best.index], parts[best.index + 1])
            var merged: [String] = []
            var i = 0
            while i < parts.count {
                if i < parts.count - 1, parts[i] == a, parts[i + 1] == b {
                    merged.append(a + b)
                    i += 2
                } else {
                    merged.append(parts[i])
                    i += 1
                }
            }
            parts = merged
        }
        return parts
    }
}

/// One model input: token ids padded to the model's length, and for each position the word whose first piece it is.
public struct LayoutWindow: Equatable, Sendable {
    public var ids: [Int32]
    public var mask: [Int32]
    public var wordAt: [Int?]
}

public struct LayoutEncoder: Sendable {
    public let bpe: ByteLevelBPE
    public let config: FormatterConfig

    public init(bpe: ByteLevelBPE, config: FormatterConfig) { (self.bpe, self.config) = (bpe, config) }

    func pauseToken(_ gap: Double) -> Int? { config.pauseTokens.first { gap >= $0.seconds }?.id }

    /// The words in order, cut into windows that each fit the model. Each window starts with the app token, and its
    /// first word gets no pause marker, as in training.
    public func windows(words: [String], app: ProfileGroup?, gaps: [Double]?) -> [LayoutWindow] {
        let appID = config.appTokens[app?.rawValue ?? "unknown"] ?? config.appTokens["unknown"]!
        let limit = config.maxTokens
        var windows: [LayoutWindow] = []
        var ids: [Int] = [config.start, appID]
        var wordAt: [Int?] = [nil, nil]
        var wordsInWindow = 0
        func close() {
            ids.append(config.end)
            wordAt.append(nil)
            let padding = limit - ids.count
            windows.append(LayoutWindow(ids: (ids + [Int](repeating: config.pad, count: max(0, padding))).map(Int32.init),
                                        mask: [Int32](repeating: 1, count: ids.count) + [Int32](repeating: 0, count: max(0, padding)),
                                        wordAt: wordAt + [Int?](repeating: nil, count: max(0, padding))))
            ids = [config.start, appID]
            wordAt = [nil, nil]
            wordsInWindow = 0
        }
        for (i, word) in words.enumerated() {
            var pieces = Array(bpe.ids(word: word).prefix(limit - 3))
            var marker = wordsInWindow > 0 ? gaps.flatMap { i < $0.count ? pauseToken($0[i]) : nil } : nil
            if wordsInWindow > 0, ids.count + (marker == nil ? 0 : 1) + pieces.count + 1 > limit {
                close()
                marker = nil
                pieces = Array(bpe.ids(word: word).prefix(limit - 3))
            }
            if let marker {
                ids.append(marker)
                wordAt.append(nil)
            }
            ids += pieces
            wordAt += [i] + [Int?](repeating: nil, count: pieces.count - 1)
            wordsInWindow += 1
        }
        if wordsInWindow > 0 { close() }
        return windows
    }
}

public struct LayoutFormatter: Sendable {
    public let encoder: LayoutEncoder

    public init(encoder: LayoutEncoder) { self.encoder = encoder }

    /// `predict` takes one window's ids and mask and returns its logits, `maxTokens` rows of `WordScores.width`.
    public func format(_ text: String, app: ProfileGroup?, gaps: [Double]?,
                       predict: (_ ids: [Int32], _ mask: [Int32]) throws -> [Float]) rethrows -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return text }
        var scores = [WordScores](repeating: .unchanged, count: words.count)
        for window in encoder.windows(words: words, app: app, gaps: gaps) {
            let logits = try predict(window.ids, window.mask)
            for (position, word) in window.wordAt.enumerated() {
                guard let word else { continue }
                let start = position * WordScores.width
                scores[word] = WordScores(logits: logits[start..<start + WordScores.width])
            }
        }
        return SmartLayout.render(words: words, labels: SmartLayout.decide(words: words, scores: scores, cut: encoder.config.cut))
    }
}

/// The silence before each word of the finished text, from the decoder's timed pieces of the raw text. Nil when the
/// pieces don't spell the raw words.
public enum WordPauses {
    public static func before(text: String, raw: String, tokens: [TimedToken]) -> [Double]? {
        var spans: [(start: Double, end: Double)] = []
        for token in tokens {
            if token.text.hasPrefix(" ") || spans.isEmpty {
                spans.append((token.start, token.end))
            } else if token.text.contains(where: { $0.isLetter || $0.isNumber }) {
                spans[spans.count - 1].end = token.end
            }
        }
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard spans.count == rawWords.count else { return nil }
        let finalWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let finalKeys = finalWords.map { SmartLayout.key(SmartLayout.split($0).core) }
        let rawKeys = rawWords.map { SmartLayout.key(SmartLayout.split($0).core) }
        var toRaw = [Int?](repeating: nil, count: finalWords.count)
        for op in SequenceMatch.opcodes(finalKeys, rawKeys) where op.tag == .equal || (op.tag == .replace && op.a.count == op.b.count) {
            for (i, j) in zip(op.a, op.b) { toRaw[i] = j }
        }
        var gaps: [Double] = []
        var previousEnd: Double?
        for j in toRaw {
            guard let j else {
                gaps.append(0)
                continue
            }
            gaps.append(previousEnd.map { max(0, spans[j].start - $0) } ?? 0)
            previousEnd = spans[j].end
        }
        return gaps
    }
}

/// Python's difflib.SequenceMatcher with no junk heuristic, enough for `get_opcodes`, so word alignment matches the
/// training code's.
enum SequenceMatch {
    enum Tag { case equal, replace, delete, insert }
    struct Opcode { var tag: Tag; var a: Range<Int>; var b: Range<Int> }

    static func opcodes(_ a: [String], _ b: [String]) -> [Opcode] {
        var b2j: [String: [Int]] = [:]
        for (j, item) in b.enumerated() { b2j[item, default: []].append(j) }
        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var (besti, bestj, bestsize) = (alo, blo, 0)
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var newj2len: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
                }
                j2len = newj2len
            }
            return (besti, bestj, bestsize)
        }
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [(Int, Int, Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            blocks.append((i, j, k))
            if alo < i, blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi, j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        blocks.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var merged: [(Int, Int, Int)] = []
        for block in blocks {
            if let last = merged.last, last.0 + last.2 == block.0, last.1 + last.2 == block.1 {
                merged[merged.count - 1].2 += block.2
            } else {
                merged.append(block)
            }
        }
        merged.append((a.count, b.count, 0))
        var codes: [Opcode] = []
        var (i, j) = (0, 0)
        for (ai, bj, size) in merged {
            let tag: Tag? = i < ai && j < bj ? .replace : i < ai ? .delete : j < bj ? .insert : nil
            if let tag { codes.append(Opcode(tag: tag, a: i..<ai, b: j..<bj)) }
            (i, j) = (ai + size, bj + size)
            if size > 0 { codes.append(Opcode(tag: .equal, a: ai..<i, b: bj..<j)) }
        }
        return codes
    }
}
