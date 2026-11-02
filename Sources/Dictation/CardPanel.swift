import AppKit
import DictationCore
import SwiftUI

/// What the agent card shows. Built by the Ghostwriter from its card state; the view only draws it.
struct CardModel: Equatable {
    enum Content: Equatable {
        case draft(DraftCard)
        case handOff(HandOffCard)
    }

    var agent: BarAgent
    var heading: String
    var content: Content
    /// The key that speaks a change, as the footer names it.
    var changeKey: String
    /// False once the user switched apps: the keys go back to them and the card works by click.
    var keysLive: Bool
    /// False when the user started outside a text box, so Return copies and the button says so.
    var returnTypes = true
}

enum CardAction: Equatable {
    case key(CardKey)
    case copy
    case retry
    case pick(HandOffCard.Project)
}

/// The card above the bar, in its own panel that never takes focus, so typing stays in the user's app.
@MainActor final class CardPanel {
    var onAction: ((CardAction) -> Void)?
    private let panel = CardWindow()
    private let host = CardHost(rootView: AnyView(EmptyView()))

    init() {
        panel.contentView = host
        host.sizingOptions = [.intrinsicContentSize]
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ model: CardModel, above anchor: (frame: NSRect, edge: BarEdge)) {
        host.rootView = AnyView(CardView(model: model, onAction: { [weak self] in self?.onAction?($0) }))
        let size = host.fittingSize
        var frame = anchor.edge.placeToast(width: size.width, height: size.height, against: BarRect(anchor.frame), gap: 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor.frame) }) ?? NSScreen.main {
            frame = frame.moved(into: BarRect(screen.visibleFrame))
        }
        panel.setFrame(NSRect(frame), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        host.rootView = AnyView(EmptyView())
    }

    /// For --render-bar.
    var window: NSPanel { panel }
}

private final class CardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
    }
}

