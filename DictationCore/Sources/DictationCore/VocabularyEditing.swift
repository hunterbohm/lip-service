import Foundation

public enum TermProblem: Error, Equatable, Sendable {
    case empty, multipleLines, colon, reservedStart, commaInSpelling
    case duplicate(String)

    public var message: String {
        switch self {
        case .empty: "Enter a word."
        case .multipleLines: "Use one line."
        case .colon: "A word can't contain a colon."
        case .reservedStart: "A word can't start with # or @."
        case .commaInSpelling: "Separate misheard spellings with commas."
        case .duplicate(let word): "\(word) is already in the dictionary."
        }
    }
}

extension Vocabulary {
    /// Keeps the leading comment and blank lines of `existing`, and every line `parse` skipped in it, so a hand
    /// edit that does not read yet is not lost. Comments further down are not kept.
    public func fileText(keepingHeaderOf existing: String) -> String {
        let existingLines = existing.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var lines = Array(existingLines.prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        })
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines.append("@min-similarity \(minSimilarity)")
        lines += terms.map { $0.aliases.isEmpty ? $0.text : "\($0.text): \($0.aliases.joined(separator: ", "))" }
        lines += Vocabulary.parse(existing).issues.map { existingLines[$0.line - 1] }
        return lines.joined(separator: "\n") + "\n"
    }

    public mutating func save(_ term: Term, replacing original: String?) throws(TermProblem) {
        let text = term.text.trimmingCharacters(in: .whitespaces)
        let aliases = term.aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if text.isEmpty { throw .empty }
        if text.contains(where: \.isNewline) || aliases.contains(where: { $0.contains(where: \.isNewline) }) {
            throw .multipleLines
        }
        if text.contains(":") { throw .colon }
        if text.hasPrefix("#") || text.hasPrefix("@") { throw .reservedStart }
        if aliases.contains(where: { $0.contains(",") }) { throw .commaInSpelling }
        let originalKey = original?.lowercased()
        if text.lowercased() != originalKey, terms.contains(where: { $0.text.lowercased() == text.lowercased() }) {
            throw .duplicate(text)
        }
        let saved = Term(text: text, aliases: aliases)
        if let index = terms.firstIndex(where: { $0.text.lowercased() == originalKey }) {
            terms[index] = saved
        } else {
            terms.append(saved)
        }
    }

    public static func aliases(fromField field: String) -> [String] {
        field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
