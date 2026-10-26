import DictationCore
import SwiftUI

/// The look, after Tesla's dark center screen: one dark canvas, flat tiles, blue only for what is on, and a gray
/// fill for the chosen one of several.
enum Theme {
    static let canvas = Color(hex: 0x17181A)
    static let tile = Color(hex: 0x232529)
    static let raised = Color(hex: 0x2B2D32)
    static let line = Color(hex: 0x33353A)
    static let dock = Color(hex: 0x0B0B0C)
    static let toast = Color(hex: 0x2A2C30)
    static let text = Color(hex: 0xF4F4F5)
    static let secondary = Color(hex: 0xA2A4A9)
    static let tertiary = Color(hex: 0x6F7277)
    static let blue = Color(hex: 0x3E6AE1)
    static let chosen = Color(hex: 0x5C5E62)
    static let green = Color(hex: 0x30C46C)
    static let amber = Color(hex: 0xE9A23B)
    static let red = Color(hex: 0xE5484D)
    static let radius: CGFloat = 10

    static func color(_ tone: NoticeTone) -> Color {
        switch tone {
        case .info: green
        case .warning: amber
        case .failure: red
        }
    }

    static func symbol(_ tone: NoticeTone) -> String {
        switch tone {
        case .info: "info.circle"
        case .warning: "exclamationmark.circle"
        case .failure: "xmark.circle"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A joined row of tiles. A toggle turns blue while on. Of choices, the chosen one turns gray.
struct TileGroup: View {
    enum Kind { case toggles, choice }

    struct Item: Identifiable {
        var id: String { title }
        let title: String
        var symbol: String?
        var help: String?
        let isOn: Bool
        let action: () -> Void
    }

    let kind: Kind
    let items: [Item]
    var width: CGFloat = 132

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Theme.line.frame(width: 1) }
                Tile(item: item, on: kind == .toggles ? Theme.blue : Theme.chosen, width: width)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct Tile: View {
    let item: TileGroup.Item
    let on: Color
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            VStack(spacing: 7) {
                if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 19)) }
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(item.isOn ? Color.white : Theme.text.opacity(0.92))
            .frame(width: width, height: item.symbol == nil ? 44 : 78)
            .background(item.isOn ? on : hovering ? Theme.raised : Theme.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.help ?? "")
        .onHover { hovering = $0 }
    }
}

/// A rounded bar with a colored icon, a title and a reason, like a message on the Tesla screen.
struct Notice<Actions: View>: View {
    let tone: NoticeTone
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: Theme.symbol(tone)).font(.system(size: 25)).foregroundStyle(Theme.color(tone))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                if let detail { Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.text.opacity(0.75)) }
            }
            Spacer(minLength: 16)
            actions
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.toast))
    }
}

extension Notice where Actions == EmptyView {
    init(tone: NoticeTone, title: String, detail: String? = nil) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

/// Tesla's checkbox: a square that fills blue with a check.
struct CheckRow: View {
    let title: String
    var help: String?
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Theme.blue : .clear)
                    .strokeBorder(isOn ? Theme.blue : Theme.text.opacity(0.45), lineWidth: 1.5)
                    .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 24, height: 24)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .medium))
                        if let help {
                            Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(Theme.tertiary).help(help)
                        }
                    }
                    if let note { Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.amber) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DarkButtonStyle: ButtonStyle {
    enum Kind { case plain, prominent, destructive }
    var kind = Kind.plain

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Styled(configuration: configuration, kind: kind)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(kind == .destructive ? Theme.red : .white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                // A see-through fill, so a plain button shows on the canvas and on a notice alike.
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(kind == .prominent ? Theme.blue : Color.white.opacity(0.09)))
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
        }
    }
}

struct SearchBox: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 12)
        .frame(width: 270, height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tile))
    }
}

struct PageTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.system(size: 22, weight: .semibold)).padding(.bottom, 22)
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.secondary) }
        }
        .padding(.bottom, 12)
    }
}

extension View {
    /// The content column every page shares, under the window's title bar.
    func page() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.trailing, 40)
            .padding(.top, 16)
            .padding(.bottom, 28)
    }
}
