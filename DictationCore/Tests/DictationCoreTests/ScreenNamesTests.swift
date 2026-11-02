import Testing
@testable import DictationCore

@Suite("Names from the screen") struct ScreenNamesTests {
    private static let slack = """
        # general
        Theo Browne  10:42 AM
        Hey @hunter, can you check the ProfitPilot dashboard before the standup? Ask Siobhan about the Beehiiv numbers.
        Sarah Chen  10:45 AM
        Thanks Theo, I'll ask Marcus too. 3 replies
        Message #general
        """

    private static let email = """
        Subject: Contract for the Austin office
        From: Priya Raman
        To: Hunter Bohm
        Hi Hunter,
        Following up on our call with Northwind Labs. Can you send the signed contract to Daniel O'Brien by Friday?
        Best,
        Priya
        """

    @Test func aChatGivesItsPeopleAndProducts() {
        let names = ScreenNames.extract([ScreenText(text: Self.slack, distance: 120)], excluding: ["Beehiiv"])
        for name in ["Theo", "Browne", "Hunter", "ProfitPilot", "Siobhan", "Sarah", "Chen", "Marcus"] {
            #expect(names.contains(name), "\(name) in \(names)")
        }
        for word in ["Hey", "Thanks", "Message", "AM", "Ask", "Beehiiv", "general", "3", "I", "Theo Browne"] {
            #expect(!names.contains(word), "\(word) in \(names)")
        }
    }

    @Test func anEmailGivesItsPeopleAndPlaces() {
        let names = ScreenNames.extract([ScreenText(text: Self.email, distance: 0, cursor: 0)], excluding: [])
        for name in ["Priya", "Raman", "Hunter", "Bohm", "Austin", "Northwind", "Daniel", "O'Brien"] {
            #expect(names.contains(name), "\(name) in \(names)")
        }
        for word in ["Subject", "Contract", "From", "To", "Hi", "Following", "Can", "Friday", "Best"] {
            #expect(!names.contains(word), "\(word) in \(names)")
        }
    }

    @Test func wordsInTheDictionaryAndCommonWordsAreLeftOut() {
        let names = ScreenNames.extract([ScreenText(text: "We met Will and Hermes at the New Office with Siobhan", distance: 0)],
                                        excluding: ["hermes"])
        #expect(names == ["Siobhan"])
    }

    @Test func theNearestComeFirstAndTheListStopsAtTheLimit() {
        let far = ScreenText(text: "ask Zelda", distance: 300)
        let field = ScreenText(text: "with Alvarez, then Brightwater and Corvina", distance: 0, cursor: 40)
        let title = ScreenText(text: "talk to Delacroix", distance: 1)
        #expect(ScreenNames.extract([far, field, title], excluding: []) == ["Corvina", "Brightwater", "Alvarez", "Delacroix", "Zelda"])
        #expect(ScreenNames.extract([far, field, title], excluding: [], limit: 2) == ["Corvina", "Brightwater"])
    }

    @Test func handlesAndInnerCapitalsCountAnywhere() {
        let names = ScreenNames.extract([ScreenText(text: "cc @theo and @here. Open macOS settings on the iPhone. @dev42", distance: 0)],
                                        excluding: [])
        #expect(names == ["Theo", "macOS", "iPhone"])
    }
}
