import Testing
@testable import DictationCore

@Suite("HalftonePrint") struct HalftonePrintTests {
    private let dots = HalftonePrint.dots
    private func cover(_ dot: HalftonePrint.Dot, voice: Double = 0, spin: Double = 0, light: HalftonePrint.Light = .still) -> Double {
        HalftonePrint.coverage(of: dot, voice: voice, spin: spin, light: light)
    }
    private func centre(nearest x: Double) -> HalftonePrint.Dot {
        dots.filter { $0.y == 0 }.min { abs($0.x - x) < abs($1.x - x) }!
    }

    @Test func theScreenIsADiagonalHalftoneInsideTheGlyph() {
        let column = 2.6 / 2.0.squareRoot(), row = 2.6 * 2.0.squareRoot()
        #expect(dots.allSatisfy { $0.x >= 1.5 && $0.x <= 45 - 1.5 && abs($0.y) <= 9.6 })
        let columns = Set(dots.map(\.x)).sorted()
        #expect(columns.count == 23)
        #expect(columns[0] == 1.5 && columns.last! > 45 - 1.5 - column)
        for (a, b) in zip(columns, columns.dropFirst()) { #expect(abs(b - a - column) < 1e-9) }
        let evenRows = dots.filter { $0.x == columns[0] }.map(\.y).sorted()
        let oddRows = dots.filter { $0.x == columns[1] }.map(\.y).sorted()
        for (a, b) in zip(evenRows, evenRows.dropFirst()) { #expect(abs(b - a - row) < 1e-9) }
        #expect(evenRows.contains { abs($0) < 1e-9 })
        #expect(oddRows.allSatisfy { abs(abs($0) - row / 2) < 1e-9 || abs(abs($0) - 1.5 * row) < 1e-9 || abs(abs($0) - 2.5 * row) < 1e-9 })
    }

    @Test func silenceLeavesAThinBaseline() {
        let left = dots.filter { $0.x < 20 }
        for dot in left where dot.y == 0 { #expect(cover(dot) > 0.85) }
        for dot in left where abs(dot.y) > 2.5 { #expect(cover(dot) == 0) }
        let drawn = left.filter { HalftonePrint.radius(coverage: cover($0)) != nil }
        #expect(!drawn.isEmpty && drawn.allSatisfy { abs($0.y) < 2.5 })
    }

    @Test func voiceRaisesThePrintTallerThanTheBaseline() {
        let left = dots.filter { $0.x < 20 }
        let quiet = left.filter { abs($0.y) > 4 && cover($0) > 0.1 }
        let loud = left.filter { abs($0.y) > 4 && cover($0, voice: 1) > 0.1 }
        let half = left.filter { abs($0.y) > 4 && cover($0, voice: 0.5) > 0.1 }
        #expect(quiet.isEmpty)
        #expect(!half.isEmpty && half.count < loud.count)
        #expect(loud.map { abs($0.y) }.max()! > 7)
        #expect(cover(centre(nearest: 10), voice: 1) > 0.99)
    }

    @Test func thePrintIsSymmetricTopToBottom() {
        for dot in dots {
            let mirror = HalftonePrint.Dot(x: dot.x, y: -dot.y)
            #expect(dots.contains(mirror))
            for voice in [0.0, 0.5, 1] {
                #expect(cover(dot, voice: voice, spin: 0.4, light: .running(time: 0.3))
                    == cover(mirror, voice: voice, spin: 0.4, light: .running(time: 0.3)))
            }
        }
    }

    @Test func olderVoiceSitsToTheRight() {
        let delays = Set(dots.map(\.x)).sorted().map { HalftonePrint.Dot(x: $0, y: 0).delay }
        for (a, b) in zip(delays, delays.dropFirst()) { #expect(b > a) }
        #expect(abs(HalftonePrint.Dot(x: 7, y: 0).delay - 0.1) < 1e-12)
        #expect(delays[0] < 0.03 && delays.last! < 0.65)
    }

    @Test func thePrintThinsAsItReachesTheWords() {
        let arrives = Set(dots.map(\.x)).sorted().map { HalftonePrint.Dot(x: $0, y: 0).arrive }
        #expect(arrives.filter { $0 == 1 }.count > 10)
        for (a, b) in zip(arrives, arrives.dropFirst()) { #expect(b <= a) }
        #expect(arrives.last! < 0.3)
        #expect(cover(centre(nearest: 43), voice: 1) < 0.3 * cover(centre(nearest: 10), voice: 1))
    }

    @Test func finishingSettlesToABaselineAndALightCrossesIt() {
        let dot = centre(nearest: 20)
        let atDot = (dot.x - HalftonePrint.passStart) / HalftonePrint.passTravel / HalftonePrint.passRate
        let on = cover(dot, voice: 1, spin: 1, light: .running(time: atDot))
        let off = cover(dot, voice: 1, spin: 1, light: .running(time: atDot + 0.4))
        #expect(abs(on - 0.7) < 1e-6)
        #expect(abs(off - 0.16) < 1e-3)
        #expect(cover(dot, voice: 1, spin: 0, light: .running(time: atDot)) == cover(dot, voice: 1))
        let outer = HalftonePrint.Dot(x: dot.x, y: 8.48)
        #expect(cover(outer, voice: 1, spin: 1, light: .running(time: atDot)) < 1e-3)
        let half = cover(dot, voice: 1, spin: 0.5, light: .still)
        #expect(half > 0.45 && half < 0.55)
    }

    @Test func reduceMotionHoldsOneStillLevelAlongTheBaseline() {
        let baseline = dots.filter { $0.y == 0 }
        #expect(baseline.count > 10)
        let levels = baseline.map { cover($0, voice: 0, spin: 1, light: .still) }
        #expect(levels.allSatisfy { abs($0 - 0.16) < 1e-12 })
        let moving = cover(centre(nearest: 20), voice: 0, spin: 1, light: .running(time: 0.3))
        #expect(moving >= 0.16)
        #expect(dots.filter { abs($0.y) > 4 }.allSatisfy { cover($0, voice: 1, spin: 1, light: .still) < 0.01 })
    }

    @Test func radiusFollowsTheSquareRootAndSmallDotsAreSkipped() {
        #expect(HalftonePrint.radius(coverage: 0) == nil)
        #expect(HalftonePrint.radius(coverage: 0.01) == nil)
        #expect(abs(HalftonePrint.radius(coverage: 1)! - 1.0) < 1e-12)
        #expect(abs(HalftonePrint.radius(coverage: 0.25)! - 0.5) < 1e-12)
    }
}
