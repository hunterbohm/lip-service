import DictationCore
import SwiftUI

struct DictationPage: View {
    let services: WindowServices

    private var preferences: Preferences { services.preferences }

    var body: some View {
        let settings = preferences.current.settings
        let loginItem = services.loginItem
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Dictation")
                SectionHeader(title: "Dictation keys",
                              detail: "Hold one to talk. Tap it twice for hands-free. ⌃⌘V pastes your last dictation again.")
                TileGroup(kind: .toggles, items: HotkeyChoice.allCases.map { key in
                    let on = settings.hotkeys.contains(key)
                    return .init(title: key.title, symbol: "keyboard", help: on && settings.hotkeys == [key] ? "One key always stays on." : nil,
                                 isOn: on) { preferences.change { $0.setHotkey(key, on: !on) } }
                })
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
                ])
                .padding(.bottom, 30)
                HStack(alignment: .top, spacing: 48) {
                    CheckRow(title: "Launch at login", help: "Opens Lip Service when you log in to your Mac.", note: loginItem.note,
                             isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    CheckRow(title: "Show menu bar icon",
                             help: "Without it, open this window from Spotlight or Raycast.",
                             isOn: preferences.binding(\.showMenuBarIcon))
                }
            }
            .page()
        }
    }

    private func toggle(_ title: String, _ symbol: String, _ keyPath: WritableKeyPath<DictationCore.Settings, Bool>,
                        help: String) -> TileGroup.Item {
        let on = preferences.current.settings[keyPath: keyPath]
        return .init(title: title, symbol: symbol, help: help, isOn: on) { preferences.change { $0[keyPath: keyPath] = !on } }
    }
}
