import Testing
@testable import DictationCore

@Suite("HalftoneLips") struct HalftoneLipsTests {
    private let dots = HalftoneLips.dots

    @Test func theScreenIsADiagonalHalftoneInsideTheGlyph() {
        let column = 2.4 / 2.0.squareRoot(), row = 2.4 * 2.0.squareRoot()
        #expect(dots.allSatisfy { $0.x >= 1.5 && $0.x <= 45 - 1.5 && abs($0.y) <= 9.6 && $0.u >= 0 && $0.u <= 1 })
        let columns = Set(dots.map(\.x)).sorted()
        #expect(columns.count == 25)
        for (a, b) in zip(columns, columns.dropFirst()) { #expect(abs(b - a - column) < 1e-9) }
        let evenRows = dots.filter { $0.x == columns[0] }.map(\.y).sorted()
        let oddRows = dots.filter { $0.x == columns[1] }.map(\.y).sorted()
        for (a, b) in zip(evenRows, evenRows.dropFirst()) { #expect(abs(b - a - row) < 1e-9) }
        #expect(evenRows.contains { abs($0) < 1e-9 })
        #expect(oddRows.allSatisfy { abs(abs($0) - row / 2) < 1e-9 || abs(abs($0) - 1.5 * row) < 1e-9 || abs(abs($0) - 2.5 * row) < 1e-9 })
    }

    @Test func lipsAreClosedAtSilence() {
        let nearest = dots.filter { abs($0.u - 0.5) < 0.05 && abs($0.y) < 2 }
        #expect(!nearest.isEmpty)
        for dot in nearest {
            let covered = HalftoneLips.coverage(of: dot, voice: 0, spin: 0, seam: .still)
            if dot.y == 0 { #expect(covered < 0.1) } else { #expect(covered > 0.9) }
        }
    }

    @Test func louderVoiceOpensAGapInTheMiddle() {
        let near = dots.filter { abs($0.u - 0.5) < 0.05 && abs($0.y) < 3.5 }
        #expect(!near.isEmpty)
        for dot in near { #expect(HalftoneLips.coverage(of: dot, voice: 1, spin: 0, seam: .still) == 0) }
        let quiet = dots.filter { abs($0.u - 0.5) < 0.05 && abs($0.y) > 6 && abs($0.y) < 7.5 }
        let wide = quiet.map { HalftoneLips.coverage(of: $0, voice: 1, spin: 0, seam: .still) }
        #expect(wide.contains { $0 > 0.9 })
    }

    @Test func cornersStayClosedWhereTheLipsMeet() {
        let corner = dots.filter { $0.u < 0.04 }
        let closed = corner.map { HalftoneLips.coverage(of: $0, voice: 0, spin: 0, seam: .still) }
        let open = corner.map { HalftoneLips.coverage(of: $0, voice: 1, spin: 0, seam: .still) }
        #expect(closed == open)
    }

    @Test func theLipsAreSymmetricTopToBottomAndLeftToRight() {
        for dot in dots {
            let mirror = HalftoneLips.Dot(x: dot.x, y: -dot.y)
            #expect(dots.contains(mirror))
            for voice in [0.0, 0.5, 1] {
                #expect(HalftoneLips.coverage(of: dot, voice: voice, spin: 0.4, seam: .running(time: 0.3))
                    == HalftoneLips.coverage(of: mirror, voice: voice, spin: 0.4, seam: .running(time: 0.3)))
            }
        }
        let left = HalftoneLips.Dot(x: 1.5 + 0.2 * HalftoneLips.length, y: 5.1)
        let right = HalftoneLips.Dot(x: 1.5 + 0.8 * HalftoneLips.length, y: 5.1)
        for voice in [0.0, 0.5, 1] {
            #expect(abs(HalftoneLips.coverage(of: left, voice: voice, spin: 0, seam: .still)
                - HalftoneLips.coverage(of: right, voice: voice, spin: 0, seam: .still)) < 1e-12)
        }
        #expect(abs(left.delay - right.delay) < 1e-12)
    }

    @Test func theMiddleOpensFirstAndTheCornersFollow() {
        let centre = HalftoneLips.Dot(x: 1.5 + 0.5 * HalftoneLips.length, y: 0)
        let corner = HalftoneLips.Dot(x: 1.5, y: 0)
        #expect(centre.delay == 0)
        #expect(abs(corner.delay - 0.08) < 1e-12)
    }

    @Test func finishingClosesTheLipsAndAnAdvancingLightRunsAlongTheSeam() {
        let seam = HalftoneLips.Dot(x: 1.5 + 0.5 * HalftoneLips.length, y: 0)
        let passing = 0.5 / 1.4
        let off = HalftoneLips.coverage(of: seam, voice: 1, spin: 1, seam: .running(time: 0.05))
        let on = HalftoneLips.coverage(of: seam, voice: 1, spin: 1, seam: .running(time: passing))
        #expect(on > 0.7 && on <= 0.8 + 1e-9)
        #expect(off < 0.05)
        #expect(HalftoneLips.coverage(of: seam, voice: 1, spin: 0, seam: .running(time: passing)) == 0)
        let outer = HalftoneLips.Dot(x: seam.x, y: 8.48)
        #expect(HalftoneLips.coverage(of: outer, voice: 1, spin: 1, seam: .running(time: passing)) < 1e-3)
        let later = HalftoneLips.Dot(x: 1.5 + 0.9 * HalftoneLips.length, y: 0)
        let before = HalftoneLips.coverage(of: later, voice: 1, spin: 1, seam: .running(time: passing))
        let during = HalftoneLips.coverage(of: later, voice: 1, spin: 1, seam: .running(time: 0.9 / 1.4))
        #expect(during > before + 0.2)
    }

    @Test func reduceMotionHoldsOneStillLevelOnTheSeam() {
        let seam = dots.filter { abs($0.y) < 0.1 && $0.shape > 0.99 }
        #expect(!seam.isEmpty)
        let levels = seam.map { HalftoneLips.coverage(of: $0, voice: 0, spin: 1, seam: .still) }
        #expect(Set(levels).count == 1)
        #expect(levels[0] > 0.2 && levels[0] < 0.5)
        let moving = HalftoneLips.coverage(of: seam[0], voice: 0, spin: 1, seam: .running(time: 0.5 / 1.4))
        #expect(moving > levels[0])
    }

    @Test func radiusFollowsTheSquareRootAndSmallDotsAreSkipped() {
        #expect(HalftoneLips.radius(coverage: 0) == nil)
        #expect(HalftoneLips.radius(coverage: 0.02) == nil)
        #expect(abs(HalftoneLips.radius(coverage: 1)! - 0.95) < 1e-12)
        #expect(abs(HalftoneLips.radius(coverage: 0.25)! - 0.475) < 1e-12)
    }
}
