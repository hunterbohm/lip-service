import DictationCore
import SwiftUI

struct DictationPage: View {
    let services: WindowServices
    @State private var recording: Slot?
    @State private var problem: String?

    /// What a recording will set: a dictation key, new or in place of one, or the paste shortcut.
    private enum Slot: Equatable {
        case dictation(replacing: Shortcut?)
        case pasteLast
    }

    private static let maxHotkeys = 4

    private var preferences: Preferences { services.preferences }

    var body: some View {
        let settings = preferences.current.settings
        let loginItem = services.loginItem
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Dictation")
                SectionHeader(title: "Dictation keys",
                              detail: "Hold one to talk. Tap it twice for hands-free. Click a key to change it.")
                VStack(alignment: .leading, spacing: 0) {
                    KeyRow(items: dictationKeys(settings))
                    note
                }
                .padding(.bottom, 30)
                SectionHeader(title: "Paste last dictation", detail: "Pastes your last dictation again, wherever you are typing.")
                KeyRow(items: [pasteKey(settings)])
                    .padding(.bottom, 30)
                SectionHeader(title: "Bar position", detail: "Where the bar sits while you talk. You can also drag it.")
                TileGroup(kind: .choice, items: BarEdge.allCases.map { edge in
                    .init(title: edge.rawValue.capitalized, isOn: settings.barEdge == edge) { preferences.change { $0.barEdge = edge } }
                }, width: 104)
                .padding(.bottom, 30)
                TileGroup(kind: .toggles, items: [
                    toggle("Sounds", "speaker.wave.2", \.sounds, help: "A short sound when dictation starts, ends and is cancelled."),
                    toggle("Smart spacing", "space", \.smartSpacing,
                           help: "Adds a space after the word before the cursor and keeps a sentence you continue lowercase."),
                    toggle("Vocabulary boost", "sparkles", \.vocabularyEnabled, help: "Spells the words in your Dictionary your way."),
                    toggle("Hide bar when idle", "rectangle.dashed", \.hideBarWhenIdle, help: "Shows the bar only while you talk."),
                    toggle("Mute other audio", "speaker.slash", \.muteWhileDictating,
                           help: "Mutes your Mac's sound while you talk and turns it back on when you stop."),
                ])
                .padding(.bottom, 30)
                HStack(alignment: .top, spacing: 48) {
                    CheckRow(title: "Launch at login", help: "Opens Lip Service when you log in to your Mac.", note: loginItem.note,
                             isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    CheckRow(title: "Show menu bar icon",
                             help: "Without it, open this window from Spotlight or Raycast.",
                             isOn: preferences.binding(\.showMenuBarIcon))
                }
                .padding(.bottom, 24)
                VStack(alignment: .leading, spacing: 20) {
                    explained("Send an anonymous daily usage count", isOn: preferences.binding(\.sendUsageCount),
                              "Once a day, when you first use Lip Service, it sends a hashed random ID, the app and macOS versions, the date, and whether you used dictation, Ghostwrite or Hand off. Never your voice, your words, your apps or your agent.")
                    explained("Check for updates", isOn: preferences.binding(\.checkForUpdates),
                              "Once a day, asks GitHub which version is newest and tells you here and in the menu bar when yours is older. It sends nothing about you or your Mac, and it installs nothing.")
                }
            }
            .page()
        }
        .onDisappear(perform: stop)
    }

    private func explained(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CheckRow(title: title, isOn: isOn)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 36)
                .frame(maxWidth: 680, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var note: some View {
        if recording != nil {
            Text("Press a key or a combination, or a modifier key on its own and let go. Escape cancels.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 10)
        } else if let problem {
            Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber).padding(.top, 10)
        }
    }

    private func dictationKeys(_ settings: DictationCore.Settings) -> [KeyItem] {
        var items = settings.hotkeys.map { shortcut in
            KeyItem(id: "key-\(shortcut.key)-\(shortcut.modifiers.rawValue)", title: shortcut.title, symbol: "keyboard",
                    look: recording == .dictation(replacing: shortcut) ? .recording : .on,
                    remove: settings.hotkeys.count > 1 ? { preferences.change { $0.removeHotkey(shortcut) } } : nil) {
                start(.dictation(replacing: shortcut))
            }
        }
        if settings.hotkeys.count < Self.maxHotkeys {
            items.append(KeyItem(id: "add", title: "Add Key", symbol: "plus",
                                 look: recording == .dictation(replacing: nil) ? .recording : .off, remove: nil) {
                start(.dictation(replacing: nil))
            })
        }
        return items
    }

    private func pasteKey(_ settings: DictationCore.Settings) -> KeyItem {
        KeyItem(id: "paste", title: settings.pasteLast?.title ?? "Off", symbol: "doc.on.clipboard",
                look: recording == .pasteLast ? .recording : settings.pasteLast == nil ? .off : .on,
                remove: settings.pasteLast == nil ? nil : { preferences.change { _ = $0.setPasteLast(nil) } }) {
            start(.pasteLast)
        }
    }

    /// Clicking the tile that is recording cancels it.
    private func start(_ slot: Slot) {
        let again = recording == slot
        stop()
        problem = nil
        guard !again else { return }
        recording = slot
        services.shortcuts.start { outcome in
            recording = nil
            switch outcome {
            case .cancelled:
                break
            case .rejected(let message):
                problem = message
            case .recorded(let shortcut):
                preferences.change { settings in
                    problem = switch slot {
                    case .dictation(let old): settings.setHotkey(shortcut, replacing: old)
                    case .pasteLast: settings.setPasteLast(shortcut)
                    }
                }
            }
        }
    }

    private func stop() {
        guard recording != nil else { return }
        services.shortcuts.stop()
        recording = nil
    }

    private func toggle(_ title: String, _ symbol: String, _ keyPath: WritableKeyPath<DictationCore.Settings, Bool>,
                        help: String) -> TileGroup.Item {
        let on = preferences.current.settings[keyPath: keyPath]
        return .init(title: title, symbol: symbol, help: help, isOn: on) { preferences.change { $0[keyPath: keyPath] = !on } }
    }
}

private struct KeyItem: Identifiable {
    enum Look { case on, off, recording }

    let id: String
    let title: String
    let symbol: String
    let look: Look
    let remove: (() -> Void)?
    let action: () -> Void
}

/// Key tiles joined in one row, like the other tile groups: blue for a key in use, outlined while recording.
private struct KeyRow: View {
    let items: [KeyItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Theme.line.frame(width: 1) }
                KeyTile(item: item)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct KeyTile: View {
    let item: KeyItem
    @State private var hovering = false

    var body: some View {
        let recording = item.look == .recording
        Button(action: item.action) {
            VStack(spacing: 7) {
                Image(systemName: recording ? "record.circle" : item.symbol).font(.system(size: 19))
                Text(recording ? "Press keys…" : item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(item.look == .off ? Theme.text.opacity(0.92) : .white)
            .frame(width: 132, height: 78)
            .background(item.look == .on ? Theme.blue : recording || hovering ? Theme.raised : Theme.tile)
            .overlay { if recording { Rectangle().strokeBorder(Theme.blue, lineWidth: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Click again to cancel." : item.look == .on ? "Click to change." : "")
        .overlay(alignment: .topTrailing) {
            if let remove = item.remove, hovering, !recording {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
                    .help("Remove")
            }
        }
        .onHover { hovering = $0 }
    }
}
