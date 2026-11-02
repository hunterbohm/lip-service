import Foundation

/// Saved text that a spoken cue stands for. Saying the cue on its own inserts the text exactly as saved.
public struct Snippet: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var cue: String
    public var text: String

    public init(id: UUID = UUID(), cue: String, text: String) { (self.id, self.cue, self.text) = (id, cue, text) }
}

public enum SnippetProblem: Error, Equatable, Sendable {
    case emptyCue, emptyText
    case duplicate(String)

    public var message: String {
        switch self {
        case .emptyCue: "Enter what you will say."
        case .emptyText: "Enter the text to insert."
        case .duplicate(let cue): "Another snippet already uses “\(cue)”."
        }
    }
}

public enum Snippets {
    /// The snippet whose cue is the whole dictation, ignoring case, punctuation and the spaces around it.
    public static func match(_ dictated: String, in snippets: [Snippet]) -> Snippet? {
        let spoken = key(dictated)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { key($0.cue) == spoken }
    }

    /// Adds the snippet, or puts it in place of the one with its id. The cue is trimmed. The text is kept as typed.
    public static func save(_ snippet: Snippet, in snippets: inout [Snippet]) throws(SnippetProblem) {
        let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key(cue).isEmpty { throw .emptyCue }
        if snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyText }
        if snippets.contains(where: { $0.id != snippet.id && key($0.cue) == key(cue) }) { throw .duplicate(cue) }
        let saved = Snippet(id: snippet.id, cue: cue, text: snippet.text)
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = saved } else { snippets.append(saved) }
    }

    /// Lowercase letters and digits, one space between words. Apostrophes join, so "what's" and "whats" are one cue.
    static func key(_ text: String) -> String {
        let spaced = text.lowercased().compactMap { character -> Character? in
            if character == "'" || character == "’" { return nil }
            return character.isLetter || character.isNumber ? character : " "
        }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }
}
