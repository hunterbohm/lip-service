import DictationCore
import Testing

@Suite("Other apps' bars") struct ScreenBarsTests {
    /// The ultrawide under a laptop, as AppKit has it, with the menu bar hidden so its visible frame is the whole screen.
    let screen = BarRect(x: -2560, y: -1047, width: 2560, height: 1080)

    @Test func aTilersTopBarIsLeftOut() {
        let omniBar = BarRect(x: -2560, y: 1, width: 2560, height: 32)
        #expect(screen.clear(of: [omniBar]) == BarRect(x: -2560, y: -1047, width: 2560, height: 1048))
    }

    @Test func barsOnEveryEdgeAreLeftOut() {
        let bars = [BarRect(x: -2560, y: -1047, width: 2000, height: 40),
                    BarRect(x: -2560, y: -1047, width: 30, height: 1080),
                    BarRect(x: -50, y: -900, width: 50, height: 800)]
        #expect(screen.clear(of: bars) == BarRect(x: -2530, y: -1007, width: 2480, height: 1040))
    }

    @Test func floatingWindowsOverlaysAndOtherScreensAreIgnored() {
        let others = [BarRect(x: -1500, y: 1, width: 400, height: 32),   // short, a menu bar extra's popover
                      BarRect(x: -2560, y: -1047, width: 2560, height: 1080), // full-screen overlay
                      BarRect(x: -2560, y: -500, width: 2560, height: 30),  // across the middle, not at an edge
                      BarRect(x: 0, y: 950, width: 1512, height: 32)]       // the laptop's own bar, another screen
        #expect(screen.clear(of: others) == screen)
    }
}
