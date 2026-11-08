import AppKit
import DictationCore
import SwiftUI

private struct FieldLabelWidth: EnvironmentKey { static let defaultValue: CGFloat = 150 }

extension EnvironmentValues {
    var fieldLabelWidth: CGFloat {
        get { self[FieldLabelWidth.self] }
        set { self[FieldLabelWidth.self] = newValue }
    }
}

/// "Who writes for you": every agent with where it runs and whether it answers. Picking one makes it the default.
/// Under it, where the default agent's hand-offs go, a test, and the settings most people never touch.
struct AgentSheet: View {
    let services: WindowServices
    let close: () -> Void
    @State private var adding: Bool
    @State private var advanced: Bool
    @State private var pairingCode = ""

    init(services: WindowServices, adding: Bool = false, advanced: Bool = false, close: @escaping () -> Void) {
        (self.services, self.close) = (services, close)
        _adding = State(initialValue: adding)
        _advanced = State(initialValue: advanced)
    }

    private var preferences: Preferences { services.preferences }

    var body: some View {
        let settings = preferences.current.settings.agents
        let current = settings.current
        let ordered = settings.agents.sorted { rank($0) < rank($1) }
        SheetOverlay(width: 500, close: close) {
            VStack(alignment: .leading, spacing: 12) {
                SheetTitle(title: "Who writes for you", done: close)
                VStack(spacing: 8) {
                    ForEach(ordered) { agent in
                        pickRow(initial: listInitial(preset: agent.presetID, name: agent.name), dashed: false, name: agent.name, selected: agent.id == current?.id,
                                detail: AnyView(detail(agent))) {
                            preferences.change { $0.agents.defaultAgent = agent.id }
                            services.agents.checkIfNeeded(agent)
                        }
                    }
                    pickRow(initial: "+", dashed: true, name: "Another agent", selected: adding,
                            detail: AnyView(Text("Add one that isn\u{2019}t set up yet").font(.system(size: 12)).foregroundStyle(Theme.secondary))) {
                        adding.toggle()
                    }
                    if adding {
                        ForEach(AgentPreset.all.filter { preset in preset.id == "custom" || !settings.agents.contains { $0.presetID == preset.id } }) { preset in
                            pickRow(initial: preset.id == "custom" ? "+" : listInitial(preset: preset.id, name: preset.name), dashed: false,
                                    name: preset.id == "custom" ? "Your own agent" : preset.name, selected: false,
                                    detail: AnyView(Text(found(preset)).font(.system(size: 12)).foregroundStyle(Theme.secondary))) { add(preset) }
                                .padding(.leading, 18)
                        }
                    }
                }
                if let agent = current {
                    Divider().overlay(Theme.line)
                    section(for: agent)
                }
            }
        }
        .onAppear { services.agents.detect() }
    }

    private func rank(_ agent: AgentConnection) -> Int {
        switch services.agents.state(of: agent) {
        case .notInstalled: 1
        default: 0
        }
    }

    private func found(_ preset: AgentPreset) -> String {
        if preset.id == "custom" { return "Any agent that speaks the Agent Client Protocol" }
        return services.agents.installed?.contains(preset.id) == true ? "On this Mac" : "Not found on this Mac. Set Runs on to use another one."
    }

