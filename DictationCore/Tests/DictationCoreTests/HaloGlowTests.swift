import Foundation
import Testing
@testable import DictationCore

@Suite("HaloGlow") struct HaloGlowTests {
    private let width = 300.0, height = 40.0
    private let dots = HaloGlow.dots(capsuleWidth: 300, capsuleHeight: 40)
    private var printX: Double { 18 + HalftonePrint.width / 2 }

    private func distanceToOutline(_ dot: HaloGlow.Dot) -> Double {
        let radius = height / 2
        return hypot(max(radius - dot.x, 0, dot.x - (width - radius)), dot.y - radius) - radius
    }

    @Test func everyDotIsOutsideTheCapsuleAndWithinReach() {
        #expect(dots.count > 300)
        for dot in dots {
            let edge = distanceToOutline(dot)
            #expect(edge >= 2 - 1e-9 && edge <= 26 + 1e-9)
        }
    }

    @Test func dotsSitOnAHexGridThatStartsAtTheCapsulesCorner() {
        let rows = Set(dots.map(\.y)).sorted()
        #expect(rows[0] >= -26 && rows.last! <= height + 26)
        for dot in dots {
            let row = Int(((dot.y + 26) / (5 * 0.866)).rounded())
            let shift = row % 2 == 1 ? 2.5 : 0
            #expect(abs((dot.x + 26 - shift) / 5 - ((dot.x + 26 - shift) / 5).rounded()) < 1e-9)
        }
    }

    @Test func theGridMovesWithTheCapsuleNotTheScreen() {
        let narrow = HaloGlow.dots(capsuleWidth: 300, capsuleHeight: height)
        let wide = HaloGlow.dots(capsuleWidth: 420, capsuleHeight: height)
        let wideLeft = Set(wide.filter { $0.x < 100 }.map { [$0.x, $0.y, $0.delay, $0.weight] })
        let narrowLeft = Set(narrow.filter { $0.x < 100 }.map { [$0.x, $0.y, $0.delay, $0.weight] })
        #expect(!narrowLeft.isEmpty && narrowLeft == wideLeft)
        #expect(wide.map(\.x).max()! > narrow.map(\.x).max()! + 100)
    }

    @Test func lightFallsWithDistanceFromTheOutline() {
        let columns = Dictionary(grouping: dots.filter { $0.y < 0 && $0.x > printX }, by: \.x)
        #expect(!columns.isEmpty)
        for (_, column) in columns where column.count > 1 {
            let nearToFar = column.sorted { $0.y > $1.y }
            for (near, far) in zip(nearToFar, nearToFar.dropFirst()) {
                #expect(HaloGlow.strength(of: far, glow: 1) < HaloGlow.strength(of: near, glow: 1))
            }
        }
    }

    @Test func lightFallsWithDistanceFromThePrintAndArrivesLater() {
        let nearestRow = dots.filter { $0.y < 0 && $0.x > printX && $0.x < 260 }.map(\.y).max()!
        let along = dots.filter { $0.y == nearestRow && $0.x > printX }.sorted { $0.x < $1.x }
        #expect(along.count > 20)
        for (near, far) in zip(along, along.dropFirst()) {
            #expect(HaloGlow.strength(of: far, glow: 1) < HaloGlow.strength(of: near, glow: 1))
            #expect(far.delay > near.delay)
        }
        #expect(dots.allSatisfy { $0.delay >= 0 && $0.delay < LevelEnvelope.span })
        let nearest = dots.min { $0.delay < $1.delay }!
        #expect(nearest.delay < 0.06)
    }

    @Test func silenceStillLeavesTwelvePercentOfTheLight() {
        for dot in dots {
            #expect(abs(HaloGlow.strength(of: dot, glow: 0) - 0.12 * dot.weight) < 1e-12)
            #expect(abs(HaloGlow.strength(of: dot, glow: 1) - dot.weight) < 1e-12)
        }
        #expect(dots.contains { HaloGlow.strength(of: $0, glow: 0) >= HaloGlow.faintest })
    }

    @Test func noDotIsKeptThatNoVoiceCouldLight() {
        #expect(dots.allSatisfy { HaloGlow.strength(of: $0, glow: 1) >= HaloGlow.faintest })
    }

    @Test func strengthSetsRadiusAndOpacity() {
        #expect(abs(HaloGlow.radius(strength: 0) - 0.4) < 1e-12)
        #expect(abs(HaloGlow.radius(strength: 1) - 1.5) < 1e-12)
        #expect(abs(HaloGlow.opacity(strength: 0) - 0.05) < 1e-12)
        #expect(abs(HaloGlow.opacity(strength: 1) - 0.67) < 1e-12)
        #expect(HaloGlow.radius(strength: 0.5) > HaloGlow.radius(strength: 0.2))
        #expect(HaloGlow.opacity(strength: 0.5) > HaloGlow.opacity(strength: 0.2))
    }
}
