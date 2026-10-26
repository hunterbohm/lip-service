import AVFoundation
import DictationCore
import SwiftUI

struct HomePage: View {
    let services: WindowServices
    @Bindable var state: WindowState

    var body: some View {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        let entries = services.history.entries
        let shown = (query.isEmpty ? entries : entries.filter {
            $0.text.localizedStandardContains(query) || ($0.app?.name.localizedStandardContains(query) ?? false)
        }).sorted { $0.date > $1.date }
        let now = Date.now
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isEmpty {
                    SetupNotices(setup: services.setup)
                    if services.willow.showsCard { WillowNotice(willow: services.willow).padding(.bottom, 12) }
                    Hero(stats: HistoryStats(entries, now: now, calendar: .current)).padding(.top, 6).padding(.bottom, 30)
                }
                HStack {
                    Text("Recent").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    SearchBox(prompt: "Search \(Self.count(entries.count))", text: $state.search)
                }
                .padding(.bottom, 4)
                if entries.isEmpty {
                    Empty(message: "Hold \(HotkeyChoice.phrase(services.preferences.current.settings.hotkeys)) and start talking.")
                } else if shown.isEmpty {
                    Empty(message: "No dictations match \u{201C}\(query)\u{201D}.")
                } else {
                    ForEach(shown) { entry in
                        HistoryRow(entry: entry, when: HistoryEntry.when(entry.date, now: now, calendar: .current), query: query,
                                   copy: services.copy) { services.history.delete(entry.id) }
                    }
                }
            }
            .page()
        }
    }

    static func count(_ dictations: Int) -> String {
        dictations == 1 ? "1 dictation" : "\(dictations.formatted()) dictations"
    }
}

/// The big number reads like the speed on the Tesla screen. The rest stay quieter beside it.
private struct Hero: View {
    let stats: HistoryStats

    var body: some View {
        HStack(alignment: .bottom, spacing: 46) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stats.wordsThisWeek.formatted()).font(.system(size: 76, weight: .light)).monospacedDigit()
                Text("Words this week").font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .bottom, spacing: 40) {
                Stat(value: stats.totalWords.formatted(), label: "Words in all")
                Stat(value: stats.wordsPerMinute.map { $0.formatted() } ?? "–", label: "Words a minute")
                Stat(value: stats.streakDays == 1 ? "1 day" : "\(stats.streakDays) days", label: "Streak")
            }
            .padding(.bottom, 1)
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26)).monospacedDigit()
            Text(label).font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct SetupNotices: View {
    let setup: SetupStatus

    var body: some View {
        let checks = setup.checks
        VStack(alignment: .leading, spacing: 10) {
            if !checks.microphone {
                Notice(tone: .warning, title: "Allow the microphone", detail: "Lip Service listens only while you hold a dictation key.") {
                    Button("Allow") {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                            Microphone.requestAccessIfNeeded()
                        } else {
                            SystemSettingsPane.microphone.open()
                        }
                    }
                    .buttonStyle(DarkButtonStyle(kind: .prominent))
                }
            }
            if !checks.accessibility {
                Notice(tone: .warning, title: "Allow Accessibility",
                       detail: "Lets the keys work in every app and the text paste at the cursor.") {
                    Button("Open Settings") { SystemSettingsPane.accessibility.open() }.buttonStyle(DarkButtonStyle(kind: .prominent))
                }
            }
            if checks.fnKey == .needsSetting {
                Notice(tone: .warning, title: "Set \u{201C}Press fn key to\u{201D} to Do Nothing",
                       detail: "Until then fn also opens another action, so it can't start dictation.") {
                    Button("Open Keyboard") { SystemSettingsPane.keyboard.open() }.buttonStyle(DarkButtonStyle(kind: .prominent))
                }
            }
        }
        .padding(.bottom, checks.isComplete ? 0 : 12)
    }
}

private struct WillowNotice: View {
    let willow: WillowImporter

    var body: some View {
        Notice(tone: .info, title: "Import from Willow", detail: detail) {
            switch willow.phase {
            case .ready:
                Button("Not Now") { willow.dismissCard() }.buttonStyle(DarkButtonStyle())
                Button("Import") { willow.run() }.buttonStyle(DarkButtonStyle(kind: .prominent))
            case .importing:
                ProgressView().controlSize(.small)
            case .finished:
                Button("Done") { willow.dismissCard() }.buttonStyle(DarkButtonStyle())
            }
        }
    }

    private var detail: String {
        switch willow.phase {
        case .ready: "Bring over your dictations and settings. Audio stays with Willow."
        case .importing: "Importing…"
        case .finished(let message): message
        }
    }
}

private struct Empty: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let when: String
    let query: String
    let copy: (String) -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(highlighted)
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.app.map { "\($0.name), \(when)" } ?? when)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    copy(entry.text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                IconButton(symbol: "trash", help: "Delete", action: delete)
            }
            .foregroundStyle(Theme.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(entry.text)
        var rest = attributed.startIndex..<attributed.endIndex
        while !query.isEmpty, let match = attributed[rest].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[match].backgroundColor = Theme.blue.opacity(0.45)
            rest = match.upperBound..<attributed.endIndex
        }
        return attributed
    }
}
