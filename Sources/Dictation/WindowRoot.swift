import AppKit
import DictationCore
import SwiftUI

struct WindowRoot: View {
    let services: WindowServices
    @Bindable var state: WindowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Nav(page: $state.page)
                Group {
                    switch state.page {
                    case .home: HomePage(services: services, state: state)
                    case .dictation: DictationPage(services: services)
                    case .microphone: MicrophonePage(services: services)
                    case .dictionary: DictionaryPage(preferences: services.preferences)
                    case .history: HistoryPage(services: services)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // A page's scroll view that reaches the top edge, under the transparent title bar, comes out empty
                // in --render-window's offscreen snapshot. One point down, it draws.
                .padding(.top, 1)
            }
            Dock(services: services)
        }
        .frame(minWidth: 880, minHeight: 560)
        .foregroundStyle(Theme.text)
        .tint(Theme.blue)
        .background(Theme.canvas, ignoresSafeAreaEdges: .all)
        .task {
            // Permissions and microphones change outside the app, and neither posts a notice worth wiring up.
            while !Task.isCancelled {
                services.setup.refresh()
                services.inputs.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct Nav: View {
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { item in
                NavRow(page: item, selected: page == item) { page = item }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 30)
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct NavRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol).font(.system(size: 17)).frame(width: 22)
                Text(page.title).font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Theme.text.opacity(0.88))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.raised : hovering ? Theme.tile : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The strip along the bottom, like the Tesla screen's: what is listening, how to talk, and the last dictation.
private struct Dock: View {
    let services: WindowServices
    @State private var copied = false

    var body: some View {
        let settings = services.preferences.current.settings
        let source = services.inputs.inUse(settings.microphone)
        let last = services.history.entries.max { $0.date < $1.date }
        ZStack {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "mic").font(.system(size: 14))
                    Text(source.name)
                    Circle().fill(source.missing == nil ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                }
                .foregroundStyle(Theme.text.opacity(0.85))
                .help(source.missing.map { "\($0) isn't connected, so dictation uses \(source.name)." } ?? "Dictation uses \(source.name).")
                Spacer()
                Button {
                    guard let last else { return }
                    services.copy(last.text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy last", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(DarkButtonStyle())
                .disabled(last == nil)
                .help("Copies your last dictation. ⌃⌘V pastes it anywhere.")
            }
            Text("Hold \(Text(HotkeyChoice.phrase(settings.hotkeys)).foregroundStyle(.white).fontWeight(.medium)) to talk")
                .foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 22)
        .frame(height: 58)
        .background(Theme.dock)
        .overlay(alignment: .top) { Color.white.opacity(0.06).frame(height: 1) }
    }
}

extension Preferences {
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<DictationCore.Settings, Value>) -> Binding<Value> {
        Binding(get: { self.current.settings[keyPath: keyPath] },
                set: { value in self.change { $0[keyPath: keyPath] = value } })
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
