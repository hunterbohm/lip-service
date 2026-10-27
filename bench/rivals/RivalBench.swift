// Drives hold-to-talk dictation apps the way a person does: hold the app's hotkey, play a clip into a virtual
// microphone, let go, and time how long the text takes to land in this app's own text view.
// usage: open -W RivalBench.app --args PLAN.json   (see bench/rivals/README.md)
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

struct Target: Decodable {
    let name: String
    let key: String
}

struct Plan: Decodable {
    let clips: String
    let out: String
    let ids: [String]
    let targets: [Target]
    let rounds: [Int]
    let device: String
    let prerollS: Double
    let tailS: Double
    let settleS: Double
    let timeoutS: Double
    let gapS: Double
}

struct Trial: Encodable {
    let app: String
    let round: Int
    let clip: String
    let slot: Int
    let audio_s: Double
    let release_to_first_s: Double?
    let release_to_final_s: Double?
    let changes: Int
    let text: String
    let error: String?
}

/// A hold-to-talk key: a modifier sent as flagsChanged events, with the device bit that tells left from right.
struct HoldKey {
    let code: CGKeyCode
    let flags: CGEventFlags

    static let table: [String: HoldKey] = [
        "fn": HoldKey(code: 63, flags: .maskSecondaryFn),
        "rightoption": HoldKey(code: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)),
        "rightcommand": HoldKey(code: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)),
        "rightcontrol": HoldKey(code: 62, flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)),
    ]

    func post(down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)!
        event.type = .flagsChanged
        event.flags = down ? flags : []
        event.post(tap: .cghidEventTap)
    }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func outputDevice(named name: String) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    for id in ids {
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
           cfName?.takeRetainedValue() as String? == name {
            return id
        }
    }
    throw NSError(domain: "RivalBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio device named \(name)"])
}

/// Plays clips into one output device. The engine stays running between clips so no clip pays its start-up cost.
@MainActor
final class Speaker {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(device: AudioDeviceID) throws {
        var device = device
        let status = AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: "RivalBench", code: 2, userInfo: [NSLocalizedDescriptionKey: "set output device: \(status)"])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        try engine.start()
        player.play()
    }

    func play(_ file: AVAudioFile) async {
        await withCheckedContinuation { done in
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done.resume() }
        }
    }
}

@MainActor
final class Bench: NSObject, NSApplicationDelegate, NSTextStorageDelegate {
    let plan: Plan
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 420))
    var speaker: Speaker!
    var listening = false
    var changeTimes: [Double] = []
    var lostFocus = false

    init(plan: Plan) { self.plan = plan }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dictation apps paste with Command-V, which a text view handles only through an Edit menu's key equivalent.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "RivalBench", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .systemFont(ofSize: 20)
        textView.textStorage?.delegate = self
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        window.contentView = scroll
        window.title = "Untitled"
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if self.listening { self.lostFocus = true } }
        }
        Task { await self.run() }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let at = now()
        MainActor.assumeIsolated { if listening { changeTimes.append(at) } }
    }

    func log(_ line: String) { FileHandle.standardError.write((line + "\n").data(using: .utf8)!) }

    /// Launched outside LaunchServices, a plain activate() request is refused, so raise this app through Accessibility.
    func focus() async {
        NSApp.activate()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        try? await Task.sleep(for: .milliseconds(300))
    }

    func run() async {
        let out: FileHandle
        do {
            guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
                throw NSError(domain: "RivalBench", code: 3, userInfo: [NSLocalizedDescriptionKey: "needs Accessibility to press keys"])
            }
            speaker = try Speaker(device: try outputDevice(named: plan.device))
            if !FileManager.default.fileExists(atPath: plan.out) {
                FileManager.default.createFile(atPath: plan.out, contents: nil)
            }
            out = try FileHandle(forWritingTo: URL(fileURLWithPath: plan.out))
            try out.seekToEnd()
        } catch {
            log("RivalBench: \(error.localizedDescription)")
            exit(1)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for round in plan.rounds {
            for (index, clip) in plan.ids.enumerated() {
                for slot in plan.targets.indices {
                    let target = plan.targets[(slot + index + round) % plan.targets.count]
                    let trial = await dictate(clip: clip, into: target, round: round, slot: slot)
                    out.write(try! encoder.encode(trial) + Data("\n".utf8))
                    log("\(trial.app) r\(round) \(clip): \(trial.error ?? String(format: "%.3f s", trial.release_to_final_s ?? .nan)) \(trial.text.prefix(60))")
                    try? await Task.sleep(for: .seconds(plan.gapS))
                }
            }
        }
        try? out.close()
        exit(0)
    }

    func dictate(clip: String, into target: Target, round: Int, slot: Int) async -> Trial {
        func failed(_ error: String, audio: Double = 0) -> Trial {
            Trial(app: target.name, round: round, clip: clip, slot: slot, audio_s: audio, release_to_first_s: nil,
                  release_to_final_s: nil, changes: changeTimes.count, text: textView.string, error: error)
        }
        guard let key = HoldKey.table[target.key] else { return failed("unknown key \(target.key)") }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: plan.clips).appending(path: clip + ".wav")) else {
            return failed("cannot read \(clip).wav")
        }
        let audio = Double(file.length) / file.processingFormat.sampleRate
        listening = false
        textView.string = ""
        changeTimes = []
        await focus()
        guard NSApp.isActive, window.isKeyWindow else { return failed("RivalBench lost focus before the trial", audio: audio) }
        lostFocus = false
        listening = true
        key.post(down: true)
        try? await Task.sleep(for: .seconds(plan.prerollS))
        await speaker.play(file)
        try? await Task.sleep(for: .seconds(plan.tailS))
        key.post(down: false)
        let released = now()
        let early = changeTimes.count
        while true {
            try? await Task.sleep(for: .milliseconds(20))
            let t = now()
            if let last = changeTimes.last, t - last >= plan.settleS { break }
            if changeTimes.isEmpty, t - released >= plan.timeoutS { break }
        }
        listening = false
        guard let first = changeTimes.first, let last = changeTimes.last else {
            return failed(lostFocus ? "lost focus during the trial" : "no text", audio: audio)
        }
        return Trial(app: target.name, round: round, clip: clip, slot: slot, audio_s: audio,
                     release_to_first_s: first - released, release_to_final_s: last - released, changes: changeTimes.count,
                     text: textView.string,
                     error: lostFocus ? "lost focus during the trial" : early > 0 ? "text arrived before release" : nil)
    }
}

let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[args.count - 1]),
      let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
    FileHandle.standardError.write(Data("usage: RivalBench PLAN.json\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let bench = Bench(plan: plan)
app.delegate = bench
app.run()
