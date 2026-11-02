import Foundation

/// Text read from the screen when a dictation starts.
public struct ScreenText: Equatable, Sendable {
    public var text: String
    /// How far it sits from the focused field, in points, 0 for the field itself.
    public var distance: Double
    /// The cursor's place in `text`, in characters, when this is the focused field.
    public var cursor: Int?

    public init(text: String, distance: Double, cursor: Int? = nil) {
        (self.text, self.distance, self.cursor) = (text, distance, cursor)
    }
}

/// Names likely to be said next, taken from text on the screen: capitalized words that are not common words, @handles,
/// and words with a capital inside such as ProfitPilot. They boost one dictation only. A run of two or three capitalized
/// words, such as a full name on its own line, vouches for each of its words, but the run itself is not a name to boost:
/// on the bench clips, "Sarah Chen" turned the spoken "Sarah, the" into "Sarah Chen", and its single words changed
/// nothing.
public enum ScreenNames {
    public static let limit = 30

    /// Nearest the cursor first, at most `limit`, leaving out `known` words such as the dictionary's.
    public static func extract(_ texts: [ScreenText], excluding known: [String], limit: Int = limit) -> [String] {
        let skip = Set(known.map { $0.lowercased() })
        var found: [(name: String, distance: Double, offset: Int)] = []
        for text in texts {
            for candidate in candidates(in: text.text) {
                let offset = text.cursor.map { abs(candidate.offset - $0) } ?? candidate.offset
                found.append((candidate.name, text.distance, offset))
            }
        }
        found.sort { ($0.distance, $0.offset) < ($1.distance, $1.offset) }
        var seen = skip
        var names: [String] = []
        for candidate in found where names.count < limit && seen.insert(candidate.name.lowercased()).inserted {
            names.append(candidate.name)
        }
        return names
    }

    private struct Token {
        var word: String
        var offset: Int
        /// Punctuation or a line break came before it, so it starts a new run.
        var afterBreak: Bool
        /// The first word of its text, or the first after ".", "!", "?", ":" or a line break, where a common word has a
        /// capital too.
        var startsSentence: Bool
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":"]

    /// Characters that end a run of capitalized words.
    private static let breaks: Set<Character> = [".", "!", "?", ",", ";", ":", "|", "•", "·", "—", "–", "(", ")", "[", "]",
                                                 "{", "}", "\"", "“", "”", "/", "#", "*", "<", ">", "="]

    static func candidates(in text: String) -> [(name: String, offset: Int)] {
        var result: [(name: String, offset: Int)] = []
        var run: [Token] = []
        func flush() {
            result += names(fromRun: run)
            run = []
        }
        for token in tokens(text) {
            if token.afterBreak { flush() }
            if token.word.hasPrefix("@") {
                flush()
                if let handle = handle(token.word) { result.append((handle, token.offset)) }
            } else if isCapitalized(token.word) {
                run.append(token)
            } else {
                flush()
                if hasInnerCapital(token.word), !CommonWords.contains(token.word) { result.append((token.word, token.offset)) }
            }
        }
        flush()
        return result
    }

    /// Common words at either end come off, so "Thanks Theo" gives Theo. Each word left that is not common is a name.
    /// One word left that starts its sentence is dropped, since its capital may only mark the sentence: the same name
    /// mid-sentence, or beside a surname, still counts.
    private static func names(fromRun run: [Token]) -> [(name: String, offset: Int)] {
        var words = run[...]
        while let first = words.first, CommonWords.contains(first.word) { words = words.dropFirst() }
        while let last = words.last, CommonWords.contains(last.word) { words = words.dropLast() }
        guard let first = words.first else { return [] }
        if words.count == 1, first.startsSentence, !hasInnerCapital(first.word) { return [] }
        var names: [(name: String, offset: Int)] = []
        for token in words where !CommonWords.contains(token.word) { names.append((token.word, token.offset)) }
        return names
    }

    /// "@theo" gives Theo. A handle with digits or other marks in it is not something people say.
    private static func handle(_ word: String) -> String? {
        let name = word.dropFirst()
        guard name.count >= 3, name.allSatisfy(\.isLetter), !CommonWords.contains(String(name)) else { return nil }
        return name.allSatisfy(\.isLowercase) ? name.prefix(1).uppercased() + name.dropFirst() : String(name)
    }

    /// An upper-case first letter and a lower-case letter after it, so ALL-CAPS labels are left out.
    private static func isCapitalized(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase, word.count >= 2 else { return false }
        return word.dropFirst().contains(where: \.isLowercase)
    }

    private static func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    /// Words of letters, with inner apostrophes and hyphens, or an @ in front. A word with a digit is dropped.
    private static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = "", start = 0, broke = true, sentence = true, hasDigit = false
        func finish() {
            let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            if !word.isEmpty, !hasDigit, word != "@" {
                tokens.append(Token(word: word, offset: start, afterBreak: broke, startsSentence: sentence))
            }
            if !current.isEmpty { (broke, sentence) = (hasDigit, false) }
            current = ""
            hasDigit = false
        }
        for (offset, character) in text.enumerated() {
            if character.isLetter || character.isNumber || ((character == "'" || character == "’" || character == "-") && !current.isEmpty)
                || (character == "@" && current.isEmpty) {
                if current.isEmpty { start = offset }
                if character.isNumber { hasDigit = true }
                current.append(character)
            } else {
                finish()
                if character.isNewline || breaks.contains(character) { broke = true }
                if character.isNewline || sentenceEnds.contains(character) { sentence = true }
            }
        }
        finish()
        return tokens
    }
}
