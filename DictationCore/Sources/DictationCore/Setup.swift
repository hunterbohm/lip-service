import Foundation

/// The part of Settings a user's own agent may set up with `Dictation setup`: the agents and their drafts, the
/// profile rules, and the Ghostwrite and Hand off keys. Saved before an apply, so Undo puts exactly these back.
public struct SetupFields: Equatable, Codable, Sendable {
    public var agents: AgentSettings
    /// The rules of each group, keyed by the group's name.
    public var rules: [String: ProfileRules]
    public var ghostwriteKey: Shortcut?
    public var handOffKey: Shortcut?
}

extension Settings {
    public var setupFields: SetupFields {
        get {
            SetupFields(agents: agents,
                        rules: Dictionary(uniqueKeysWithValues: ProfileGroup.allCases.compactMap { group in
                            profiles.rules[group].map { (group.rawValue, $0) }
                        }),
                        ghostwriteKey: ghostwriteKey, handOffKey: handOffKey)
        }
        set {
            agents = newValue.agents
            for group in ProfileGroup.allCases {
                if let rules = newValue.rules[group.rawValue] { profiles.set(rules, for: group) }
            }
            ghostwriteKey = newValue.ghostwriteKey
            handOffKey = newValue.handOffKey
        }
    }
}

/// An applied setup, kept until the user dismisses it or undoes it: who did it, what changed in plain words, and what
/// to put back.
public struct SetupRecord: Equatable, Codable, Sendable {
    public static let anonymous = "Your agent"

    public var by: String
    public var changes: [String]
    public var previous: SetupFields
    public var date: Date

    public init(by: String?, changes: [String], previous: SetupFields, date: Date = .now) {
        let name = by?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        (self.by, self.changes, self.previous, self.date) = (name.isEmpty ? Self.anonymous : name, changes, previous, date)
    }

    public var title: String { "\(by) set up Lip Service" }

    public func undo(_ settings: Settings) -> Settings {
        var restored = settings
        restored.setupFields = previous
        // A key the setup freed and the user has since given to Paste Last or dictation stays theirs: the agent keys keep
        // their current values rather than share it.
        let taken = { (key: Shortcut?) in key.map { $0 == settings.pasteLast || settings.hotkeys.contains($0) } ?? false }
        if taken(restored.ghostwriteKey) || taken(restored.handOffKey)
            || (restored.ghostwriteKey != nil && restored.ghostwriteKey == restored.handOffKey) {
            restored.ghostwriteKey = settings.ghostwriteKey
            restored.handOffKey = settings.handOffKey
        }
        return restored
    }
}

public struct SetupPlan: Equatable, Sendable {
    public var settings: Settings
    /// Plain words, one line per change. Empty when the input changes nothing.
    public var changes: [String]
}

/// Everything wrong with an input, so an agent can fix it in one go. Nothing was changed.
public struct SetupInvalid: Error, Equatable, Sendable {
    public var problems: [String]
}

/// `Dictation setup show|apply`. Reading and writing are pure: the app target only moves the bytes.
public enum SetupSpec {
    static let topLevel = ["agents", "defaultAgent", "reviewFirst", "voiceExamples", "includeWindowText", "voiceNotes", "profiles", "keys"]
    static let ignored = ["found", "help"]
    static let agentFields = ["id", "preset", "name", "command", "host", "spokenNames", "destination"]
    /// Destinations that hold a secret in the Keychain. They can be kept as they are, never made or changed from here.
    static let secretKinds: [DestinationKind] = [.slack, .discord, .webhook]

