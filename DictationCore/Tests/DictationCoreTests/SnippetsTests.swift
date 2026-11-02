import Foundation
import Testing
@testable import DictationCore

@Suite("Snippets") struct SnippetsTests {
    private static let address = Snippet(cue: "my address", text: "Hunter Bohm\n123 Main Street\nAustin, TX 78701\n")
    private static let email = Snippet(cue: "What's my email", text: "hunter@example.com")

    @Test func theWholeDictationMatchesDespiteCaseAndPunctuation() {
        #expect(Snippets.match("My address.", in: [Self.address, Self.email]) == Self.address)
        #expect(Snippets.match("  my, address!  ", in: [Self.address]) == Self.address)
        #expect(Snippets.match("Whats my email?", in: [Self.address, Self.email]) == Self.email)
    }

    @Test func aPartialPhraseDoesNotMatch() {
        #expect(Snippets.match("Send my address to Sam.", in: [Self.address]) == nil)
        #expect(Snippets.match("My.", in: [Self.address]) == nil)
        #expect(Snippets.match(".", in: [Snippet(cue: "!", text: "x")]) == nil)
    }

    @Test func theSnippetGoesInVerbatimWithNoStyle() {
        var settings = Settings()
        settings.snippets = [Self.address, Snippet(cue: "thanks", text: "Thanks so much.")]
        let configuration = Configuration(settings: settings, vocabulary: Vocabulary(terms: []), issues: [])
        #expect(Insertion.make("My address.", app: "com.apple.MobileSMS", configuration: configuration)
            == Insertion(text: "Hunter Bohm\n123 Main Street\nAustin, TX 78701\n", source: .snippet))
        #expect(Insertion.make("Thanks.", app: "com.apple.MobileSMS", configuration: configuration).text == "Thanks so much.")
    }

    @Test func savingChecksTheCueAndKeepsTheText() throws {
        var snippets: [Snippet] = []
        try Snippets.save(Snippet(id: Self.address.id, cue: "  my address ", text: Self.address.text), in: &snippets)
        #expect(snippets == [Self.address])
        #expect(throws: SnippetProblem.duplicate("My Address")) {
            try Snippets.save(Snippet(cue: "My Address", text: "other"), in: &snippets)
        }
        #expect(throws: SnippetProblem.emptyCue) { try Snippets.save(Snippet(cue: " ?", text: "x"), in: &snippets) }
        #expect(throws: SnippetProblem.emptyText) { try Snippets.save(Snippet(cue: "sig", text: "\n "), in: &snippets) }
        try Snippets.save(Snippet(id: Self.address.id, cue: "home address", text: "Austin"), in: &snippets)
        #expect(snippets.map(\.cue) == ["home address"])
    }

    @Test func snippetsSurviveAStoreAndARead() throws {
        var settings = Settings()
        settings.snippets = [Self.address]
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).snippets == [Self.address])
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).snippets.isEmpty)
    }
}
