import AudioToolbox
import AVFAudio
import DictationCore

/// The start, stop, and cancel cues from the bundle, played as system sounds. macOS plays a system sound from its own
/// sound server, so a cue never makes this app play audio. An app that plays audio while it records looks like a call
/// to macOS, which then takes the user's AirPods from their iPhone on every dictation. A system sound plays at the
/// alert volume, through the output Sound settings picks for sound effects.
@MainActor final class Sounds {
    private let start = Sound("start")
    private let stop = Sound("stop")
    private let cancel = Sound("cancel")

    func play(_ cue: Cue) {
        let sound = switch cue {
        case .start: start
        case .stop: stop
        case .cancel: cancel
        }
        if let sound { AudioServicesPlaySystemSound(sound.id) }
    }

    /// The start cue's length, so muting other sound can wait for it.
    var startLength: Double { start?.length ?? 0 }
}

private struct Sound {
    let id: SystemSoundID
    let length: Double

    init?(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"), let file = try? AVAudioFile(forReading: url)
        else { return nil }
        var id = SystemSoundID()
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        // macOS skips a user interface sound when Play user interface sound effects is off. The app's own Sounds
        // setting decides instead.
        var interfaceSound: UInt32 = 0
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
                                 UInt32(MemoryLayout<UInt32>.size), &interfaceSound)
        self.id = id
        length = Double(file.length) / file.fileFormat.sampleRate
    }
}