    public static let help = """
        Every field is optional; a field left out stays as it is. "agents" lists agents to add or change; agents not listed \
        stay. An agent is {"id", "preset": hermes|claude|codex|opencode|gemini|custom, "name", "command": [words], \
        "host": ssh name or null for this Mac, "spokenNames": [names], "destination": {"kind": iMessage|t3Code|telegram|\
        agentReply|command, ...}}. iMessage takes "handle", telegram "botUsername", command "executable" and "arguments", \
        t3Code optional "provider" and "model". Slack, Discord and web-address hand-offs hold secrets, so set those up in the \
        app. "defaultAgent" is an agent id. reviewFirst, voiceExamples and includeWindowText are true or false. "voiceNotes" \
        is a few lines on how the user writes. "profiles" maps messages|workChat|email|aiAndCode|everythingElse to \
        {"style": formal|casual|veryCasual, "pressReturn": true|false}. "keys" sets "ghostwrite" and "handOff" to a key \
        such as "⌃ fn" or "⌥ fn", or null to turn it off; "dictation" is shown but can't be changed here. "found" lists \
        agents installed on this Mac.
        """

    // MARK: Show

    public static func show(_ settings: Settings, found: [String]) -> JSONValue {
        let agents = settings.agents
        var profiles: [String: JSONValue] = [:]
        for group in ProfileGroup.allCases {
            let rules = settings.profiles.rules[group] ?? ProfileRules(style: .formal)
            profiles[group.rawValue] = ["style": .string(rules.style.rawValue), "pressReturn": .bool(rules.pressReturn)]
        }
        return [
            "agents": .array(agents.agents.map(agentJSON)),
            "defaultAgent": agents.current.map { .string($0.id) } ?? .null,
            "reviewFirst": .bool(agents.reviewFirst),
            "voiceExamples": .bool(agents.voiceExamples),
            "includeWindowText": .bool(agents.includeWindowText),
            "voiceNotes": .string(agents.voiceNotes),
            "profiles": .object(profiles),
            "keys": ["dictation": .array(settings.hotkeys.map { .string($0.title) }),
                     "ghostwrite": settings.ghostwriteKey.map { .string($0.title) } ?? .null,
                     "handOff": settings.handOffKey.map { .string($0.title) } ?? .null],
            "found": .array(found.map { .string($0) }),
            "help": .string(help),
        ]
    }

    static func agentJSON(_ agent: AgentConnection) -> JSONValue {
        [
            "id": .string(agent.id), "preset": .string(agent.presetID), "name": .string(agent.name),
            "command": .array(agent.command.map { .string($0) }),
            "host": agent.hostName.map { .string($0) } ?? .null,
            "spokenNames": .array(agent.spokenNames.map { .string($0) }),
            "destination": destinationJSON(agent.destination),
        ]
    }

