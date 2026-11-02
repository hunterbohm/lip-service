import AppKit
import DictationCore
import SwiftUI

struct GhostwritePage: View {
    let services: WindowServices
    @Bindable var state: WindowState
    @State private var recording: CaptureKind?
    @State private var problem: String?
    @State private var copied = false

    private var preferences: Preferences { services.preferences }
    private var agents: AgentServices { services.agents }

    var body: some View {
        let settings = preferences.current.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Ghostwrite", lead: "Say what you want written. Your agent writes it in your voice.")
                if let agent = settings.agents.current {
                    AgentTile(agent: agent, services: services) { state.sheet = .agents }
                    HStack(spacing: 10) {
                        keyTile("Ghostwrite", "Writes it where you're typing", .ghostwrite, settings.ghostwriteKey)
                        keyTile("Hand off", handOffNote(agent), .handOff, settings.handOffKey)
                    }
                    .padding(.top, 12)
                    if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber).padding(.top, 10) }
                    if recording != nil {
                        Text("Press a key or a combination, or a modifier key on its own and let go. Escape cancels.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 10)
                    }
                    RowList {
                        ListRow(divider: false) { toggle("Show the draft before typing it", preferences.binding(\.agents.reviewFirst)) }
                        ListRow { toggle("Learn my voice from my dictations", preferences.binding(\.agents.voiceExamples)) }
                        ListRow { toggle("Send the window's text with hand-offs", preferences.binding(\.agents.includeWindowText)) }
                        ListRow { voiceRow(settings.agents.voiceNotes) }
                    }
                    .padding(.top, 16)
                } else {
                    EmptyTile { services.openSetup(.ghostwrite) }
                }
                HStack(spacing: 4) {
                    Text(settings.agents.current == nil ? "Want your agent to set it up?" : "Want your agent to change these?")
                        .foregroundStyle(Theme.tertiary)
                    LinkButton(title: copied ? "Copied" : "Copy setup prompt") {
                        services.copy(SetupPrompt.forThisApp)
                        copied = true
                    }
                }
                .font(.system(size: 12.5))
                .padding(.top, 14)
            }
            .page()
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            agents.detect()
            if let agent = settings.agents.current { agents.checkIfNeeded(agent) }
        }
        .onDisappear { stopRecording() }
    }

    private func handOffNote(_ agent: AgentConnection) -> String {
        if case .agentReply = agent.destination { return "Hands a task to \(agent.name) and shows its reply" }
        return "Sends a task to \(agent.destination.title(agent: agent.name))"
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Group {
            Text(title).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
            SquareCheck(isOn: isOn)
        }
    }

    private func voiceRow(_ notes: String) -> some View {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your voice").font(.system(size: 14))
                Text(text.isEmpty ? "Not written yet. Your agent can write it, or you can." : text)
                    .font(.system(size: 12.5)).foregroundStyle(text.isEmpty ? Theme.tertiary : Color(hex: 0xC9CACD)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") { state.sheet = .voice }.buttonStyle(DarkButtonStyle())
        }
    }

    private func keyTile(_ title: String, _ note: String, _ kind: CaptureKind, _ shortcut: Shortcut?) -> some View {
        KeyTile(title: title, note: note, cap: recording == kind ? "Press keys…" : shortcut?.title ?? "Off", isSet: shortcut != nil || recording == kind,
                record: { record(kind) }, turnOff: shortcut == nil ? nil : { preferences.change { _ = $0.setAgentKey(kind, nil) } })
    }

    private func record(_ kind: CaptureKind) {
        let again = recording == kind
        stopRecording()
        problem = nil
        guard !again else { return }
        recording = kind
        services.shortcuts.start { outcome in
            recording = nil
            switch outcome {
            case .cancelled: break
            case .rejected(let message): problem = message
            case .recorded(let shortcut): preferences.change { problem = $0.setAgentKey(kind, shortcut) }
            }
        }
    }

    private func stopRecording() {
        guard recording != nil else { return }
        services.shortcuts.stop()
        recording = nil
    }
}

/// A key and what it does. Clicking records a new key; the x, shown on hover, turns it off.
private struct KeyTile: View {
    let title: String
    let note: String
    let cap: String
    let isSet: Bool
    let record: () -> Void
    let turnOff: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button(action: record) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Kbd(title: cap, blue: isSet)
                    Spacer()
                    if let turnOff, hovering { IconButton(symbol: "xmark", help: "Turn off", action: turnOff).foregroundStyle(Theme.secondary) }
                }
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.top, 10)
                Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(2).padding(.top, 2)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.raised : Theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSet ? "Click to record a new key." : "Click to set a key.")
    }
}

/// The default agent: who it is, whether it answers, and where it runs.
private struct AgentTile: View {
    let agent: AgentConnection
    let services: WindowServices
    let change: () -> Void

    var body: some View {
        let state = services.agents.state(of: agent)
        HStack(spacing: 12) {
            AgentAvatar(initial: agent.initial, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 15, weight: .semibold))
                AgentStatusLine(agent: agent, state: state)
            }
            Spacer(minLength: 8)
            if case .unreachable = state {
                Button("Try again") { services.agents.test(agent) }.buttonStyle(DarkButtonStyle())
            }
            Button("Change", action: change).buttonStyle(DarkButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
    }
}

/// "Ready · on mini", "Checking…", "Can't reach" with the reason, or "Not installed".
struct AgentStatusLine: View {
    let agent: AgentConnection
    let state: AgentServices.State
    var showsPlace = true

    var body: some View {
        let place = agent.hostName.map { "on \($0)" } ?? "on this Mac"
        switch state {
        case .ready: StatusLine(color: Theme.green, text: showsPlace ? "Ready · \(place)" : "Ready")
        case .checking: StatusLine(color: Theme.tertiary, text: showsPlace ? "Checking… · \(place)" : "Checking…")
        case .unchecked: StatusLine(color: Theme.tertiary, text: showsPlace ? "Not checked yet · \(place)" : "Not checked yet")
        case .notInstalled: StatusLine(color: Theme.amber, text: "Not installed on this Mac")
        case .unreachable(let reason):
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(color: Theme.amber, text: showsPlace ? "Can't reach · \(place)" : "Can't reach")
                Text(reason).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(2).padding(.leading, 13)
                if let hint = agent.hint(forTrouble: reason) {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2).padding(.leading, 13)
                }
            }
        }
    }
}

/// With no agent set up, the one thing to do.
private struct EmptyTile: View {
    let setUp: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.stars").font(.system(size: 17)).frame(width: 36, height: 36)
                .background(Circle().fill(Theme.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Ghostwrite").font(.system(size: 15, weight: .semibold))
                Text("Pick the agent you already use. Then hold ⌃ fn and say what you want written.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Button("Set up", action: setUp).buttonStyle(DarkButtonStyle(kind: .prominent))
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
    }
}