    private func detail(_ agent: AgentConnection) -> some View {
        let state = services.agents.state(of: agent)
        let status: String = switch state {
        case .ready: "Ready"
        case .checking: "Checking…"
        case .unchecked: "Not checked yet"
        case .unreachable: "Can't reach"
        case .notInstalled: "Not installed"
        }
        return Text("\(agent.placeName) · \(status)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
    }

    private func pickRow(initial: String, dashed: Bool, name: String, selected: Bool, detail: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if dashed {
                    Text(initial).font(.system(size: 14)).foregroundStyle(Theme.secondary).frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                } else {
                    AgentAvatar(initial: initial, size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14))
                    detail
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.blue : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ preset: AgentPreset) {
        let connection = preset.connection()
        preferences.change { settings in
            settings.agents.agents.append(connection)
            settings.agents.defaultAgent = connection.id
        }
        adding = false
        advanced = preset.id == "custom"
        services.agents.checkIfNeeded(connection)
    }

    @ViewBuilder private func section(for agent: AgentConnection) -> some View {
        let state = services.agents.state(of: agent)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.system(size: 14, weight: .semibold))
                    AgentStatusLine(agent: agent, state: state, showsPlace: false)
                }
                Spacer()
                Button(state == .checking ? "Testing…" : "Test") { services.agents.test(agent) }
                    .buttonStyle(DarkButtonStyle()).disabled(state == .checking)
            }
            Text("Hand off goes to").font(.system(size: 13.5, weight: .semibold)).padding(.top, 4)
            DestinationFields(agent: agent, services: services, pairingCode: $pairingCode, update: update(agent))
            Button { advanced.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(advanced ? 90 : 0))
                    Text("Advanced")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            if advanced { advancedFields(agent) }
        }
        .environment(\.fieldLabelWidth, 110)
    }

    private func advancedFields(_ agent: AgentConnection) -> some View {
        let update = update(agent)
        return VStack(alignment: .leading, spacing: 10) {
            LabeledField(title: "Name", text: Binding(get: { agent.name }, set: { value in update { $0.name = value } }))
            CommandField(command: agent.command) { words in update { $0.command = words } }
            LabeledField(title: "Runs on", text: Binding(get: { agent.remoteHost ?? "" }, set: { value in update { $0.remoteHost = value.isEmpty ? nil : value } }),
                         prompt: "This Mac", help: "Another Mac's ssh name, such as mini, to run the agent there over ssh.")
            LabeledField(title: "Also called", text: Binding(get: { agent.spokenNames.joined(separator: ", ") },
                                                             set: { value in update { $0.spokenNames = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }),
                         help: "Start a request with one, as in \u{201C}\(agent.spokenNames.first ?? agent.name), reply…\u{201D}, to use this agent for it.")
            ModelMenus(agent: agent, catalog: services.agents.catalogs[agent.id], update: update)
            Button("Remove \(agent.name)") {
                preferences.change { $0.agents.agents.removeAll { $0.id == agent.id } }
            }
            .buttonStyle(DarkButtonStyle(kind: .destructive))
        }
    }

    private func update(_ agent: AgentConnection) -> (@escaping (inout AgentConnection) -> Void) -> Void {
        { edit in
            preferences.change { settings in
                guard let index = settings.agents.agents.firstIndex(where: { $0.id == agent.id }) else { return }
                edit(&settings.agents.agents[index])
            }
        }
    }
}

/// The voice notes, written by the user, built by the agent, or left to the user's own agent through the setup prompt.
struct VoiceSheet: View {
    let services: WindowServices
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        let agent = services.preferences.current.settings.agents.current
        SheetOverlay(width: 520, close: close) {
            VStack(alignment: .leading, spacing: 12) {
                SheetTitle(title: "Your voice", done: close)
                Text("How you write, sent with every draft. Write it yourself, or let your agent write it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                TextEditor(text: services.preferences.binding(\.agents.voiceNotes))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.tile))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line))
                HStack(spacing: 10) {
                    if let agent {
                        Button(services.agents.building ? "Writing…" : "Build with \(agent.name)") { services.agents.buildVoiceNotes(with: agent) }
                            .buttonStyle(DarkButtonStyle()).disabled(services.agents.building)
                    }
                    Button(copied ? "Copied" : "Copy setup prompt") {
                        services.copy(SetupPrompt.forThisApp)
                        copied = true
                    }
                    .buttonStyle(DarkButtonStyle())
                    .help("A prompt to paste into your own agent. It asks you a few things and sets Lip Service up, voice included.")
                }
                if let problem = services.agents.buildProblem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber) }
            }
        }
    }
}

/// The command exactly as typed, saved as shell words on every change. The field keeps the typed text, so a space or
/// an unclosed quote isn't rewritten while typing; it reloads only when the saved command changes from elsewhere.
private struct CommandField: View {
    var title = "Command"
    let command: [String]
    var prompt = ""
    var help = "Runs through your login shell, so it finds the same programs your terminal does. Quote a path that has spaces."
    let save: ([String]) -> Void
    @State private var text = ""