    /// Only what is not a secret. A Slack, Discord or web-address hand-off shows its kind and nothing else.
    static func destinationJSON(_ destination: Destination) -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(destination.kind.rawValue)]
        switch destination {
        case .iMessage(let handle): object["handle"] = .string(handle)
        case .t3Code(let t3):
            if let provider = t3.provider { object["provider"] = .string(provider) }
            if let model = t3.model { object["model"] = .string(model) }
        case .telegram(let bot): object["botUsername"] = .string(bot)
        case .command(let executable, let arguments):
            object["executable"] = .string(executable)
            object["arguments"] = .array(arguments.map { .string($0) })
        case .slack, .discord, .webhook, .agentReply: break
        }
        return .object(object)
    }

    // MARK: Apply

    public static func plan(_ input: Data, from settings: Settings) -> Result<SetupPlan, SetupInvalid> {
        guard let root = JSONValue.parse(input), case .object(let fields) = root else {
            return .failure(SetupInvalid(problems: ["The input is not a JSON object. Send the same shape `setup show` prints."]))
        }
        var reader = Reader()
        for key in fields.keys.sorted() where !topLevel.contains(key) && !ignored.contains(key) {
            reader.problems.append("Unknown field \"\(key)\". The fields are \(topLevel.joined(separator: ", ")).")
        }
        var next = settings
        if let value = fields["agents"] { applyAgents(value, to: &next, reader: &reader) }
        if let value = fields["defaultAgent"], value != .null {
            if let id = reader.string(value, "defaultAgent") {
                if next.agents.agent(id: id) != nil {
                    if id != next.agents.current?.id { next.agents.defaultAgent = id }
                } else {
                    let known = next.agents.agents.map(\.id)
                    reader.problems.append("defaultAgent \"\(id)\" is not an agent. " + (known.isEmpty ? "No agents are set up." : "The agents are \(known.joined(separator: ", ")).") )
                }
            }
        }
        if let value = fields["reviewFirst"], let flag = reader.bool(value, "reviewFirst") { next.agents.reviewFirst = flag }
        if let value = fields["voiceExamples"], let flag = reader.bool(value, "voiceExamples") { next.agents.voiceExamples = flag }
        if let value = fields["includeWindowText"], let flag = reader.bool(value, "includeWindowText") { next.agents.includeWindowText = flag }
        if let value = fields["voiceNotes"], let text = reader.string(value, "voiceNotes") { next.agents.voiceNotes = text }
        if let value = fields["profiles"] { applyProfiles(value, to: &next, reader: &reader) }
        if let value = fields["keys"] { applyKeys(value, to: &next, reader: &reader) }
        guard reader.problems.isEmpty else { return .failure(SetupInvalid(problems: reader.problems)) }
        if settings.agents.agents.isEmpty, next.agents.defaultAgent == nil { next.agents.defaultAgent = next.agents.agents.first?.id }
        return .success(SetupPlan(settings: next, changes: changes(from: settings.setupFields, to: next.setupFields)))
    }

    private struct Reader {
        var problems: [String] = []

        mutating func string(_ value: JSONValue, _ path: String) -> String? {
            if let text = value.string { return text }
            problems.append("\(path) must be text.")
            return nil
        }

        mutating func bool(_ value: JSONValue, _ path: String) -> Bool? {
            if let flag = value.bool { return flag }
            problems.append("\(path) must be true or false.")
            return nil
        }

        mutating func strings(_ value: JSONValue, _ path: String) -> [String]? {
            guard let items = value.array, items.allSatisfy({ $0.string != nil }) else {
                problems.append("\(path) must be a list of text.")
                return nil
            }
            return items.compactMap(\.string)
        }

        mutating func object(_ value: JSONValue, _ path: String, allowed: [String]) -> [String: JSONValue]? {
            guard case .object(let fields) = value else {
                problems.append("\(path) must be an object.")
                return nil
            }
            for key in fields.keys.sorted() where !allowed.contains(key) {
                problems.append("Unknown field \"\(path).\(key)\". The fields are \(allowed.joined(separator: ", ")).")
            }
            return fields
        }
    }

    private static func applyAgents(_ value: JSONValue, to settings: inout Settings, reader: inout Reader) {
        guard let entries = value.array else { return reader.problems.append("agents must be a list.") }
        for (index, entry) in entries.enumerated() {
            let path = "agents[\(index)]"
            guard let fields = reader.object(entry, path, allowed: agentFields) else { continue }
            let id = fields["id"].flatMap { reader.string($0, "\(path).id") }
            let presetID = fields["preset"].flatMap { reader.string($0, "\(path).preset") }
            if let presetID, AgentPreset.with(id: presetID) == nil {
                reader.problems.append("\(path).preset \"\(presetID)\" is not one of \(AgentPreset.all.map(\.id).joined(separator: ", ")).")
                continue
            }
            let existing = settings.agents.agents.firstIndex { agent in
                if let id { return agent.id == id }
                if let presetID, presetID != "custom" { return agent.presetID == presetID }
                return false
            }
            var agent: AgentConnection
            if let existing {
                agent = settings.agents.agents[existing]
                if let presetID, presetID != agent.presetID {
                    reader.problems.append("\(path).preset can't change an agent that exists. \"\(agent.id)\" is \(agent.presetID).")
                    continue
                }
            } else {
                guard let presetID, let preset = AgentPreset.with(id: presetID) else {
                    reader.problems.append("\(path) is a new agent, so it needs a \"preset\".")
                    continue
                }
                agent = preset.connection()
                if let id {
                    guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
                        reader.problems.append("\(path).id may use letters, numbers, - and _.")
                        continue
                    }
                    agent.id = id
                }
            }
            if let value = fields["name"], let name = reader.string(value, "\(path).name") {
                if name.trimmingCharacters(in: .whitespaces).isEmpty { reader.problems.append("\(path).name can't be empty.") } else { agent.name = name }
            }
            if let value = fields["command"], let words = reader.strings(value, "\(path).command") { agent.command = words }
            if let value = fields["host"] {
                if value == .null { agent.remoteHost = nil } else if let host = reader.string(value, "\(path).host") {
                    let host = host.trimmingCharacters(in: .whitespaces)
                    agent.remoteHost = host.isEmpty ? nil : host
                }
            }
            if let value = fields["spokenNames"], let names = reader.strings(value, "\(path).spokenNames") {
                agent.spokenNames = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let value = fields["destination"] { applyDestination(value, to: &agent, path: "\(path).destination", reader: &reader) }
            if agent.command.isEmpty { reader.problems.append("\(path) has no command. A custom agent needs \"command\", such as [\"my-agent\", \"acp\"].") }
            if let existing { settings.agents.agents[existing] = agent } else {
                if settings.agents.agents.contains(where: { $0.id == agent.id }) {
                    reader.problems.append("\(path).id \"\(agent.id)\" is already used in this list.")
                    continue
                }
                settings.agents.agents.append(agent)
            }
        }
    }

    private static func applyDestination(_ value: JSONValue, to agent: inout AgentConnection, path: String, reader: inout Reader) {
        let allowed = ["kind", "handle", "provider", "model", "botUsername", "executable", "arguments"]
        guard let fields = reader.object(value, path, allowed: allowed) else { return }
        var kind = agent.destination.kind
        if let value = fields["kind"] {
            guard let text = reader.string(value, "\(path).kind") else { return }
            guard let named = DestinationKind(rawValue: text) else {
                return reader.problems.append("\(path).kind \"\(text)\" is not one of \(DestinationKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            kind = named
        }
        if secretKinds.contains(kind) {
            if kind != agent.destination.kind {
                return reader.problems.append("\(path).kind \(kind.rawValue) holds a secret, so set it up in Lip Service on the Ghostwrite page.")
            }
            if fields.keys.contains(where: { $0 != "kind" }) {
                reader.problems.append("\(path) is \(kind.rawValue), which holds a secret. Change it in Lip Service on the Ghostwrite page.")
            }
            return
        }
        var destination = kind == agent.destination.kind ? agent.destination : kind.blank
        let own: [DestinationKind: [String]] = [.iMessage: ["handle"], .t3Code: ["provider", "model"], .telegram: ["botUsername"],
                                                .command: ["executable", "arguments"], .agentReply: []]
        for key in fields.keys.sorted() where key != "kind" && !(own[kind] ?? []).contains(key) {
            reader.problems.append("\(path).\(key) does not belong to \(kind.rawValue). It takes \((own[kind] ?? []).joined(separator: ", ").nilIfEmpty ?? "no fields").")
        }
        switch destination {
        case .iMessage:
            if let value = fields["handle"], let handle = reader.string(value, "\(path).handle") { destination = .iMessage(handle: handle.trimmingCharacters(in: .whitespaces)) }
        case .t3Code(var t3):
            for key in ["provider", "model"] {
                guard let value = fields[key] else { continue }
                let text = value == .null ? nil : reader.string(value, "\(path).\(key)").flatMap { $0.isEmpty ? nil : $0 }
                if key == "provider" { t3.provider = text } else { t3.model = text }
            }
            destination = .t3Code(t3)
        case .telegram:
            if let value = fields["botUsername"], let bot = reader.string(value, "\(path).botUsername") { destination = .telegram(botUsername: bot.trimmingCharacters(in: .whitespaces)) }
        case .command(var executable, var arguments):
            if let value = fields["executable"], let text = reader.string(value, "\(path).executable") { executable = text }
            if let value = fields["arguments"], let words = reader.strings(value, "\(path).arguments") { arguments = words }
            if executable.isEmpty { reader.problems.append("\(path).executable can't be empty.") }
            destination = .command(executable: executable, arguments: arguments)
        case .agentReply, .slack, .discord, .webhook:
            break
        }
        agent.destination = destination
    }

    private static func applyProfiles(_ value: JSONValue, to settings: inout Settings, reader: inout Reader) {
        let names = ProfileGroup.allCases.map(\.rawValue)
        guard let groups = reader.object(value, "profiles", allowed: names) else { return }
        for group in ProfileGroup.allCases {
            guard let entry = groups[group.rawValue] else { continue }
            let path = "profiles.\(group.rawValue)"
            guard let fields = reader.object(entry, path, allowed: ["style", "pressReturn"]) else { continue }
            var rules = settings.profiles.rules[group] ?? ProfileRules(style: .formal)
            if let value = fields["style"], let text = reader.string(value, "\(path).style") {
                if let style = WritingStyle(rawValue: text) { rules.style = style } else {
                    reader.problems.append("\(path).style \"\(text)\" is not one of \(WritingStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
            }
            if let value = fields["pressReturn"], let flag = reader.bool(value, "\(path).pressReturn") {
                if flag, !group.listsApps, !rules.pressReturn {
                    reader.problems.append("\(path).pressReturn can't be on. Return is pressed only for the groups that list apps.")
                } else {
                    rules.pressReturn = flag
                }
            }
            settings.profiles.set(rules, for: group)
        }
    }

    private static func applyKeys(_ value: JSONValue, to settings: inout Settings, reader: inout Reader) {
        guard let fields = reader.object(value, "keys", allowed: ["dictation", "ghostwrite", "handOff"]) else { return }
        if let value = fields["dictation"] {
            if let titles = reader.strings(value, "keys.dictation"), titles != settings.hotkeys.map(\.title) {
                reader.problems.append("keys.dictation can't be changed here. Change the dictation keys in Lip Service, on the Dictation page.")
            }
        }
        for (name, kind) in [("ghostwrite", CaptureKind.ghostwrite), ("handOff", .handOff)] {
            guard let value = fields[name] else { continue }
            if value == .null {
                _ = settings.setAgentKey(kind, nil)
            } else if let text = reader.string(value, "keys.\(name)") {
                guard let shortcut = Shortcut.parse(text) else {
                    reader.problems.append("keys.\(name) \"\(text)\" is not a key. Write it like \"⌃ fn\", \"⌥ fn\", \"Right Option\" or \"⌃⌘V\".")
                    continue
                }
                if let problem = settings.setAgentKey(kind, shortcut) { reader.problems.append("keys.\(name): \(problem)") }
            }
        }
    }

    // MARK: Change list

    /// What a setup changed, in plain words: who writes, where hand-offs go, the on/off choices, the voice, each group's
    /// style and the keys. Nothing for what stayed the same.
    public static func changes(from old: SetupFields, to new: SetupFields) -> [String] {
        var lines: [String] = []
        let oldCurrent = old.agents.current, current = new.agents.current
        if let current, current.id != oldCurrent?.id {
            lines.append("Ghostwrite writes with \(current.name)" + (current.hostName.map { " on \($0)" } ?? ""))
        }
        for agent in new.agents.agents {
            let before = old.agents.agent(id: agent.id)
            if let before {
                if before.name != agent.name { lines.append("Renamed \(before.name) to \(agent.name)") }
                if before.hostName != agent.hostName {
                    lines.append("\(agent.name) runs on " + (agent.hostName ?? "this Mac"))
                }
                if before.command != agent.command { lines.append("\(agent.name) starts with “\(agent.command.joined(separator: " "))”") }
                if before.spokenNames != agent.spokenNames {
                    lines.append(agent.spokenNames.isEmpty ? "\(agent.name) has no spoken names" : "Say " + agent.spokenNames.map { "“\($0)”" }.joined(separator: " or ") + " to use \(agent.name)")
                }
            } else if agent.id != current?.id {
                lines.append("Added \(agent.name)")
            }
            if before?.destination != agent.destination {
                lines.append(agent.id == current?.id ? "Hand offs go to \(agent.destination.title(agent: agent.name))"
                                                       : "\(agent.name) hand offs go to \(agent.destination.title(agent: agent.name))")
            }
        }
        if old.agents.reviewFirst != new.agents.reviewFirst {
            lines.append(new.agents.reviewFirst ? "Drafts show before they're typed" : "Drafts are typed straight away")
        }
        if old.agents.voiceExamples != new.agents.voiceExamples {
            lines.append(new.agents.voiceExamples ? "Drafts learn your voice from your dictations" : "Drafts no longer use your dictations as examples")
        }
        if old.agents.includeWindowText != new.agents.includeWindowText {
            lines.append(new.agents.includeWindowText ? "Hand offs include the window's text" : "Hand offs leave out the window's text")
        }
        if old.agents.voiceNotes != new.agents.voiceNotes {
            let notes = new.agents.voiceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(notes.isEmpty ? "Cleared your voice notes" : "Your voice: “\(notes.count > 90 ? notes.prefix(89) + "…" : Substring(notes))”")
        }
        for group in ProfileGroup.allCases {
            guard let rules = new.rules[group.rawValue], rules != old.rules[group.rawValue] else { continue }
            let before = old.rules[group.rawValue]
            var line = group.title + ": "
            if before?.style != rules.style {
                line += rules.style.title.lowercased()
                if before?.pressReturn != rules.pressReturn { line += rules.pressReturn ? ", and Return is pressed for you" : ", and Return is not pressed" }
            } else {
                line += rules.pressReturn ? "Return is pressed for you" : "Return is not pressed"
            }
            lines.append(line)
        }
        if old.ghostwriteKey != new.ghostwriteKey { lines.append("Ghostwrite key: " + (new.ghostwriteKey?.title ?? "off")) }
        if old.handOffKey != new.handOffKey { lines.append("Hand off key: " + (new.handOffKey?.title ?? "off")) }
        return lines
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Shortcut {
    /// Reads what `title` writes, and the plain-words form of the same: "⌃ fn", "ctrl+fn", "Right Option", "⌃⌘V".
    public static func parse(_ text: String) -> Shortcut? {
        let symbols: [Character: Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        let words: [(String, Modifiers)] = [("control", .control), ("ctrl", .control), ("option", .option), ("alt", .option),
                                            ("shift", .shift), ("command", .command), ("cmd", .command)]
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: " "))
        var modifiers: Modifiers = []
        scanning: while let first = rest.first {
            if let modifier = symbols[first] {
                modifiers.insert(modifier)
                rest = rest.dropFirst()
                continue
            }
            if first == " " {
                rest = rest.dropFirst()
                continue
            }
            for (word, modifier) in words where rest.lowercased().hasPrefix(word + " ") {
                modifiers.insert(modifier)
                rest = rest.dropFirst(word.count)
                continue scanning
            }
            break
        }
        let name = rest.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        if let key = ModifierKey.all.first(where: { $0.name.lowercased() == name }) { return Shortcut(key: key.code, modifiers: modifiers) }
        return KeyNames.code(named: name).map { Shortcut(key: $0, modifiers: modifiers) }
    }
}

/// The prompt the user pastes into their own agent, from the first run, the Ghostwrite page and the voice sheet.
public enum SetupPrompt {
    public static func text(executable: String) -> String {
        """
        Set up Lip Service for me. It's the dictation app on this Mac.
        1. Run: "\(executable)" setup show
        2. Ask me which agent should write for me, where hand-offs should go, and how I write in chats, work chat and email.
        3. From what you know about me, and anything I've written that you can reach, write a few lines on how I write: tone, greetings, sign-offs, punctuation, length.
        4. Apply it all with: "\(executable)" setup apply --by "<your name>", with the JSON on stdin.
        5. Run "\(executable)" setup test, and tell me what it says.
        """
    }
}
