import AppKit
import DictationCore
import SwiftUI

/// The parts the Ghostwrite page, the Profiles page and the first run share.

extension SetupPrompt {
    /// The prompt for this running app, with the path of its own binary.
    @MainActor static var forThisApp: String {
        text(executable: Bundle.main.executablePath ?? "/Applications/Lip Service.app/Contents/MacOS/Dictation")
    }
}

/// A page title with the one line under it that says what the page is for.
struct PageHeader: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(lead).font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
        }
        .padding(.bottom, 18)
    }
}

/// A key as a small cap: blue while it is the key, gray for a plain mention.
struct Kbd: View {
    let title: String
    var blue = true

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(blue ? Theme.blue : Theme.raised))
    }
}

/// Tesla's checkbox, on the right of a list row.
struct SquareCheck: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? Theme.blue : .clear)
                .strokeBorder(isOn ? Theme.blue : Theme.text.opacity(0.45), lineWidth: 1.5)
                .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Rows in one rounded tile, a thin line between them.
struct RowList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.tile)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ListRow<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { if divider { Theme.line.frame(height: 1) } }
    }
}

/// A row of choices joined into one control; the chosen one has the gray fill.
struct Segmented<Value: Hashable>: View {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var font: CGFloat = 12.5
    var horizontal: CGFloat = 12
    var vertical: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Theme.line.frame(width: 1) }
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: font, weight: selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Color.white : Theme.text.opacity(0.85))
                        .lineLimit(1)
                        .padding(.horizontal, horizontal).padding(.vertical, vertical)
                        .background(selection == option.value ? Theme.chosen : Theme.raised)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A colored dot and a line of words, for whether an agent answers.
struct StatusLine: View {
    let color: Color
    let text: String
    var lines = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(lines)
        }
    }
}

/// A card laid over the window with a dimmed backdrop, as the mockup draws it. Clicking outside, or Escape, closes it.
struct SheetOverlay<Content: View>: View {
    var width: CGFloat = 480
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture(perform: close)
            content
                .padding(.horizontal, 20).padding(.vertical, 18)
                .frame(width: width)
                .background(Color(hex: 0x1E1F22))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: 0x303136)))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                .padding(24)
        }
        .onExitCommand(perform: close)
    }
}

struct SheetTitle: View {
    let title: String
    let done: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Done", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// The prompt as a user's agent will read it.
struct PromptBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(3)
            .foregroundStyle(Color(hex: 0xD6D7DA))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x101113)))
    }
}

/// What a user's own agent changed: a check, who did it, and each change in plain words.
struct AppliedNotice: View {
    let record: SetupRecord
    var limit = 6
    var showsTitle = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 4) {
                if showsTitle { Text(record.title).font(.system(size: 14.5, weight: .semibold)) }
                ForEach(Array(record.changes.prefix(limit).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.tertiary)
                        Text(line).font(.system(size: 13.5)).foregroundStyle(Color(hex: 0xD6D7DA)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if record.changes.count > limit {
                    Text("and \(record.changes.count - limit) more").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.tile))
    }
}

/// A text link in the page's quiet blue.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).foregroundStyle(Color(hex: 0x8EA9F2)) }.buttonStyle(.plain)
    }
}

/// The letter on an agent's round mark in a list. Codex gets X, so it isn't taken for Claude Code.
func listInitial(preset: String, name: String) -> String {
    preset == "codex" ? "X" : String(name.prefix(1)).uppercased()
}

extension AgentConnection {
    /// "On this Mac" or "On mini".
    var placeName: String { hostName.map { "On \($0)" } ?? "On this Mac" }
}

/// Which apps count as installed for Profiles. The window render swaps it for a fixed set.
@MainActor enum AppInstalled {
    static var override: ((String) -> Bool)?

    static func check(_ bundleID: String) -> Bool {
        if let override { return override(bundleID) }
        let id = bundleID.hasSuffix("*") ? String(bundleID.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "."))) : bundleID
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
}

/// The time from letting go of the key to the text, for the first run's Try it step. Set after the text is in, so
/// nothing is added to the key path.
@MainActor @Observable final class DictationTiming {
    private(set) var seconds: Double?
    private(set) var serial = 0

    func record(_ seconds: Double) {
        self.seconds = seconds
        serial += 1
    }
}
