import AppKit
import AVFoundation
import DictationCore
import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome, permissions, tryIt, style, ghostwrite, check, done

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .tryIt: "Try it"
        case .style: "How you write"
        case .ghostwrite: "Ghostwrite"
        case .check: "Check"
        case .done: "Done"
        }
    }
}

/// Where the first run is, and what the user picked on the way. Settings are written as each step is left, so closing
/// the window anywhere keeps what was done.
@MainActor @Observable final class OnboardingModel {
    var step = SetupStep.welcome
    /// The "Let my agent set it up" screen of the welcome step.
    var agentPath = false
    var agentPathStarted = Date.now
    var copied = false
    var choice = "hermes"
    var hermesHost = ""
    var customCommand = ""
    var skippedGhostwrite = false
    var tried = false
    var tryBaseline = 0
    var tryText = ""
    var pairingCode = ""
    var onFinish: () -> Void = {}

    func go(_ step: SetupStep) { self.step = step }
}

struct OnboardingView: View {
    let services: WindowServices
    @Bindable var model: OnboardingModel

    private var preferences: Preferences { services.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(SetupStep.allCases, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2).fill(step.rawValue <= model.step.rawValue ? Theme.blue : Color(hex: 0x3A3B40)).frame(width: 18, height: 4)
                }
                Spacer()
                if model.step != .welcome { Text(model.step.title).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 20)
            footer.padding(.top, 8)
        }
        .padding(.horizontal, 34).padding(.top, 14).padding(.bottom, 22)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
        .foregroundStyle(Theme.text)
        .tint(Theme.blue)
        .background(Theme.canvas, ignoresSafeAreaEdges: .all)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(services: services, model: model)
        case .permissions: PermissionsStep(services: services)
        case .tryIt: TryItStep(services: services, model: model)
        case .style: StyleStep(preferences: preferences)
        case .ghostwrite: GhostwriteStep(services: services, model: model)
        case .check: CheckStep(services: services, model: model)
        case .done: DoneStep(services: services, model: model)
        }
    }

    private var checks: SetupChecks { services.setup.checks }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch model.step {
            case .welcome:
                if model.agentPath {
                    if let record = appliedRecord {
                        Button("Undo") { preferences.undoSetup(); model.agentPathStarted = .now }.buttonStyle(DarkButtonStyle())
                        Spacer()
                        Button("Continue") { model.go(.permissions) }.buttonStyle(DarkButtonStyle(kind: .prominent))
                            .help(record.title)
                    } else {
                        Button("Back") { model.agentPath = false }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button(model.copied ? "Copied" : "Copy prompt") {
                            services.copy(SetupPrompt.forThisApp)
                            model.copied = true
                        }
                        .buttonStyle(DarkButtonStyle(kind: .prominent))
                    }
                } else {
                    Spacer()
                }
            case .permissions:
                back(.welcome)
                Spacer()
                // The fn row can't hold up setup: macOS may leave its setting unsaved while showing Do Nothing.
                Button("Continue") { model.go(.tryIt) }.buttonStyle(DarkButtonStyle(kind: .prominent))
                    .disabled(!(checks.microphone && checks.accessibility))
            case .tryIt:
                back(.permissions)
                Spacer()
                Button("Skip") { model.go(.style) }.buttonStyle(.plain).foregroundStyle(Theme.secondary).padding(.trailing, 6)
                Button("Continue") { model.go(.style) }.buttonStyle(DarkButtonStyle(kind: .prominent)).disabled(!model.tried)
            case .style:
                back(.tryIt)
                Spacer()
                Button("Continue") { model.go(.ghostwrite) }.buttonStyle(DarkButtonStyle(kind: .prominent))
            case .ghostwrite:
                back(.style)
                Spacer()
                Button("Skip") { model.skippedGhostwrite = true; model.go(.done) }.buttonStyle(.plain).foregroundStyle(Theme.secondary).padding(.trailing, 6)
                Button("Continue") {
                    model.skippedGhostwrite = false
                    GhostwriteStep.commit(model, services: services)
                    model.go(.check)
                }
                .buttonStyle(DarkButtonStyle(kind: .prominent)).disabled(!GhostwriteStep.canContinue(model, services: services))
            case .check:
                back(.ghostwrite)
                Spacer()
                Button("Continue") { model.go(.done) }.buttonStyle(DarkButtonStyle(kind: .prominent)).disabled(!CheckStep.canContinue(services: services))
            case .done:
                back(model.skippedGhostwrite ? .ghostwrite : .check)
                Spacer()
                Button("Open Lip Service") { model.onFinish() }.buttonStyle(DarkButtonStyle(kind: .prominent))
            }
        }
        .frame(height: 36)
    }

    private func back(_ step: SetupStep) -> some View {
        Button("Back") { model.go(step) }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
    }

    /// An agent's setup applied since the prompt screen was opened.
    private var appliedRecord: SetupRecord? {
        preferences.setupRecord.flatMap { $0.date >= model.agentPathStarted ? $0 : nil }
    }
}

