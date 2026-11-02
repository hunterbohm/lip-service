import Foundation

/// A dictation as it landed in a field: the field's whole text right after the paste, and where the pasted text sits.
public struct PastedSpan: Equatable, Sendable {
    public var value: String
    /// Where the pasted text starts in `value`, in UTF-16 units, as Accessibility counts.
    public var location: Int
    public var inserted: String

    public init(value: String, location: Int, inserted: String) {
        (self.value, self.location, self.inserted) = (value, location, inserted)
    }
}

/// Learns a word from the user's own fix: when exactly one word of a dictation was replaced by another that looks or
/// sounds like it, the new word goes into the dictionary, with the old one as a misheard spelling unless it is a real
/// word.
public enum FixLearning {
    /// The word the user typed over one dictated word, with the word it replaced. Nil unless the only change to the
    /// field since the paste is one word inside the pasted text swapped for a different word, with a word of the
    /// dictation left unchanged beside it. That last rule turns away a whole field replaced, such as a sent message
    /// followed by a new one.
    public static func fix(of span: PastedSpan, now current: String) -> (old: String, new: String)? {
        guard span.location >= 0, span.location <= span.value.utf16.count else { return nil }
        let old = Array(span.value), new = Array(current)
        let start = span.value.distance(from: span.value.startIndex, to: String.Index(utf16Offset: span.location, in: span.value))
        let end = start + span.inserted.count
        guard end <= old.count, String(old[start..<end]) == span.inserted, old != new else { return nil }
        var prefix = zip(old, new).prefix { $0.0 == $0.1 }.count
        var suffix = zip(old.reversed(), new.reversed()).prefix { $0.0 == $0.1 }.count
        suffix = min(suffix, old.count - prefix, new.count - prefix)
        while prefix > 0, isWordCharacter(old[prefix - 1]) { prefix -= 1 }
        while suffix > 0, isWordCharacter(old[old.count - suffix]) { suffix -= 1 }
        guard prefix >= start, old.count - suffix <= end,
              (old[start..<prefix] + old[(old.count - suffix)..<end]).contains(where: isWordCharacter)
        else { return nil }
        let replaced = words(old[prefix..<(old.count - suffix)]), typed = words(new[prefix..<(new.count - suffix)])
        guard replaced.count == 1, typed.count == 1, replaced[0].lowercased() != typed[0].lowercased() else { return nil }
        return (replaced[0], typed[0])
    }

    /// The term to add for the fix, or nil when the new word is short, common, already in the dictionary, or not
    /// close enough to the old one. An old word that `isWord` knows, such as "more" fixed to "Moore", is not kept as a
    /// misheard spelling, since it would replace the everyday word in every dictation.
    public static func learn(from span: PastedSpan, now current: String, vocabulary: Vocabulary,
                             isWord: (String) -> Bool) -> Vocabulary.Term? {
        guard let fix = fix(of: span, now: current), fix.new.filter(\.isLetter).count >= 3, !CommonWords.contains(fix.new),
              !vocabulary.terms.contains(where: { $0.text.lowercased() == fix.new.lowercased() }), similar(fix.old, fix.new)
        else { return nil }
        return Vocabulary.Term(text: fix.new, aliases: isWord(fix.old) ? [] : [fix.old.lowercased()])
    }

    /// Looks alike, within half its letters by edit distance, or sounds alike, the same Soundex code.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter(\.isLetter)), y = Array(b.lowercased().filter(\.isLetter))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if Double(editDistance(x, y)) / Double(max(x.count, y.count)) <= 0.5 { return true }
        return soundex(x) == soundex(y)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    /// Words with the punctuation around them taken off.
    private static func words(_ characters: ArraySlice<Character>) -> [String] {
        String(characters).split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() { row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1))) }
            previous = row
        }
        return previous[b.count]
    }

    static func soundex(_ letters: [Character]) -> String {
        func code(_ c: Character) -> Character? {
            switch c {
            case "b", "f", "p", "v": "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": "2"
            case "d", "t": "3"
            case "l": "4"
            case "m", "n": "5"
            case "r": "6"
            default: nil
            }
        }
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased(), last = code(first)
        for c in letters.dropFirst() {
            let digit = code(c)
            if let digit, digit != last { result.append(digit) }
            if c != "h" && c != "w" { last = digit }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
