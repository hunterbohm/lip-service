import AppKit
import DictationCore

/// `--render-bar DIR`: lays out every bar state with the app's own Bar on a stand-in screen kept off the displays,
/// and writes each as a PNG, the whole stage and a close-up, so the look can be checked without a key press. The
/// voice is frozen mid-speech and the animations settled, so a still shows the lips at a fixed moment. One scene is captured while its words are still printing in.
@MainActor enum RenderBar {
    private struct Scene {
        var name: String
        var state: BarState
        var edge = BarEdge.bottom
        var dragNearest: BarEdge?
        var quiet = false
        /// How long to let the animations run before the snapshot. Short, and a word is caught mid-print.
        var settle = 1.2
    }

    /// Mid-speech: loud now, with swells before it that the lips carry outward, so the corners open a moment after the middle.
    nonisolated private static func speaking(_ age: Double) -> Float {
        Float(min(max(0.45 + 0.4 * cos(age * 10) * exp(-age * 0.7), 0), 1))
    }
    private static let frozenAt = 0.9
    private static let short = "Teo Yep, I'll share the latest version in a few minutes"
    private static let long = "Okay so the plan for Friday is to ship the new onboarding flow to everyone, then check the "
        + "Beehiiv numbers on Monday and ask ProfitPilot to draft the follow-up email for the people who signed up late"
    private static let stage = NSRect(x: -9000, y: -9000, width: 1000, height: 620)
    private static let scale: CGFloat = 2

    private static let scenes: [Scene] = [
        Scene(name: "01-listening-start", state: BarState(body: .listening(words: "", handsFree: false))),
        Scene(name: "02-listening-short", state: BarState(body: .listening(words: short, handsFree: false))),
        Scene(name: "03-listening-long", state: BarState(body: .listening(words: long, handsFree: false))),
        Scene(name: "04-hands-free", state: BarState(body: .listening(words: short, handsFree: true))),
        Scene(name: "05-hands-free-start", state: BarState(body: .listening(words: "", handsFree: true))),
        Scene(name: "06-transcribing", state: BarState(body: .transcribing(words: short, waitingOn: nil))),
        Scene(name: "07-transcribing-waiting-on-model", state: BarState(body: .transcribing(words: short, waitingOn: .compiling))),
        Scene(name: "08-preparing-download", state: BarState(body: .preparing(.downloading(fraction: 0.42)))),
        Scene(name: "09-preparing-compile", state: BarState(body: .preparing(.compiling))),
        Scene(name: "10-toast-copied", state: BarState(body: .hidden, toast: .copied(.focusMoved))),
        Scene(name: "11-toast-failed", state: BarState(body: .hidden, toast: .failed("Transcription failed: The model stopped responding."))),
        Scene(name: "12-toast-microphone-missing", state: BarState(body: .listening(words: "", handsFree: false),
                                                                    toast: .microphoneMissing(chosen: "Shure MV7+", using: "MacBook Pro Microphone"))),
        Scene(name: "13-toast-nothing-to-paste", state: BarState(body: .idle, toast: .nothingToPaste)),
        Scene(name: "14-toast-model-failed-retry", state: BarState(body: .hidden, toast: .modelFailed("The network connection was lost."))),
        Scene(name: "15-toast-fn-key-setting", state: BarState(body: .listening(words: "", handsFree: false), toast: .fnKeySetting)),
        Scene(name: "16-idle-bottom", state: BarState(body: .idle)),
        Scene(name: "17-idle-top", state: BarState(body: .idle), edge: .top),
        Scene(name: "18-idle-left", state: BarState(body: .idle), edge: .left),
        Scene(name: "19-idle-right", state: BarState(body: .idle), edge: .right),
        Scene(name: "20-listening-top", state: BarState(body: .listening(words: short, handsFree: false)), edge: .top),
        Scene(name: "21-listening-left", state: BarState(body: .listening(words: short, handsFree: false)), edge: .left),
        Scene(name: "22-listening-right", state: BarState(body: .listening(words: short, handsFree: false)), edge: .right),
        Scene(name: "23-listening-right-long", state: BarState(body: .listening(words: long, handsFree: true)), edge: .right),
        Scene(name: "24-toast-right", state: BarState(body: .listening(words: "", handsFree: false),
                                                       toast: .microphoneMissing(chosen: "Shure MV7+", using: "MacBook Pro Microphone")),
              edge: .right),
        Scene(name: "25-toast-top", state: BarState(body: .idle, toast: .copied(.focusMoved)), edge: .top),
        Scene(name: "26-dragging", state: BarState(body: .idle), edge: .bottom, dragNearest: .right),
        Scene(name: "27-listening-quiet", state: BarState(body: .listening(words: "", handsFree: false)), quiet: true),
        Scene(name: "28-listening-word-printing", state: BarState(body: .listening(words: short, handsFree: false)), settle: 0.12),
    ]

    static func run(into directory: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        let bar = Bar(level: { 0 }, area: { _ in stage })
        for scene in scenes {
            bar.render(BarState(body: .hidden), edge: scene.edge)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            bar.meter.freeze(at: frozenAt, profile: scene.quiet ? { _ in 0 } : speaking)
            bar.render(scene.state, edge: scene.edge)
            bar.showOutlines(nearest: scene.dragNearest)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: scene.settle))
            let panels = bar.visiblePanels.map { (frame: $0.frame.offsetBy(dx: -stage.minX, dy: -stage.minY), image: snapshot($0)) }
            let stagePath = directory.appending(path: "\(scene.name).png")
            let closeUpPath = directory.appending(path: "\(scene.name)-closeup.png")
            guard write(compose(panels, in: NSRect(origin: .zero, size: stage.size)), to: stagePath),
                  write(compose(panels, in: closeUp(around: panels.map(\.frame))), to: closeUpPath)
            else { return 1 }
            print(stagePath.path)
        }
        return 0
    }

    private static func snapshot(_ panel: NSPanel) -> NSImage {
        guard let view = panel.contentView else { return NSImage() }
        view.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                   pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func closeUp(around frames: [NSRect]) -> NSRect {
        guard let first = frames.first else { return NSRect(origin: .zero, size: stage.size) }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return union.insetBy(dx: -36, dy: -24).intersection(NSRect(origin: .zero, size: stage.size))
    }

    /// A light window with a darker sidebar stands in for the screen, so the bar's contrast reads as it would.
    private static func compose(_ panels: [(frame: NSRect, image: NSImage)], in region: NSRect) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale), pixelsHigh: Int(region.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = region.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.translateX(by: -region.minX, yBy: -region.minY)
        transform.concat()
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: stage.size).fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 180, height: stage.height).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        for row in 0..<9 { NSRect(x: 220, y: stage.height - 70 - CGFloat(row) * 52, width: 360 + CGFloat(row % 3) * 90, height: 10).fill() }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        for panel in panels {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            panel.image.draw(in: panel.frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("cannot write \(url.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
