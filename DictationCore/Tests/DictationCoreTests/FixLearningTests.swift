import Testing
@testable import DictationCore

@Suite("Learns from your fixes") struct FixLearningTests {
    private static let before = "Notes: "
    private static let inserted = " Ask Shivon about the launch."
    private static let span = PastedSpan(value: before + inserted + "\nThanks", location: before.utf16.count, inserted: inserted)
    private static let dictionary = Vocabulary(terms: [.init(text: "ProfitPilot")])
    /// Stands in for the spell checker the app asks.
    private static let realWords: Set<String> = ["more", "steal", "their", "there"]
    private static func isWord(_ word: String) -> Bool { realWords.contains(word.lowercased()) }

    private static func learned(_ current: String, vocabulary: Vocabulary = dictionary) -> Vocabulary.Term? {
        FixLearning.learn(from: span, now: current, vocabulary: vocabulary, isWord: isWord)
    }

    @Test func aTypoFixLearnsTheWord() {
        #expect(Self.learned("Notes:  Ask Siobhan about the launch.\nThanks") == .init(text: "Siobhan", aliases: ["shivon"]))
    }

    @Test func aFixWithItsPunctuationChangedStillLearns() {
        let span = PastedSpan(value: "Ping Teo, then ship.", location: 0, inserted: "Ping Teo, then ship.")
        #expect(FixLearning.learn(from: span, now: "Ping Theo then ship.", vocabulary: Self.dictionary, isWord: Self.isWord) == .init(text: "Theo", aliases: ["teo"]))
    }

    @Test func aRewriteOfSeveralWordsLearnsNothing() {
        #expect(Self.learned("Notes:  Tell Siobhan we launch Friday.\nThanks") == nil)
        #expect(Self.learned("Notes:  Ask Siobhan about the plan.\nThanks") == nil)
    }

    @Test func aCommonWordSwapLearnsNothing() {
        let span = PastedSpan(value: "Meet me their at noon.", location: 0, inserted: "Meet me their at noon.")
        #expect(FixLearning.learn(from: span, now: "Meet me there at noon.", vocabulary: Self.dictionary, isWord: Self.isWord) == nil)
    }

    @Test func aCaseOnlyChangeLearnsNothing() {
        #expect(Self.learned("Notes:  Ask shivon about the launch.\nThanks") == nil)
        #expect(Self.learned("Notes:  Ask SHIVON about the launch.\nThanks") == nil)
    }

    @Test func aWordAlreadyInTheDictionaryOrTooShortOrUnlikeLearnsNothing() {
        #expect(Self.learned("Notes:  Ask Siobhan about the launch.\nThanks",
                             vocabulary: Vocabulary(terms: [.init(text: "siobhan")])) == nil)
        #expect(Self.learned("Notes:  Ask Sv about the launch.\nThanks") == nil)
        #expect(Self.learned("Notes:  Ask Marcus about the launch.\nThanks") == nil)
    }

    @Test func aChangeOutsideTheDictationLearnsNothing() {
        #expect(Self.learned("Nodes:  Ask Shivon about the launch.\nThanks") == nil)
        #expect(Self.learned("Notes:  Ask Shivon about the launch.\nThank Siobhan") == nil)
        #expect(Self.learned("") == nil)
    }

    @Test func aCommonOldWordIsNotKeptAsAMisheardSpelling() {
        let span = PastedSpan(value: "Email Sam more today.", location: 0, inserted: "Email Sam more today.")
        #expect(FixLearning.learn(from: span, now: "Email Sam Moore today.", vocabulary: Self.dictionary, isWord: Self.isWord)
            == .init(text: "Moore", aliases: []))
    }

    @Test func aRealOldWordIsNotKeptAsAMisheardSpelling() {
        let span = PastedSpan(value: "Email Sam steal today.", location: 0, inserted: "Email Sam steal today.")
        #expect(FixLearning.learn(from: span, now: "Email Sam Steele today.", vocabulary: Self.dictionary, isWord: Self.isWord)
            == .init(text: "Steele", aliases: []))
    }

    @Test func aWholeFieldReplacedLearnsNothing() {
        let sent = PastedSpan(value: "Shivon?", location: 0, inserted: "Shivon?")
        #expect(FixLearning.learn(from: sent, now: "Siobhan?", vocabulary: Self.dictionary, isWord: Self.isWord) == nil)
        let afterNotes = PastedSpan(value: "Notes: Shivon", location: 6, inserted: " Shivon")
        #expect(FixLearning.learn(from: afterNotes, now: "Notes: Siobhan", vocabulary: Self.dictionary, isWord: Self.isWord) == nil)
    }

    @Test func similarWordsLookOrSoundAlike() {
        #expect(FixLearning.similar("Shivon", "Siobhan"))
        #expect(FixLearning.similar("Teo", "Theo"))
        #expect(FixLearning.similar("christine", "Kristin"))
        #expect(!FixLearning.similar("Shivon", "Marcus"))
        #expect(!FixLearning.similar("cat", "Delacroix"))
    }
}

@Suite("Learned notice") struct LearnedNoticeTests {
    @Test func theNoticeNamesTheWordAndOffersUndo() {
        let notice = BarNotice.learned("Siobhan")
        #expect(notice.title == "Learned Siobhan")
        #expect(notice.action == .undoLearned)
        #expect(BarToastAction.undoLearned.title == "Undo")
        #expect(notice.tone == .info)
        #expect(notice.outlastsNextDictation)
        #expect(!BarNotice.copied(.focusMoved).outlastsNextDictation)
    }
}
