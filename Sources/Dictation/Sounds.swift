import AudioToolbox
import AVFAudio
import DictationCore

/// The cues from the bundle, played as system sounds: start, stop and cancel for a dictation, and a talk's own two.
/// macOS plays a system sound from its own sound server, so a cue never makes this app play audio. An app that plays
/// audio while it records looks like a call to macOS, which then takes the user's AirPods from their iPhone on every
/// dictation. A system sound plays at the alert volume, through the output Sound settings picks for sound effects.
@MainActor final class Sounds {
    private let sounds = Dictionary(uniqueKeysWithValues: (Cue.allCases.map(\.file) + TalkCue.allCases.map(\.file)).compactMap { file in
        Sound(file).map { (file, $0) }
    })

    func play(_ cue: Cue) { play(cue.file) }
    func play(talk cue: TalkCue) { play(cue.file) }

    private func play(_ file: String) {
        if let sound = sounds[file] { AudioServicesPlaySystemSound(sound.id) }
    }

    /// The start cue's length, so muting other sound can wait for it.
    var startLength: Double { sounds[Cue.start.file]?.length ?? 0 }
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
