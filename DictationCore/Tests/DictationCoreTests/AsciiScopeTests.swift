import Testing
@testable import DictationCore

@Suite("ASCII scope") struct AsciiScopeTests {
    @Test func silenceIsAFlatBaselineNeverBlank() {
        let frame = AsciiScope.listening(peaks: [Float](repeating: 0, count: AsciiScope.columns))
        #expect(String(frame.cells) == String(repeating: "⣀", count: AsciiScope.columns))
        #expect(frame.lit == 0..<AsciiScope.columns)
        #expect(AsciiScope.resting == frame)
    }

    @Test func aCellRisesWithTheVoiceAndNeverFalls() {
        let heights: [Character] = ["⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿"]
        var previous = 0
        var seen = Set<Character>()
        for step in 0...100 {
            let cell = AsciiScope.cell(level: Float(step) / 100)
            let height = heights.firstIndex(of: cell)
            #expect(height != nil && height! >= previous)
            previous = height ?? previous
            seen.insert(cell)
        }
        #expect(seen == Set(heights), "every step of the ramp shows somewhere between silence and full")
    }

    @Test func aHalfLevelStandsClearOfTheBaselineAndBelowFull() {
        #expect(AsciiScope.cell(level: 0.5) != AsciiScope.baseline)
        #expect(AsciiScope.cell(level: 0.5) != AsciiScope.cell(level: 0.95))
    }

    @Test func outOfRangeLevelsClamp() {
        #expect(AsciiScope.cell(level: -1) == "⣀" && AsciiScope.cell(level: 7) == "⣿")
    }

    @Test func theNewestVoiceIsAtTheRight() {
        let peaks = [Float](repeating: 0, count: AsciiScope.columns - 1) + [1]
        let cells = AsciiScope.listening(peaks: peaks).cells
        #expect(cells.last == "⣿" && cells.first == "⣀")
    }

    @Test func theSweepRunsToTheEndAndBack() {
        let n = AsciiScope.columns
        func lit(_ step: Int) -> Int { AsciiScope.transcribing(at: (Double(step) + 0.5) * AsciiScope.sweepStep).lit.lowerBound }
        #expect(lit(0) == 0 && lit(1) == 1 && lit(n - 1) == n - 1)
        #expect(lit(n) == n - 2 && lit(2 * n - 3) == 1)
        #expect(lit(2 * n - 2) == 0, "it turns round and starts over")
    }

    @Test func theSweepIsOneBrightCellOnADimBaseline() {
        let frame = AsciiScope.transcribing(at: 0.4)
        #expect(frame.cells.count == AsciiScope.columns && frame.lit.count == 1)
        #expect(frame.cells[frame.lit.lowerBound] == "⣤")
        #expect(frame.cells.enumerated().allSatisfy { $0.offset == frame.lit.lowerBound || $0.element == "⣀" })
    }

    @Test func withoutTimeTheSweepRestsInTheMiddle() {
        #expect(AsciiScope.transcribing(at: nil).lit == AsciiScope.columns / 2..<AsciiScope.columns / 2 + 1)
    }
}