private struct StepTitle: View {
    let title: String
    let lead: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            lead.font(.system(size: 13.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 16)
    }
}

// MARK: Welcome

private struct WelcomeStep: View {
    let services: WindowServices
    @Bindable var model: OnboardingModel

    var body: some View {
        if model.agentPath {
            if let record = services.preferences.setupRecord.flatMap({ $0.date >= model.agentPathStarted ? $0 : nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    StepTitle(title: record.title, lead: Text("Here's what it changed."))
                    AppliedNotice(record: record, limit: 7, showsTitle: false)
                    Text("Permissions still need you. That's next.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.top, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    StepTitle(title: "Let your agent set it up",
                              lead: Text("Paste this into the agent you use. It looks at what's on this Mac, asks you a few things, and sets up Lip Service. You'll see what it changed, with Undo."))
                    PromptBox(text: SetupPrompt.forThisApp)
                    HStack(spacing: 8) {
                        Circle().fill(Theme.tertiary).frame(width: 7, height: 7)
                        Text("Waiting for your agent…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 14)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lip Service").font(.system(size: 30, weight: .semibold)).padding(.top, 24)
                Text("Hold fn, talk, let go. Your words show up where you're typing.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    choice("Set it up", "A few permissions, then pick how your words look.") { model.go(.permissions) }
                    choice("Let my agent set it up", "Copy a prompt for Claude Code, Codex, Hermes or any agent. It asks how you like it and does the rest.") {
                        model.agentPath = true
                        model.agentPathStarted = .now
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    private func choice(_ title: String, _ note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Permissions

private struct PermissionsStep: View {
    let services: WindowServices
    @State private var askedAccessibility = false

    var body: some View {
        let checks = services.setup.checks
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Permissions", lead: Text("Lip Service runs on your Mac. Nothing you say leaves it unless you use Ghostwrite or Hand off."))
            RowList {
                row("Microphone", "To hear you.", done: checks.microphone, label: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? "Allow" : "Open Settings",
                    first: true) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { Microphone.requestAccessIfNeeded() } else { SystemSettingsPane.microphone.open() }
                }
                row("Accessibility", "So fn works in every app and the text goes in where you're typing.", done: checks.accessibility,
                    label: askedAccessibility ? "Open Settings" : "Allow") {
                    if askedAccessibility { SystemSettingsPane.accessibility.open(); return }
                    // The system prompt also lists Lip Service in System Settings, with its switch ready to turn on.
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    askedAccessibility = true
                }
                row("fn key", "Set “Press fn key to” to Do Nothing, so fn only dictates.", done: checks.fnKey != .needsSetting, label: "Open Keyboard") {
                    SystemSettingsPane.keyboard.open()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                services.setup.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func row(_ title: String, _ why: String, done: Bool, label: String, first: Bool = false, action: @escaping () -> Void) -> some View {
        ListRow(divider: !first) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(why).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if done {
                Label("Done", systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
            } else {
                Button(label, action: action).buttonStyle(DarkButtonStyle(kind: .prominent))
            }
        }
    }
}

// MARK: Try it

private struct TryItStep: View {
    let services: WindowServices
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Try it", lead: Text("Hold fn, say something, and let go."))
            TextEditor(text: $model.tryText)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)
                .frame(height: 118)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
                .overlay(alignment: .topLeading) {
                    if model.tryText.isEmpty {
                        (Text("Click here, then hold ") + Text("fn").bold() + Text(" and talk."))
                            .font(.system(size: 14)).foregroundStyle(Theme.tertiary).padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false)
                    }
                }
            if model.tried, let seconds = services.timing.seconds {
                Text("✓ That took \(String(format: "%.1f", seconds)) s").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green).padding(.top, 12)
            }
        }
        .onAppear {
            model.tryBaseline = services.timing.serial
            focused = true
        }
        .onChange(of: services.timing.serial) { _, serial in
            if serial != model.tryBaseline { model.tried = true }
        }
    }
}

// MARK: How you write

private struct StyleStep: View {
    let preferences: Preferences

    var body: some View {
        let profiles = preferences.current.settings.profiles
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "How should your words look?", lead: Text("Lip Service picks from the app you're in. Change it any time in Profiles."))
            VStack(spacing: 0) {
                ForEach(Array(ProfileGroup.allCases.enumerated()), id: \.element) { index, group in
                    let rules = profiles.rules[group] ?? ProfileRules(style: .formal)
                    HStack(spacing: 14) {
                        Text(group.title).font(.system(size: 13.5, weight: .semibold)).frame(width: 112, alignment: .leading)
                        Segmented(options: WritingStyle.allCases.map { ($0.title, $0) },
                                  selection: Binding(get: { rules.style },
                                                     set: { style in preferences.change { $0.profiles.set(ProfileRules(style: style, pressReturn: rules.pressReturn), for: group) } }))
                        Text(rules.style.apply("Sounds good, see you at 5.", keeping: []))
                            .font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xC9CACD)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { if index > 0 { Theme.line.frame(height: 1) } }
                }
            }
        }
    }
}

// MARK: Ghostwrite

private struct GhostwriteStep: View {
    let services: WindowServices
    @Bindable var model: OnboardingModel

    /// The agents to offer: those found on this Mac, then Hermes, which is offered either way, then any other.
    struct Option: Identifiable {
        let id: String
        let name: String
        let place: String
    }

    static func options(found: Set<String>?) -> [Option] {
        let found = found ?? []
        var list = AgentPreset.all.filter { $0.id != "custom" && found.contains($0.id) }
            .map { Option(id: $0.id, name: $0.name, place: "On this Mac") }
        if !found.contains("hermes") { list.append(Option(id: "hermes", name: "Hermes", place: "On another Mac")) }
        list.append(Option(id: "custom", name: "Another agent", place: "Any agent that speaks the Agent Client Protocol"))
        return list
    }

    static func canContinue(_ model: OnboardingModel, services: WindowServices) -> Bool {
        switch model.choice {
        case "custom": return !model.customCommand.trimmingCharacters(in: .whitespaces).isEmpty
        case "hermes": return services.agents.installed?.contains("hermes") == true || !model.hermesHost.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    /// Makes the picked agent the default, adding it when it is new.
    static func commit(_ model: OnboardingModel, services: WindowServices) {
        services.preferences.change { settings in
            var agents = settings.agents
            var agent: AgentConnection
            let typed = model.customCommand.trimmingCharacters(in: .whitespaces)
            if model.choice == "custom", let current = agents.current, current.presetID == "custom",
               current.command == ShellWords.split(typed) {
                agent = current
            } else if model.choice == "custom" {
                agent = AgentPreset.with(id: "custom")!.connection()
                agent.command = ShellWords.split(typed)
                if let existing = agents.agents.first(where: { $0.presetID == "custom" && $0.command == agent.command }) { agent = existing }
            } else {
                guard let preset = AgentPreset.with(id: model.choice) else { return }
                agent = agents.agents.first { $0.presetID == preset.id } ?? preset.connection()
                if preset.id == "hermes", services.agents.installed?.contains("hermes") != true {
                    let host = model.hermesHost.trimmingCharacters(in: .whitespaces)
                    agent.remoteHost = host.isEmpty ? nil : host
                }
            }
            if let index = agents.agents.firstIndex(where: { $0.id == agent.id }) { agents.agents[index] = agent } else { agents.agents.append(agent) }
            agents.defaultAgent = agent.id
            settings.agents = agents
        }
    }

    var body: some View {
        let options = Self.options(found: services.agents.installed)
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Ghostwrite",
                      lead: Text("Hold ") + Text("⌃ fn").bold() + Text(" and say what you want, like “reply that Thursday works”. Your agent writes it in your voice."))
            VStack(spacing: 8) {
                ForEach(options) { option in
                    let selected = model.choice == option.id
                    Button { model.choice = option.id } label: {
                        HStack(spacing: 12) {
                            if option.id == "custom" {
                                Text("+").font(.system(size: 14)).foregroundStyle(Theme.secondary).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            } else {
                                AgentAvatar(initial: listInitial(preset: option.id, name: option.name), size: 30)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.name).font(.system(size: 14))
                                Text(option.place).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 8)
                            if selected, option.id == "hermes", option.place == "On another Mac" {
                                Text("Mac").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                field("mini", text: $model.hermesHost, width: 100)
                            }
                            if selected, option.id == "custom" {
                                field("my-agent acp", text: $model.customCommand, width: 190)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.blue : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Ghostwrite sends what you say and the text of the window you're in to this agent.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.top, 12)
        }
        .onAppear {
            services.agents.detect()
            if let current = services.preferences.current.settings.agents.current {
                model.choice = current.presetID
                if model.hermesHost.isEmpty, let host = current.hostName { model.hermesHost = host }
                if model.customCommand.isEmpty, current.presetID == "custom" { model.customCommand = ShellWords.join(current.command) }
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x101113)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
    }
}

// MARK: Check

private struct CheckStep: View {
    let services: WindowServices
    @Bindable var model: OnboardingModel

    private var agent: AgentConnection? { services.preferences.current.settings.agents.current }

    /// Hermes and any agent with no better place use iMessage or the card, so a handle must be filled in for iMessage.
    static func canContinue(services: WindowServices) -> Bool {
        guard let agent = services.preferences.current.settings.agents.current else { return true }
        switch agent.destination {
        case .iMessage(let handle): return !handle.trimmingCharacters(in: .whitespaces).isEmpty
        case .telegram(let bot): return !bot.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    /// The kinds the picked agent offers: its own first.
    static func kinds(for agent: AgentConnection) -> [DestinationKind] {
        switch agent.presetID {
        case "hermes": [.iMessage, .telegram, .agentReply]
        case "claude", "codex": [.t3Code, .agentReply]
        default: [.agentReply]
        }
    }

    var body: some View {
        if let agent {
            let state = services.agents.state(of: agent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Checking \(agent.name)").font(.system(size: 22, weight: .semibold)).padding(.bottom, 6)
                result(agent, state).padding(.bottom, 16)
                destination(agent)
            }
            .onAppear {
                services.agents.detect()
                if state != .checking, state != .notInstalled { services.agents.test(agent) }
            }
        } else {
            Text("No agent yet.").foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder private func result(_ agent: AgentConnection, _ state: AgentServices.State) -> some View {
        switch state {
        case .checking, .unchecked:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(agent.name) to say hi…").font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
            }
        case .ready(let seconds):
            Text("✓ \(agent.name) answered in \(String(format: "%.1f", seconds)) s").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.green)
        case .notInstalled:
            problem("\(agent.name) isn't installed on this Mac.", agent)
        case .unreachable(let reason):
            problem(reason, agent)
        }
    }

    private func problem(_ reason: String, _ agent: AgentConnection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason).font(.system(size: 13)).foregroundStyle(Theme.amber).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let hint = agent.hint(forTrouble: reason) {
                Text(hint).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Try again") { services.agents.test(agent) }.buttonStyle(DarkButtonStyle())
                Button("Back") { model.go(.ghostwrite) }.buttonStyle(DarkButtonStyle())
            }
        }
    }

    private func destination(_ agent: AgentConnection) -> some View {
        let kinds = Self.kinds(for: agent)
        let update: (@escaping (inout AgentConnection) -> Void) -> Void = { edit in
            services.preferences.change { settings in
                guard let index = settings.agents.agents.firstIndex(where: { $0.id == agent.id }) else { return }
                edit(&settings.agents.agents[index])
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Hand off sends tasks to").font(.system(size: 14, weight: .semibold))
            if kinds.count > 1 {
                Segmented(options: kinds.map { ($0 == .agentReply ? "Reply in the card" : $0.title, $0) },
                          selection: Binding(get: { kinds.contains(agent.destination.kind) ? agent.destination.kind : kinds[0] },
                                             set: { kind in update { $0.destination = kind.blank } }))
            } else {
                Text("Reply in the card").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            DestinationFields(agent: agent, services: services, pairingCode: $model.pairingCode, showsPicker: false, update: update)
                .environment(\.fieldLabelWidth, 110)
            Text(note(agent)).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
    }

    private func note(_ agent: AgentConnection) -> String {
        let key = services.preferences.current.settings.handOffKey?.title ?? "⌥ fn"
        if case .agentReply = agent.destination { return "Hold \(key) and say a task. \(agent.name) does it and its answer shows in the card." }
        return "Hold \(key) and say a task. \(agent.name) keeps going in its own app."
    }
}

// MARK: Done

private struct DoneStep: View {
    let services: WindowServices
    let model: OnboardingModel

    var body: some View {
        let settings = services.preferences.current.settings
        let live = settings.agents.current != nil
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "You're set", lead: Text("Hold a key, talk, let go."))
            RowList {
                row(settings.hotkeys.first?.title ?? "fn", "Dictate, anywhere you type", on: true, first: true)
                row(settings.ghostwriteKey?.title ?? "Off", live ? "Ghostwrite: say what you want, your agent writes it" : "Ghostwrite: set up an agent on the Ghostwrite page",
                    on: live && settings.ghostwriteKey != nil)
                row(settings.handOffKey?.title ?? "Off", live ? "Hand off: send a task to your agent" : "Hand off: set up an agent on the Ghostwrite page",
                    on: live && settings.handOffKey != nil)
            }
        }
    }

    private func row(_ key: String, _ what: String, on: Bool, first: Bool = false) -> some View {
        ListRow(divider: !first) {
            Kbd(title: key, blue: on).frame(minWidth: 52)
            Text(what).font(.system(size: 14)).foregroundStyle(on ? Theme.text : Theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Window

/// The first run's own window, about 640 by 520. It never has a resize handle.
@MainActor final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 640, height: 520)

    private let services: WindowServices
    private let model = OnboardingModel()
    private var window: NSWindow?
    var onClose: () -> Void = {}
    var openMain: () -> Void = {}

    init(services: WindowServices) { self.services = services }

    var isOpen: Bool { window != nil }

    func open(at step: SetupStep = .welcome) {
        model.step = step
        if step == .welcome { model.agentPath = false }
        model.tried = false
        model.onFinish = { [weak self] in self?.finish() }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        close()
        openMain()
    }

    func close() { window?.close() }

    func windowDidBecomeKey(_ notification: Notification) { services.setup.refresh() }

    func windowWillClose(_ notification: Notification) {
        services.preferences.finishOnboarding()
        window = nil
        onClose()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        Self.configure(window, services: services, model: model)
        window.delegate = self
        window.center()
        return window
    }

    static func configure(_ window: NSWindow, services: WindowServices, model: OnboardingModel) {
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "Set up Lip Service"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.contentView = NSHostingView(rootView: OnboardingView(services: services, model: model))
    }

    /// For the window render.
    var renderModel: OnboardingModel { model }
}
