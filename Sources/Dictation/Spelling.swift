import AppKit
import DictationCore

/// macOS's English spell checker, for the rules that must tell a real word from a misheard name. When the spell
/// service cannot be reached, as from an SSH session, the checker passes every word, so a nonsense probe tells that
/// apart and the built-in list of common words answers instead.
@MainActor enum Spelling {
    static func isWord(_ word: String) -> Bool { judge()(word) }

    /// The terms, lowercased, whose every word is a real word.
    static func everydayWords(_ terms: [String]) -> Set<String> {
        let isWord = judge()
        return Set(terms.filter { $0.split(separator: " ").allSatisfy { isWord(String($0)) } }.map { $0.lowercased() })
    }

    /// Asks the spell service once whether it answers, then judges words with it or with the common-word list.
    private static func judge() -> (String) -> Bool {
        let checkerWorks = !passes("qzxwvkjh")
        return { word in
            let lowered = word.lowercased()
            guard lowered.contains(where: \.isLetter) else { return false }
            return checkerWorks ? passes(lowered) : CommonWords.contains(lowered)
        }
    }

    private static func passes(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0,
                                            wordCount: nil).location == NSNotFound
    }
}
