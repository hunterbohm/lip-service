import Foundation

/// Reads Willow Voice's local files: one JSON file per transcript, and `Preferences/preferences.json` plus two
/// values from its defaults domain for settings.
public enum Willow {
    public static let idPrefix = "willow:"

    public enum Transcript: Equatable, Sendable {
        case dictation(HistoryEntry)
        case cancelled
        case empty
        case unreadable
    }

    /// `date` is seconds since 2001-01-01.
    public static func transcript(_ data: Data) -> Transcript {
        guard let raw = try? JSONDecoder().decode(RawTranscript.self, from: data), let date = raw.date else {
            return .unreadable
        }
        if raw.status == "cancelled" { return .cancelled }
        let text = (raw.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        let app = raw.appContext?.application.flatMap { app in
            app.name.map { HistoryApp(name: $0, bundleID: app.bundle_id) }
        }
        return .dictation(HistoryEntry(id: idPrefix + raw.id.value, date: Date(timeIntervalSinceReferenceDate: date),
                                       text: text, audioSeconds: raw.recordingDuration, app: app))
    }

    private struct RawTranscript: Decodable {
        var id: FlexibleID
        var text: String?
        var date: Double?
        var status: String?
        var recordingDuration: Double?
        var appContext: AppContext?

        struct AppContext: Decodable {
            var application: Application?
        }

        struct Application: Decodable {
            var name: String?
            var bundle_id: String?
        }
    }

    private struct FlexibleID: Decodable {
        var value: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else {
                value = String(try container.decode(Int.self))
            }
        }
    }

    public struct ImportedSettings: Equatable, Sendable {
        public var hotkeys: [HotkeyChoice]?
        public var sounds: Bool?
        public var hideBarWhenIdle: Bool?
        public var smartSpacing: Bool?
        public var microphone: MicrophoneChoice?
        public var barEdge: BarEdge?
        public var showMenuBarIcon: Bool?
        public var skippedHotkeys: [String] = []

        private static let hotkeyNames: [String: HotkeyChoice] = [
            "fn": .fn, "globe": .fn,
            "rightcontrol": .rightControl, "rightctrl": .rightControl,
            "rightoption": .rightOption, "rightalt": .rightOption,
            "rightcommand": .rightCommand, "rightcmd": .rightCommand,
        ]

        public init(preferences: Data?, barEdgePosition: String?, showMenuBarIcon: Bool?) {
            barEdge = barEdgePosition.flatMap { BarEdge(rawValue: $0.lowercased()) }
            self.showMenuBarIcon = showMenuBarIcon
            guard let preferences,
                  let object = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any]
            else { return }
            sounds = object["audioRecordingSounds"] as? Bool
            hideBarWhenIdle = object["hideBarWhenIdle"] as? Bool
            smartSpacing = object["smartTextInsertion"] as? Bool

            if let list = object["hotkeyDataArray"] as? [Any] {
                var chosen: [HotkeyChoice] = []
                for element in list {
                    let names = Self.keyNames(in: element)
                    if names.count == 1, let choice = Self.hotkeyNames[Self.normalized(names[0])] {
                        chosen.append(choice)
                    } else {
                        skippedHotkeys.append(names.isEmpty ? "an entry with no key name" : names.joined(separator: "+"))
                    }
                }
                let ordered = HotkeyChoice.allCases.filter(chosen.contains)
                hotkeys = ordered.isEmpty ? nil : ordered
            }

            if object.keys.contains("selectedMicrophoneUID") {
                let uid = (object["selectedMicrophoneUID"] as? String).map { $0.hasPrefix("uid:") ? String($0.dropFirst(4)) : $0 }
                if let uid, !uid.isEmpty {
                    let model = (object["selectedMicrophoneModelUID"] as? String)?.split(separator: ":").first.map(String.init)
                    microphone = .device(uid: uid, name: model.flatMap { $0.isEmpty ? nil : $0 } ?? uid)
                } else {
                    microphone = .systemDefault
                }
            }
        }

        public var isEmpty: Bool {
            hotkeys == nil && sounds == nil && hideBarWhenIdle == nil && smartSpacing == nil && microphone == nil
                && barEdge == nil && showMenuBarIcon == nil
        }

        public func apply(to settings: inout Settings) {
            if let hotkeys { settings.hotkeys = hotkeys }
            if let sounds { settings.sounds = sounds }
            if let hideBarWhenIdle { settings.hideBarWhenIdle = hideBarWhenIdle }
            if let smartSpacing { settings.smartSpacing = smartSpacing }
            if let microphone { settings.microphone = microphone }
            if let barEdge { settings.barEdge = barEdge }
            if let showMenuBarIcon { settings.showMenuBarIcon = showMenuBarIcon }
        }

        public var summary: [String] {
            func onOff(_ value: Bool) -> String { value ? "on" : "off" }
            var lines: [String] = []
            if let hotkeys { lines.append("Dictation hotkeys: " + hotkeys.map(\.title).joined(separator: ", ")) }
            if let sounds { lines.append("Interaction sounds: \(onOff(sounds))") }
            if let hideBarWhenIdle { lines.append("Hide bar when idle: \(onOff(hideBarWhenIdle))") }
            if let smartSpacing { lines.append("Smart spacing: \(onOff(smartSpacing))") }
            switch microphone {
            case .systemDefault: lines.append("Microphone: System Default")
            case .device(let uid, let name): lines.append("Microphone: \(name) (\(uid))")
            case nil: break
            }
            if let barEdge { lines.append("Bar position: \(barEdge.rawValue)") }
            if let showMenuBarIcon { lines.append("Menu bar icon: \(showMenuBarIcon ? "shown" : "hidden")") }
            return lines
        }

        private static func normalized(_ name: String) -> String {
            name.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        }

        /// An entry stored as Data arrives as base64, holding JSON or a property list.
        private static func keyNames(in value: Any) -> [String] {
            switch value {
            case let dictionary as [String: Any]:
                let own = (dictionary["keyName"] as? String).map { [$0] } ?? []
                return own + dictionary.filter { $0.key != "keyName" }.sorted { $0.key < $1.key }.flatMap { keyNames(in: $0.value) }
            case let array as [Any]:
                return array.flatMap(keyNames(in:))
            case let string as String:
                guard let data = Data(base64Encoded: string) else { return [] }
                if let object = try? JSONSerialization.jsonObject(with: data) { return keyNames(in: object) }
                if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) { return keyNames(in: object) }
                return []
            default:
                return []
            }
        }
    }
}
