import DictationCore
import Testing

@Suite("Where the island sits") struct IslandPlacementTests {
    /// The MacBook Pro's screen as AppKit has it, with a notch 185 points wide and 32 tall.
    let frame = BarRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = TalkIsland.Screen(hasNotch: true, notchWidth: 185, barHeight: 32)

    @Test func withNoBarANotchGrowsTheIslandOutOfItself() {
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: frame) == .init(screen: notch, drop: 0))
    }

    @Test func withNoBarAPlainScreenFloatsItBelowTheTop() {
        #expect(TalkIsland.placement(frame: frame, screen: .plain, clear: frame) == .init(screen: .plain, drop: TalkIsland.floatingGap))
    }

    @Test func aBarOverTheNotchPutsTheIslandJustBelowIt() {
        // OmniWM's bar covers the same 32 points as the notch.
        let clear = BarRect(x: 0, y: 0, width: 1512, height: 950)
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: .plain, drop: 32 + TalkIsland.floatingGap))
    }

    @Test func aBarThickerThanTheNotchPutsTheIslandBelowTheBar() {
        let clear = BarRect(x: 0, y: 0, width: 1512, height: 982 - 44)
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: .plain, drop: 44 + TalkIsland.floatingGap))
    }

    @Test func aBarThinnerThanTheNotchStillClearsTheNotch() {
        let clear = BarRect(x: 0, y: 0, width: 1512, height: 982 - 24)
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: .plain, drop: 32 + TalkIsland.floatingGap))
    }

    @Test func aBarOnAPlainScreenPutsTheIslandBelowIt() {
        let clear = BarRect(x: 0, y: 0, width: 1512, height: 982 - 30)
        #expect(TalkIsland.placement(frame: frame, screen: .plain, clear: clear) == .init(screen: .plain, drop: 30 + TalkIsland.floatingGap))
    }

    @Test func aHairlineIsNotABar() {
        let clear = BarRect(x: 0, y: 0, width: 1512, height: 982 - TalkIsland.barTolerance)
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: notch, drop: 0))
    }

    @Test func barsOnOtherEdgesDoNotMoveIt() {
        // The clear area of a screen with a bar on its left and bottom only keeps its top.
        let clear = BarRect(x: 30, y: 40, width: 1482, height: 942)
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: notch, drop: 0))
    }

    @Test func aBarJustBelowTheMenuBarCountsWhenItIsAllowedToReachUnderIt() {
        // The macOS menu bar is 32 points and a tiler's bar sits right under it, so it does not touch the screen's top.
        let tiler = BarRect(x: 0, y: 918, width: 1512, height: 32)
        #expect(frame.clear(of: [tiler]) == frame)
        let clear = frame.clear(of: [tiler], touch: 32 + 2)
        #expect(clear == BarRect(x: 0, y: 0, width: 1512, height: 918))
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear) == .init(screen: .plain, drop: 64 + TalkIsland.floatingGap))
    }

    @Test func theTilersBarOnTheMacBookIsFoundOverTheNotch() {
        let tiler = BarRect(x: 0, y: 950, width: 1512, height: 32)
        let clear = frame.clear(of: [tiler])
        #expect(clear == BarRect(x: 0, y: 0, width: 1512, height: 950))
        #expect(TalkIsland.placement(frame: frame, screen: notch, clear: clear).drop == 38)
    }
}
