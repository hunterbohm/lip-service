import AppKit
import DictationCore

/// The start, stop, and cancel cues from the bundle, read into memory at launch so a cue never waits on the disk.
/// NSSound plays on its own thread, so `play` returns at once.
@MainActor final class Sounds {
    private let start = Sounds.load("start")
    private let stop = Sounds.load("stop")
    private let cancel = Sounds.load("cancel")

    func play(_ cue: Cue) {
        let sound = switch cue {
        case .start: start
        case .stop: stop
        case .cancel: cancel
        }
        sound?.stop()
        sound?.play()
    }

    private static func load(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
    }
}
