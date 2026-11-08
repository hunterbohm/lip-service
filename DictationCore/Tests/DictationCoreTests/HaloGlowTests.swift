import Foundation
import Testing
@testable import DictationCore

@Suite("HaloGlow") struct HaloGlowTests {
    private let perimeter = HaloGlow.perimeter(capsuleWidth: 300, capsuleHeight: 40)

    private func covered(_ slices: [HaloGlow.Slice]) -> Double { slices.reduce(0) { $0 + ($1.to - $1.from) } }

    @Test func perimeterIsTheRimsCentreLine() {
        let width = 303.0, height = 43.0
        #expect(abs(perimeter - (2 * (width - height) + .pi * height)) < 1e-9)
        #expect(HaloGlow.perimeter(capsuleWidth: 420, capsuleHeight: 40) > perimeter + 239)
    }

    @Test func beamSlicesRunTailToHeadAndGetBrighter() {
        let slices = HaloGlow.beam(at: 0.6, perimeter: perimeter)
        #expect(slices.count == HaloGlow.slices)
        for (earlier, later) in zip(slices, slices.dropFirst()) {
            #expect(later.light > earlier.light && later.along > earlier.along)
            #expect(abs(later.from - earlier.to) < 1e-9)
        }
        #expect(abs(slices.last!.light - 1) < 1e-12 && slices.last!.along == 1)
        #expect(abs(slices.last!.to - 0.6 * HaloGlow.speed / perimeter) < 1e-9)
        #expect(abs(covered(slices) * perimeter - HaloGlow.tail) < 1e-6)
    }

    @Test func beamMovesAtTheSameSpeedOnEveryBar() {
        let long = HaloGlow.perimeter(capsuleWidth: 560, capsuleHeight: 40)
        for p in [perimeter, long] {
            let a = HaloGlow.beam(at: 0.6, perimeter: p).last!.to * p
            let b = HaloGlow.beam(at: 0.7, perimeter: p).last!.to * p
            #expect(abs((b - a) - HaloGlow.speed * 0.1) < 1e-6)
        }
    }

    @Test func aSliceCrossingTheRimsStartIsSplit() {
        let slices = HaloGlow.beam(at: 0.2, perimeter: perimeter)
        #expect(slices.count > HaloGlow.slices)
        for slice in slices { #expect(slice.from >= 0 && slice.to <= 1 && slice.from < slice.to) }
        #expect(abs(covered(slices) * perimeter - HaloGlow.tail) < 1e-6)
    }

    @Test func beamNeverOutrunsAShortRim() {
        #expect(abs(covered(HaloGlow.beam(at: 1.3, perimeter: 100)) - 1) < 1e-9)
        #expect(HaloGlow.beam(at: 1, perimeter: 0).isEmpty)
    }

    @Test func beamFadesFromBlueAtItsTailToNearWhiteAtItsHead() {
        let tail = HaloGlow.beamColor(along: 0), head = HaloGlow.beamColor(along: 1), middle = HaloGlow.beamColor(along: 0.5)
        #expect(tail == HaloGlow.beamTail && head == HaloGlow.beamHead)
        #expect(abs(middle.green - (tail.green + head.green) / 2) < 1e-12)
        #expect(HaloGlow.beamColor(along: 2) == head && HaloGlow.beamColor(along: -1) == tail)
    }

    @Test func rimColorsAreAllBlue() {
        #expect(HaloGlow.rimColors.count == 5)
        for color in HaloGlow.rimColors + [HaloGlow.beamTail, HaloGlow.beamHead] {
            #expect(color.blue >= color.red && color.blue >= color.green)
        }
    }

    @Test func turnWrapsOnceAroundAtTheTurnRate() {
        #expect(abs(HaloGlow.turn(at: 1) - HaloGlow.turnRate) < 1e-12)
        #expect(HaloGlow.turn(at: 100) >= 0 && HaloGlow.turn(at: 100) < 2 * .pi)
    }

    @Test func silenceStillLeavesFortyPercentOfTheLight() {
        #expect(abs(HaloGlow.light(glow: 0) - 0.4) < 1e-12)
        #expect(abs(HaloGlow.light(glow: 1) - 1) < 1e-12)
        #expect(HaloGlow.light(glow: 2) == HaloGlow.light(glow: 1))
        #expect(HaloGlow.light(glow: -1) == HaloGlow.light(glow: 0))
    }

    @Test func lightBrightensEverythingAndWidensTheHalo() {
        for (dim, bright) in [(0.4, 1.0), (0.2, 0.6)] {
            #expect(HaloGlow.rimOpacity(light: bright) > HaloGlow.rimOpacity(light: dim))
            #expect(HaloGlow.haloOpacity(light: bright) > HaloGlow.haloOpacity(light: dim))
            #expect(HaloGlow.haloRadius(light: bright) > HaloGlow.haloRadius(light: dim))
            #expect(HaloGlow.beamOpacity(light: bright) > HaloGlow.beamOpacity(light: dim))
        }
        #expect(HaloGlow.rimOpacity(light: 1) <= 1 && HaloGlow.beamOpacity(light: 1) <= 1)
        #expect(HaloGlow.haloRadius(light: 1) < HaloGlow.reach)
    }
}