private final class CardHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CardView: View {
    let model: CardModel
    let onAction: (CardAction) -> Void

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AgentAvatar(initial: model.agent.initial, size: 18)
                Text(model.heading).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            content
        }
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 20 / 255, green: 21 / 255, blue: 24 / 255).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .draft(let card): draft(card)
        case .handOff(let card): handOff(card)
        }
    }

    @ViewBuilder private func draft(_ card: DraftCard) -> some View {
        switch card.phase {
        case .permission(let prompt, _):
            question(prompt.request)
        case .failed(let reason):
            failure(reason, words: card.words, retry: true)
        case .ready(let text):
            body(text)
            footer([.init("⏎", model.returnTypes ? "Type it" : "Copy it", main: true, action: .key(.returnKey)), .init("hold \(model.changeKey)", "Change it", action: nil)],
                   trailing: .init("esc", "Discard", action: .key(.escape)))
        case .listening, .transcribing, .thinking:
            body(card.text ?? "", dimmed: true)
            footer([], trailing: .init("esc", "Discard", action: .key(.escape)))
        case .streaming(let text):
            body(text)
            footer([], trailing: .init("esc", "Discard", action: .key(.escape)))
        case .typed, .copied, .discarded:
            EmptyView()
        }
    }

    @ViewBuilder private func handOff(_ card: HandOffCard) -> some View {
        switch card.phase {
        case .confirming(let until):
            body(card.words)
            Countdown(until: until, destination: card.destination).padding(.horizontal, 16).padding(.top, 2)
            footer([.init("⏎", "Send now", main: true, action: .key(.returnKey))], trailing: .init("esc", "Cancel", action: .key(.escape)))
        case .loadingProjects:
            body(card.words)
            note("Loading your T3 Code projects…")
            footer([], trailing: .init("esc", "Cancel", action: .key(.escape)))
        case .picking(_, let query, let selected):
            body(card.words)
            ProjectPicker(projects: card.visibleProjects, query: query, selected: selected, onPick: { onAction(.pick($0)) })
                .padding(.horizontal, 10)
            footer([.init("↑↓", "Pick", action: nil), .init("⏎", "Start thread", main: true, action: .key(.returnKey))],
                   trailing: .init("esc", "Cancel", action: .key(.escape)))
        case .sending:
            body(card.words, dimmed: true)
            note("Sending to \(card.destination)…")
        case .replying(let text):
            body(text)
        case .replied(let text, let note):
            body(text)
            self.note(note)
            footer([.init("", "Copy", main: true, action: .copy)], trailing: .init("esc", "Close", action: .key(.escape)))
        case .sent(let note):
            body(card.words, dimmed: true)
            self.note(note)
        case .cancelled:
            EmptyView()
        case .failed(let reason):
            failure(reason, words: card.words, retry: false)
        }
    }

    private func body(_ text: String, dimmed: Bool = false) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Theme.text.opacity(dimmed ? 0.55 : 1))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .textSelection(.enabled)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }

    private func question(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title).font(.system(size: 14)).padding(.bottom, 4)
            ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                Button { onAction(.key(.number(index + 1))) } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                        Text(option.name).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(option.kind.hasPrefix("allow") ? Theme.tile : Color.white.opacity(0.03)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func failure(_ reason: String, words: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Theme.symbol(.failure)).font(.system(size: 17)).foregroundStyle(Theme.color(.failure))
                Text(reason).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.top, 10)
            if !words.isEmpty {
                Text("You said: \(words)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.top, 6)
            }
            footer(retry ? [.init("⏎", "Retry", main: true, action: .retry), .init("", "Copy words", action: .copy)]
                         : [.init("", "Copy words", main: true, action: .copy)],
                   trailing: .init("esc", "Close", action: .key(.escape)))
        }
    }

    private func footer(_ keys: [FooterKey], trailing: FooterKey) -> some View {
        HStack(spacing: 6) {
            ForEach(keys) { key in FooterButton(key: key, live: model.keysLive, onAction: onAction) }
            Spacer(minLength: 0)
            FooterButton(key: trailing, live: model.keysLive, onAction: onAction)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

private struct FooterKey: Identifiable {
    let key: String
    let title: String
    var main = false
    let action: CardAction?
    var id: String { title }

    init(_ key: String, _ title: String, main: Bool = false, action: CardAction?) {
        (self.key, self.title, self.main, self.action) = (key, title, main, action)
    }
}

private struct FooterButton: View {
    let key: FooterKey
    let live: Bool
    let onAction: (CardAction) -> Void

    var body: some View {
        let label = HStack(spacing: 6) {
            if live, !key.key.isEmpty {
                Text(key.key).font(.system(size: 11)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
            Text(key.title).font(.system(size: 12.5))
        }
        .foregroundStyle(key.main ? Color.white : Color(red: 0xD6 / 255, green: 0xD7 / 255, blue: 0xDA / 255))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(key.main ? Theme.blue : Color.clear))
        .contentShape(Rectangle())
        if let action = key.action {
            Button { onAction(action) } label: { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// The time left before a hand-off goes, as a bar that empties.
private struct Countdown: View {
    let until: Instant
    let destination: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let left = max(0, until - .now)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sending to \(destination) in \(Int(left.rounded(.up))) s").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.blue).frame(width: proxy.size.width * left / HandOffCard.countdown)
                        }
                }
                .frame(height: 3)
            }
        }
    }
}

/// Projects to start a thread in, filtered by what was typed, grouped by machine when there is more than one.
private struct ProjectPicker: View {
    let projects: [HandOffCard.Project]
    let query: String
    let selected: Int
    let onPick: (HandOffCard.Project) -> Void

    var body: some View {
        let machines = Set(projects.compactMap(\.environmentName))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text(query.isEmpty ? "Type to filter" : query).font(.system(size: 12.5))
            }
            .foregroundStyle(query.isEmpty ? Theme.tertiary : Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            let window = Self.window(count: projects.count, selected: selected)
            ForEach(Array(projects.enumerated())[window], id: \.element.id) { index, project in
                Button { onPick(project) } label: {
                    HStack {
                        Text(project.name).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        if machines.count > 1, let machine = project.environmentName {
                            Text(machine).font(.system(size: 11.5)).foregroundStyle(index == selected ? Color.white.opacity(0.75) : Theme.tertiary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(index == selected ? Theme.blue : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if projects.isEmpty {
                Text("No project matches.").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).padding(8)
            }
        }
    }

    /// Seven rows at most, scrolled so the selection shows.
    static func window(count: Int, selected: Int) -> Range<Int> {
        let rows = 7
        let start = min(max(0, selected - rows / 2), max(0, count - rows))
        return start..<min(count, start + rows)
    }
}
