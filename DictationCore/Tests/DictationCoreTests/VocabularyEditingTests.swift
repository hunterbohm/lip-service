import Testing
@testable import DictationCore

@Suite("Vocabulary editing") struct VocabularyEditingTests {
    @Test func theBundledFileWritesBackByteForByte() {
        let vocabulary = Vocabulary.parse(Vocabulary.bundledDefault).vocabulary
        #expect(vocabulary.fileText(keepingHeaderOf: Vocabulary.bundledDefault) == Vocabulary.bundledDefault)
    }

    @Test func writtenFilesParseBackToTheSameVocabulary() {
        let vocabulary = Vocabulary(terms: [.init(text: "ProfitPilot"), .init(text: "Beehiiv", aliases: ["behive", "bee hive"]),
                                            .init(text: "Lee's Café", aliases: ["lees cafe"])],
                                    minSimilarity: 0.85)
        let (parsed, issues) = Vocabulary.parse(vocabulary.fileText(keepingHeaderOf: ""))
        #expect(issues.isEmpty)
        #expect(parsed == vocabulary)
    }

    @Test func keepsOnlyTheLeadingCommentBlock() {
        let handEdited = "# My names\r\n\n# Second comment\nHermes\n# a later comment\nCodex: codecs\n"
        let vocabulary = Vocabulary.parse(handEdited).vocabulary
        #expect(vocabulary.fileText(keepingHeaderOf: handEdited)
            == "# My names\n\n# Second comment\n@min-similarity 0.7\nHermes\nCodex: codecs\n")
    }

    @Test func savingAddsTrimsAndRenamesInPlace() throws {
        var vocabulary = Vocabulary(terms: [.init(text: "Hermes"), .init(text: "Codex")])
        try vocabulary.save(.init(text: "  HubSpot ", aliases: [" hub spot", "", "hubb spot "]), replacing: nil)
        #expect(vocabulary.terms.last == .init(text: "HubSpot", aliases: ["hub spot", "hubb spot"]))
        try vocabulary.save(.init(text: "Hermes Agent"), replacing: "Hermes")
        #expect(vocabulary.terms.map(\.text) == ["Hermes Agent", "Codex", "HubSpot"])
        try vocabulary.save(.init(text: "codex", aliases: ["codecs"]), replacing: "Codex")
        #expect(vocabulary.terms[1] == .init(text: "codex", aliases: ["codecs"]))
    }

    @Test func refusesTermsThatWouldNotReadBack() {
        var vocabulary = Vocabulary(terms: [.init(text: "Hermes")])
        let before = vocabulary
        #expect(throws: TermProblem.empty) { try vocabulary.save(.init(text: "  "), replacing: nil) }
        #expect(throws: TermProblem.colon) { try vocabulary.save(.init(text: "a:b"), replacing: nil) }
        #expect(throws: TermProblem.reservedStart) { try vocabulary.save(.init(text: "#tag"), replacing: nil) }
        #expect(throws: TermProblem.reservedStart) { try vocabulary.save(.init(text: "@min-similarity"), replacing: nil) }
        #expect(throws: TermProblem.multipleLines) { try vocabulary.save(.init(text: "two\nlines"), replacing: nil) }
        #expect(throws: TermProblem.duplicate("hermes")) { try vocabulary.save(.init(text: "hermes"), replacing: nil) }
        #expect(throws: TermProblem.commaInSpelling) { try vocabulary.save(.init(text: "HubSpot", aliases: ["a, b"]), replacing: nil) }
        #expect(vocabulary == before)
    }

    @Test func linesTheParserSkippedSurviveASave() {
        let handEdited = "# names\nHermes\n@min-similarity 2\nhermes\nCodex:\n"
        var vocabulary = Vocabulary.parse(handEdited).vocabulary
        vocabulary.terms.append(.init(text: "HubSpot"))
        let written = vocabulary.fileText(keepingHeaderOf: handEdited)
        #expect(written == "# names\n@min-similarity 0.7\nHermes\nHubSpot\n@min-similarity 2\nhermes\nCodex:\n")
        #expect(Vocabulary.parse(written).vocabulary == vocabulary)
    }

    @Test func aFileSavedWithWindowsLineEndingsReadsLineByLine() {
        let (vocabulary, issues) = Vocabulary.parse("# names\r\nHermes\r\nBeehiiv: behive\r\nhermes\r\n")
        #expect(vocabulary.terms == [.init(text: "Hermes"), .init(text: "Beehiiv", aliases: ["behive"])])
        #expect(issues.map(\.line) == [4])
    }

    @Test func theSpellingsFieldSplitsOnCommas() {
        #expect(Vocabulary.aliases(fromField: " behive,, bee hive ,") == ["behive", "bee hive"])
    }
}
