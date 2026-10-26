import Testing
@testable import DictationCore

@Suite("Smart spacing") struct SmartSpacingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var before: String?
        var text: String
        var expected: String
        var testDescription: String { "\(before.map { "\"\($0)\"" } ?? "unreadable") + \"\(text)\"" }
    }

    static let cases: [Case] = [
        Case(before: "I said", text: "Hello there.", expected: " hello there."),
        Case(before: "I said ", text: "Hello there.", expected: "hello there."),
        Case(before: "First,", text: "Then we ship.", expected: " then we ship."),
        Case(before: "Room 12", text: "Has a view.", expected: " has a view."),
        Case(before: "Done.", text: "Next one.", expected: " Next one."),
        Case(before: "Done. ", text: "Next one.", expected: "Next one."),
        Case(before: "Really?", text: "Yes.", expected: " Yes."),
        Case(before: "Note:", text: "Bring it.", expected: " Bring it."),
        Case(before: "call (", text: "Maybe later.", expected: "Maybe later."),
        Case(before: "he said “", text: "Go.", expected: "Go."),
        Case(before: "she said \"", text: "Stop.", expected: "Stop."),
        Case(before: "first line\n", text: "Second line.", expected: "Second line."),
        Case(before: "word\t", text: "Next.", expected: "next."),
        Case(before: "", text: "Start here.", expected: "Start here."),
        Case(before: nil, text: "Terminal text.", expected: "Terminal text."),
        Case(before: "and", text: "I think so.", expected: " I think so."),
        Case(before: "and", text: "I'm here.", expected: " I'm here."),
        Case(before: "and", text: "I’ll go.", expected: " I’ll go."),
        Case(before: "so", text: "OK, ship it.", expected: " OK, ship it."),
        Case(before: "open", text: "ProfitPilot now.", expected: " ProfitPilot now."),
        Case(before: "post it in", text: "Beehiiv today.", expected: " Beehiiv today."),
        Case(before: "post it in", text: "Beehiivs are odd.", expected: " beehiivs are odd."),
        Case(before: "meet on", text: "Friday then.", expected: " Friday then."),
        Case(before: "I saw", text: "A dog.", expected: " a dog."),
        Case(before: "He said \"yes\"", text: "Then we left.", expected: " Then we left."),
        Case(before: "the dogs'", text: "Bowls are full.", expected: " Bowls are full."),
        Case(before: "a note (\"", text: "Draft.", expected: "Draft."),
    ]

    @Test(arguments: cases)
    func adjustsToThePrecedingText(_ c: Case) {
        let nouns = ["Beehiiv"] + Cleanup.calendarNames
        #expect(SmartSpacing.adjust(c.text, after: c.before, properNouns: nouns) == c.expected)
    }

    @Test func emptyTextStaysEmpty() {
        #expect(SmartSpacing.adjust("", after: "word", properNouns: []) == "")
    }
}
