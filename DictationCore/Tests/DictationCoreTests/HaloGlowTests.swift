import Foundation
import Testing
@testable import DictationCore

@Suite("HaloGlow") struct HaloGlowTests {
    private let perimeter = HaloGlow.perimeter(capsuleWidth: 300, capsuleHeight: 40)

    @Test func perimeterIsTheRimsCentreLine() {
        let width = 303.0, height = 43.0
        #expect(abs(perimeter - (2 * (width - height) + .pi * height)) < 1e-9)
        #expect(HaloGlow.perimeter(capsuleWidth: 420, capsuleHeight: 40) > perimeter + 239)
    }

    @Test func glimmerSlicesRunTailToHeadAndGetBrighter() {
        let slices = HaloGlow.glimmer(at: 0.5, perimeter: perimeter)
        #expect(slices.count == HaloGlow.slices)
        for (earlier, later) in zip(slices, slices.dropFirst()) {
            #expect(later.light > earlier.light)
            #expect(abs(later.from - earlier.to) < 1e-9)
        }
        #expect(abs(slices.last!.light - 1) < 1e-12)
        #expect(abs(slices.last!.to - 150 / perimeter) < 1e-9)
        let covered = slices.reduce(0) { $0 + ($1.to - $1.from) }
        #expect(abs(covered * perimeter - HaloGlow.tail) < 1e-6)
    }

    @Test func glimmerMovesAtTheSameSpeedOnEveryBar() {
        let long = HaloGlow.perimeter(capsuleWidth: 560, capsuleHeight: 40)
        for p in [perimeter, long] {
            let a = HaloGlow.glimmer(at: 0.1, perimeter: p).last!.to * p
            let b = HaloGlow.glimmer(at: 0.2, perimeter: p).last!.to * p
            #expect(abs((b - a) - HaloGlow.speed * 0.1) < 1e-6)
        }
    }

    @Test func aSliceCrossingTheRimsStartIsSplit() {
        let slices = HaloGlow.glimmer(at: 0.2, perimeter: perimeter)
        #expect(slices.count > HaloGlow.slices)
        for slice in slices { #expect(slice.from >= 0 && slice.to <= 1 && slice.from < slice.to) }
        let covered = slices.reduce(0) { $0 + ($1.to - $1.from) }
        #expect(abs(covered * perimeter - HaloGlow.tail) < 1e-6)
    }

    @Test func glimmerNeverOutrunsAShortRim() {
        let slices = HaloGlow.glimmer(at: 1.3, perimeter: 100)
        let covered = slices.reduce(0) { $0 + ($1.to - $1.from) }
        #expect(abs(covered - 1) < 1e-9)
        #expect(HaloGlow.glimmer(at: 1, perimeter: 0).isEmpty)
    }

    @Test func silenceStillLeavesFortyPercentOfTheLight() {
        #expect(abs(HaloGlow.light(glow: 0) - 0.4) < 1e-12)
        #expect(abs(HaloGlow.light(glow: 1) - 1) < 1e-12)
        #expect(HaloGlow.light(glow: 2) == HaloGlow.light(glow: 1))
        #expect(HaloGlow.light(glow: -1) == HaloGlow.light(glow: 0))
    }

    @Test func lightBrightensTheRimAndWidensTheHaze() {
        for (dim, bright) in [(0.4, 1.0), (0.2, 0.6)] {
            #expect(HaloGlow.rimOpacity(light: bright) > HaloGlow.rimOpacity(light: dim))
            #expect(HaloGlow.hazeOpacity(light: bright) > HaloGlow.hazeOpacity(light: dim))
            #expect(HaloGlow.hazeRadius(light: bright) > HaloGlow.hazeRadius(light: dim))
        }
        #expect(HaloGlow.rimOpacity(light: 1) <= 1 && HaloGlow.hazeRadius(light: 1) < HaloGlow.reach)
    }
}
