import Foundation

public enum SmartSpacing {
    private static let brackets: Set<Character> = ["(", "[", "{", "<", "“", "‘", "«"]
    private static let straightQuotes: Set<Character> = ["\"", "'", "`"]

    /// `preceding` is nil when the field could not be read, and empty at the start of the field.
    public static func adjust(_ text: String, after preceding: String?, properNouns: [String]) -> String {
        guard let preceding, let last = preceding.last, let first = text.first else { return text }
        var result = text
        let continuesSentence = preceding.reversed().first { $0 != " " && $0 != "\t" }
            .map { $0.isLetter || $0.isNumber || $0 == "," } ?? false
        if continuesSentence, shouldLowercase(text, properNouns: properNouns) {
            result = result.prefix(1).lowercased() + result.dropFirst()
        }
        if !last.isWhitespace, !opens(preceding), !first.isWhitespace {
            result = " " + result
        }
        return result
    }

    /// A straight quote opens only where a word could start, so `"yes"` and `dogs'` still get a space after them.
    private static func opens(_ preceding: String) -> Bool {
        guard let last = preceding.last else { return false }
        if brackets.contains(last) { return true }
        guard straightQuotes.contains(last) else { return false }
        guard let before = preceding.dropLast().last else { return true }
        return before.isWhitespace || brackets.contains(before)
    }

    private static func shouldLowercase(_ text: String, properNouns: [String]) -> Bool {
        let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard let first = word.first, first.isUppercase else { return false }
        let letters = word.filter(\.isLetter)
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false }
        if letters.dropFirst().contains(where: \.isUppercase) { return false }
        return !properNouns.contains { noun in
            text.hasPrefix(noun) && text.dropFirst(noun.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
        }
    }
}
