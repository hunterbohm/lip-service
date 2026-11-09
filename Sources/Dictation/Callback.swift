import AppKit
import CoreAudio
import CoreMediaIO
import DictationCore
import Foundation

/// How `Dictation call` and the running app talk: the request goes in a private file in the support folder, named by its
/// id, and a distributed notification carrying only the id tells the app to read it. The app answers with status
/// notifications for that id. The result never travels in a notification, which any process of this user can see.
enum CallChannel {
    static let request = Notification.Name("com.hunterbohm.dictation.call")
    static let status = Notification.Name("com.hunterbohm.dictation.call.status")
    static let folder = SupportFolder.url.appending(path: "calls", directoryHint: .isDirectory)

    static func file(for id: String) -> URL? {
        // Only a UUID names a file, so an id can't point outside the folder.
        guard UUID(uuidString: id) != nil else { return nil }
        return folder.appending(path: "\(id).json")
    }

    /// Reads and deletes the request with this id. Nil when it is missing, unreadable or older than a minute.
    static func take(_ id: String) -> CallbackRequest? {
        guard let url = file(for: id) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let written = attributes[.modificationDate] as? Date, Date().timeIntervalSince(written) < 60,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CallbackRequest.self, from: data)
    }

    static func post(_ update: CallbackUpdate) {
        guard let data = try? JSONEncoder().encode(update) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            status, object: nil, userInfo: ["update": String(decoding: data, as: UTF8.self)], deliverImmediately: true)
    }
}

/// What this Mac says about whether you can take a call now. Each reads the system as it is, with no permission prompt.
enum CallSignals {
    /// Programs that keep the microphone open on their own, not for a call: Siri's listener.
    private static let alwaysListening: Set<String> = ["corespeechd"]

    static func busy(talking: Bool, dictating: Bool) -> CallbackBusy? {
        CallbackBusy.check(talking: talking, dictating: dictating, locked: screenLocked(), focus: focusOn(), camera: cameraInUse(),
                           microphone: microphoneUsers())
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    static func focusOn() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return FocusFile.isOn(data)
    }

    /// The other programs recording from any microphone now, by name. Lip Service keeps its own microphone ready, so
    /// every Lip Service process is left out, the running app as well as `Dictation call --check`.
    static func microphoneUsers() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier, bundle = Bundle.main.bundleIdentifier
        var names: [String] = []
        for process in processes {
            guard let pid: pid_t = value(process, kAudioProcessPropertyPID), pid != me,
                  let running: UInt32 = value(process, kAudioProcessPropertyIsRunningInput), running != 0 else { continue }
            let path = executablePath(pid)
            let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            guard !alwaysListening.contains(executable), bundle == nil || app?.bundleIdentifier != bundle else { continue }
            let name = app?.localizedName ?? (executable.isEmpty ? "pid \(pid)" : executable)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Whether any camera is running for any program.
    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var on: UInt32 = 0, got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &on) == 0, on != 0 {
                return true
            }
        }
        return false
    }

    private static func value<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// `Dictation call`: hands a call back to the running app and prints each status as one JSON line until the last, then
/// exits with that status's code (see `CallbackStatus.exitCode`).
@MainActor enum CallCommand {
    struct Options {
        var from = "Hermes"
        var about = ""
        var ring = CallbackRequest.defaultRing
        var agent: String?
        /// Reads the result from this file instead of stdin.
        var resultFile: URL?
        /// Prints the busy check and exits, ringing nothing.
        var check = false
    }

    /// How long the app has to take the request, and how long the talk has to say the result once answered.
    static let ackLimit = 10.0
    static let sayLimit = 240.0

    static func run(_ options: Options) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        if options.check {
            let busy = CallSignals.busy(talking: false, dictating: false)
            var row: [String: JSONValue] = ["busy": .bool(busy != nil)]
            if let busy { row["detail"] = .string(busy.detail) }
            print(String(decoding: JSONValue.object(row).data(), as: UTF8.self))
            return busy == nil ? 0 : CallbackStatus.busy.exitCode
        }
        let result: String
        if let file = options.resultFile {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return finish(.failed, "cannot read \(file.path)") }
            result = text
        } else {
            result = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let request = CallbackRequest(from: options.from, about: options.about, result: result, ringSeconds: options.ring,
                                      agent: options.agent)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard running else { return finish(.failed, "Lip Service isn't running") }
        SupportFolder.makePrivate()
        guard let url = CallChannel.file(for: request.id) else { return finish(.failed, "bad id") }
        do {
            try FileManager.default.createDirectory(at: CallChannel.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: url, options: .atomic)
        } catch {
            return finish(.failed, "cannot write the request: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let heard = Heard()
        let observer = DistributedNotificationCenter.default().addObserver(forName: CallChannel.status, object: nil, queue: nil) { note in
            guard let text = note.userInfo?["update"] as? String,
                  let update = try? JSONDecoder().decode(CallbackUpdate.self, from: Data(text.utf8)), update.id == request.id
            else { return }
            MainActor.assumeIsolated {
                print(line(update))
                heard.last = update
            }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        DistributedNotificationCenter.default().postNotificationName(CallChannel.request, object: nil, userInfo: ["id": request.id],
                                                                     deliverImmediately: true)
        let started = Date()
        var answeredAt: Date?
        while true {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            let now = Date()
            if let last = heard.last {
                if last.status.isFinal { return last.status.exitCode }
                if last.status == .answered, answeredAt == nil { answeredAt = now }
            } else if now.timeIntervalSince(started) > ackLimit {
                return finish(.failed, "Lip Service didn't take the call")
            }
            let limit = answeredAt.map { $0.addingTimeInterval(sayLimit) } ?? started.addingTimeInterval(ackLimit + request.ringSeconds + 15)
            if now > limit { return finish(.failed, answeredAt == nil ? "the call never finished ringing" : "the result wasn't said in time") }
        }
    }

    @MainActor private final class Heard {
        var last: CallbackUpdate?
    }

    private static func finish(_ status: CallbackStatus, _ detail: String) -> Int32 {
        print(line(CallbackUpdate(id: "", status: status, detail: detail)))
        return status.exitCode
    }

    private static func line(_ update: CallbackUpdate) -> String {
        var row: [String: JSONValue] = ["status": .string(update.status.rawValue)]
        if let detail = update.detail { row["detail"] = .string(detail) }
        return String(decoding: JSONValue.object(row).data(), as: UTF8.self)
    }
}