    var body: some View {
        LabeledField(title: title, text: Binding(get: { text }, set: { value in
            text = value
            save(ShellWords.split(value))
        }), prompt: prompt, help: help)
        .onAppear { text = ShellWords.join(command) }
        .onChange(of: command) { if ShellWords.split(text) != command { text = ShellWords.join(command) } }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var help: String?
    var secure = false
    @Environment(\.fieldLabelWidth) private var labelWidth

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.secondary).frame(width: labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tile))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                if let help { Text(help).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
            }
        }
    }
}

/// The fast model for drafts, the full one for tasks, and the quick one for live talks, filled from what the agent reported the last time it ran.
struct ModelMenus: View {
    let agent: AgentConnection
    let catalog: SessionInfo?
    let update: (@escaping (inout AgentConnection) -> Void) -> Void

    var body: some View {
        let model = catalog?.options.first { $0.id == "model" || $0.category == "model" }
        let effort = catalog?.options.first { $0.id == "effort" || $0.id == "reasoning_effort" || $0.category == "thought_level" }
        let models = model?.choices ?? catalog?.models ?? []
        VStack(alignment: .leading, spacing: 10) {
            if models.isEmpty {
                Text("Test \(agent.name) once to fill in its models.").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
            } else {
                picker("Drafts use", models, current: Self.value(agent.draftOptions, model?.id), usesConfig: model != nil) { choice in
                    update { $0.draftOptions = Self.replace($0.draftOptions, id: model?.id, with: choice, usesConfig: model != nil) }
                }
                if let effort {
                    picker("Draft effort", effort.choices, current: Self.value(agent.draftOptions, effort.id), usesConfig: true) { choice in
                        update { $0.draftOptions = Self.replace($0.draftOptions, id: effort.id, with: choice, usesConfig: true) }
                    }
                }
                picker("Tasks use", models, current: Self.value(agent.taskOptions, model?.id), usesConfig: model != nil, defaultTitle: "Its own default") { choice in
                    update { $0.taskOptions = Self.replace($0.taskOptions, id: model?.id, with: choice, usesConfig: model != nil) }
                }
                picker("Live talk uses", models, current: Self.value(agent.talkOptions, model?.id), usesConfig: model != nil, defaultTitle: "Its own default") { choice in
                    update { $0.talkOptions = Self.replace($0.talkOptions, id: model?.id, with: choice, usesConfig: model != nil) }
                }
                if let effort {
                    picker("Talk effort", effort.choices, current: Self.value(agent.talkOptions, effort.id), usesConfig: true, defaultTitle: "Its own default") { choice in
                        update { $0.talkOptions = Self.replace($0.talkOptions, id: effort.id, with: choice, usesConfig: true) }
                    }
                }
            }
        }
    }

