import Testing
@testable import DictationCore

@Suite("HalftoneScope") struct HalftoneScopeTests {
    private let middle = HalftoneScope.middleRow
    private let last = HalftoneScope.lastColumn

    @Test func silenceLeavesOnlyADimMiddleRow() {
        for column in 0...last {
            #expect(HalftoneScope.lit(column: column, row: middle, voice: 0) > 0.05)
            #expect(HalftoneScope.lit(column: column, row: middle - 1, voice: 0) == 0)
            #expect(HalftoneScope.lit(column: column, row: middle + 3, voice: 0) == 0)
        }
    }

    @Test func louderVoiceReachesFartherFromTheMiddleAndIsSymmetric() {
        let quiet = HalftoneScope.lit(column: last, row: middle + 2, voice: 0.4)
        let loud = HalftoneScope.lit(column: last, row: middle + 2, voice: 0.9)
        #expect(loud > quiet)
        #expect(HalftoneScope.lit(column: last, row: middle + 2, voice: 0.6) == HalftoneScope.lit(column: last, row: middle - 2, voice: 0.6))
        #expect(HalftoneScope.lit(column: last, row: middle + 2, voice: 1) > 0.99)
        #expect(abs(HalftoneScope.lit(column: last, row: 0, voice: 1) - 0.5) < 1e-9)
    }

    @Test func olderColumnsAreDimmer() {
        #expect(HalftoneScope.lit(column: 0, row: middle, voice: 1) < HalftoneScope.lit(column: last, row: middle, voice: 1))
        #expect(abs(HalftoneScope.age(column: 0) - 0.45) < 1e-9)
        #expect(abs(HalftoneScope.age(column: last) - 1) < 1e-9)
    }

    @Test func newestColumnHasNoDelay() {
        #expect(HalftoneScope.delay(column: last) == 0)
        #expect(abs(HalftoneScope.delay(column: 0) - 14 * 0.045) < 1e-9)
    }

    @Test func finishingFadesTheVoiceAndOnlyRipplesTheMiddleRow() {
        let outer = HalftoneScope.brightness(column: 7, row: 0, voice: 1, spin: 1, time: 0.3, still: false)
        #expect(outer == 0)
        let a = HalftoneScope.brightness(column: 7, row: middle, voice: 1, spin: 1, time: 0.3, still: false)
        let b = HalftoneScope.brightness(column: 7, row: middle, voice: 1, spin: 1, time: 0.6, still: false)
        #expect(a != b)
        for value in [a, b] { #expect(value >= 0.2 && value <= 0.8) }
    }

    @Test func reduceMotionHoldsOneStillLevelOnTheMiddleRow() {
        let levels = (0..<20).map { HalftoneScope.brightness(column: $0 % 15, row: middle, voice: 0, spin: 1, time: Double($0) * 0.37, still: true) }
        #expect(Set(levels).count == 1)
        #expect(levels[0] > 0.2 && levels[0] < 0.5)
    }

    @Test func listeningIsUnaffectedByTheRipple() {
        let moving = HalftoneScope.brightness(column: 5, row: middle, voice: 0.5, spin: 0, time: 1.7, still: false)
        let still = HalftoneScope.brightness(column: 5, row: middle, voice: 0.5, spin: 0, time: 9.1, still: true)
        #expect(moving == still)
    }
}