    private func picker(_ title: String, _ choices: [ConfigOption.Choice], current: String?, usesConfig: Bool, defaultTitle: String? = nil,
                        set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.secondary).frame(width: 110, alignment: .leading)
            Picker(title, selection: Binding(get: { current ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
                if let defaultTitle { Text(defaultTitle).tag("") }
                ForEach(choices, id: \.value) { Text($0.name).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    static func value(_ choices: [ConfigChoice], _ id: String?) -> String? {
        for choice in choices {
            switch choice {
            case .option(let option, let value) where option == id: return value
            case .model(let model) where id == nil: return model
            default: continue
            }
        }
        return nil
    }

    /// Puts the choice in place of the old one for that setting, keeping the order the agent needs: model first.
    static func replace(_ choices: [ConfigChoice], id: String?, with value: String?, usesConfig: Bool) -> [ConfigChoice] {
        var rest = choices.filter { choice in
            switch choice {
            case .option(let option, _): option != id
            case .model: usesConfig
            }
        }
        guard let value else { return rest }
        let choice: ConfigChoice = usesConfig ? .option(id: id ?? "model", value: value) : .model(value)
        if id == "model" || !usesConfig { rest.insert(choice, at: 0) } else { rest.append(choice) }
        return rest
    }
}

/// Where this agent's hand-offs go, with the fields that kind needs. Tokens and webhook addresses go to the Keychain.
struct DestinationFields: View {
    let agent: AgentConnection
    let services: WindowServices
    @Binding var pairingCode: String
    var showsPicker = true
    let update: (@escaping (inout AgentConnection) -> Void) -> Void
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsPicker {
                Picker("Hand off goes to", selection: Binding(get: { agent.destination.kind }, set: { kind in update { $0.destination = kind.blank } })) {
                    ForEach(DestinationKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            switch agent.destination {
            case .iMessage(let handle):
                LabeledField(title: "iMessage to", text: Binding(get: { handle }, set: { value in update { $0.destination = .iMessage(handle: value) } }),
                             prompt: "+1 555 123 4567", help: "Sent from your own Messages, so it lands in the chat where \(agent.name) always answers you.")
            case .t3Code:
                t3Fields
            case .telegram(let bot):
                LabeledField(title: "Bot username", text: Binding(get: { bot }, set: { value in update { $0.destination = .telegram(botUsername: value) } }),
                             prompt: "@my_agent_bot", help: "Opens the chat with your message typed in. You press Return there.")
            case .slack(let team, let bot, let key):
                LabeledField(title: "Workspace", text: Binding(get: { team }, set: { value in update { $0.destination = .slack(team: value, botUserID: bot, tokenKey: key) } }))
                LabeledField(title: "Bot's member ID", text: Binding(get: { bot }, set: { value in update { $0.destination = .slack(team: team, botUserID: value, tokenKey: key) } }),
                             prompt: "U0123456")
                secretField("Your user token", key: key, prompt: "xoxp-…", help: "From your own Slack app, with chat:write and im:write. Kept in the Keychain.")
            case .discord(let key, let botID):
                secretField("Channel webhook", key: key, prompt: "https://discord.com/api/webhooks/…", help: "Kept in the Keychain.")
                LabeledField(title: "Bot's user ID", text: Binding(get: { botID }, set: { value in update { $0.destination = .discord(webhookKey: key, botID: value) } }))
            case .webhook(let url, let key):
                LabeledField(title: "Web address", text: Binding(get: { url }, set: { value in update { $0.destination = .webhook(url: value, secretKey: key) } }),
                             prompt: "https://…", help: "Gets a JSON POST signed with X-Hub-Signature-256.")
                if let key { secretField("Signing secret", key: key, prompt: "", help: "Kept in the Keychain.") }
            case .command(let executable, let arguments):
                CommandField(title: "Program", command: executable.isEmpty && arguments.isEmpty ? [] : [executable] + arguments,
                             prompt: "/usr/local/bin/my-handler",
                             help: "Run without a shell. Gets the hand-off as JSON on stdin and in LS_TEXT. Quote a path that has spaces.") { words in
                    update { $0.destination = .command(executable: words.first ?? "", arguments: Array(words.dropFirst())) }
                }
            case .agentReply:
                Text("\(agent.name) does the task and its answer shows in the card.").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .onAppear { services.agents.refreshT3(agent) }
    }

    @ViewBuilder private var t3Fields: some View {
        let state = services.agents.t3[agent.id] ?? .unknown
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .connected(let expires):
                Text("Connected to T3 Code until \(expires.formatted(date: .abbreviated, time: .omitted)).").font(.system(size: 13)).foregroundStyle(Theme.green)
            case .connecting:
                Text("Connecting…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            case .failed(let reason):
                Text(reason).font(.system(size: 13)).foregroundStyle(Theme.amber)
            case .unknown, .notConnected:
                Text("Make a pairing code in T3 Code (Settings, Connections), paste it here and press Connect T3 Code. You pick a project for each hand-off.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 10) {
                LabeledField(title: "Pairing code", text: $pairingCode)
                Button("Connect T3 Code") { services.agents.connectT3(agent, code: pairingCode); pairingCode = "" }
                    .buttonStyle(DarkButtonStyle(kind: .prominent)).disabled(pairingCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func secretField(_ title: String, key: String, prompt: String, help: String) -> some View {
        HStack(spacing: 10) {
            LabeledField(title: title, text: $secret, prompt: Keychain().read(key) == nil ? prompt : "Saved", help: help, secure: true)
            Button("Save") {
                try? Keychain().save(key, secret)
                secret = ""
            }
            .buttonStyle(DarkButtonStyle()).disabled(secret.isEmpty)
        }
    }
}
