import AppKit
import DictationCore
import SwiftUI
import WebKit

/// What the agent put on screen during a talk, in a stack of cards under the bar, newest on top. A card stays until you
/// close it, the agent says it is done with it, two minutes pass, or the talk ends. The panel never takes focus. With no card, the panel and its
/// views are gone.
@MainActor final class TalkCardPanel {
    struct Card: Identifiable {
        enum Content {
            case show(ShowCard)
            case permission(agent: String, phrase: String, detail: String, byVoice: Bool)
        }

        let id = UUID()
        var content: Content
        var agent: BarAgent
        var added = Instant.now
    }

    static let lifetime = 120.0
    static let most = 3
    var onPermission: ((Bool) -> Void)?
    private let panel = TalkCardWindow()
    private let host = TalkCardHost(rootView: AnyView(EmptyView()))
    private(set) var cards: [Card] = []
    private var anchor: (frame: NSRect, edge: BarEdge)?
    private var expiry: Timer?
    /// Measured heights of the HTML visuals, which load after the card is laid out.
    private var heights: [UUID: CGFloat] = [:]

    init() {
        panel.contentView = host
        host.sizingOptions = [.intrinsicContentSize]
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSPanel { panel }

    /// Moves the cards under a new place, such as the island once it opens or closes.
    func move(under anchor: (frame: NSRect, edge: BarEdge)) {
        guard self.anchor.map({ $0.frame != anchor.frame || $0.edge != anchor.edge }) ?? true else { return }
        self.anchor = anchor
        layout()
    }

    func handle(_ event: TalkCardEvent, agent: BarAgent, under anchor: (frame: NSRect, edge: BarEdge)) {
        self.anchor = anchor
        switch event {
        case .show(let card): add(Card(content: .show(card), agent: agent))
        case .permission(let name, let phrase, let detail, let byVoice):
            add(Card(content: .permission(agent: name, phrase: phrase, detail: detail, byVoice: byVoice), agent: agent))
        case .permissionAnswered:
            cards.removeAll { if case .permission = $0.content { true } else { false } }
            layout()
        case .clear:
            // The agent is done with what it showed. A question it is waiting on stays.
            cards.removeAll { if case .permission = $0.content { false } else { true } }
            heights = heights.filter { id, _ in cards.contains { $0.id == id } }
            layout()
        case .result, .callBackPromised:
            // The island draws these itself.
            break
        }
    }

    /// Closes every permission card, for a talk that ended with a question open.
    func dropPermissions() { handle(.permissionAnswered, agent: BarAgent(initial: "", name: ""), under: anchor ?? (.zero, .top)) }

    private func add(_ card: Card) {
        cards.insert(card, at: 0)
        if cards.count > Self.most { cards.removeLast(cards.count - Self.most) }
        layout()
    }

    private func close(_ id: UUID) {
        cards.removeAll { $0.id == id }
        heights[id] = nil
        layout()
    }

    func closeAll() {
        cards = []
        heights = [:]
        layout()
    }

    private func layout() {
        expiry?.invalidate()
        expiry = nil
        guard !cards.isEmpty, let anchor else {
            panel.orderOut(nil)
            host.rootView = AnyView(EmptyView())
            return
        }
        host.rootView = AnyView(TalkCardStack(cards: cards, heights: heights, onClose: { [weak self] in self?.close($0) },
                                              onAnswer: { [weak self] in self?.onPermission?($0) },
                                              onHeight: { [weak self] id, height in self?.measured(id, height) }))
        let size = host.fittingSize
        var frame = anchor.edge.placeToast(width: size.width, height: size.height, against: BarRect(anchor.frame), gap: 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor.frame) }) {
            frame = frame.moved(into: BarRect(screen.visibleFrame))
        }
        panel.setFrame(NSRect(frame), display: true)
        panel.orderFrontRegardless()
        let oldest = cards.map(\.added).min() ?? .now
        let timer = Timer(timeInterval: max(0.5, oldest + Self.lifetime - .now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func measured(_ id: UUID, _ height: CGFloat) {
        guard heights[id] != height, cards.contains(where: { $0.id == id }) else { return }
        heights[id] = height
        layout()
    }

    private func expire() {
        let now = Instant.now
        let kept = cards.filter { card in
            if case .permission = card.content { return true }
            return now - card.added < Self.lifetime
        }
        guard kept.count != cards.count else { return layout() }
        cards = kept
        layout()
    }

    /// The HTML visuals drawn as pictures, with where each sits in the panel, for --render-bar, which can't capture a web
    /// view by drawing the panel.
    func webSnapshots(_ done: @escaping ([(frame: NSRect, image: NSImage)]) -> Void) {
        let views = host.descendants(of: WKWebView.self)
        var shots: [(frame: NSRect, image: NSImage)] = []
        var left = views.count
        guard left > 0 else { return done([]) }
        for view in views {
            // In the panel's own coordinates, origin bottom left, as the panel's picture is drawn.
            var frame = view.convert(view.bounds, to: host)
            if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            view.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((frame, image)) }
                left -= 1
                if left == 0 { done(shots) }
            }
        }
    }
}

private final class TalkCardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.borderless, .nonactivatingPanel],
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

private final class TalkCardHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.descendants(of: type)
        }
    }
}

private struct TalkCardStack: View {
    let cards: [TalkCardPanel.Card]
    let heights: [UUID: CGFloat]
    let onClose: (UUID) -> Void
    let onAnswer: (Bool) -> Void
    let onHeight: (UUID, CGFloat) -> Void

    static let width: CGFloat = 460

    var body: some View {
        VStack(spacing: 8) {
            ForEach(cards) { card in
                TalkCardView(card: card, height: heights[card.id], onClose: { onClose(card.id) }, onAnswer: onAnswer,
                             onHeight: { onHeight(card.id, $0) })
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TalkCardView: View {
    let card: TalkCardPanel.Card
    let height: CGFloat?
    let onClose: () -> Void
    let onAnswer: (Bool) -> Void
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(heading).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                if case .show = card.content {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            content
        }
        .frame(width: TalkCardStack.width, alignment: .leading)
        // The island's look: black, round, with its faint light edge, so the cards read as part of it.
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.08), .white.opacity(0.14)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        .foregroundStyle(Theme.text)
    }

    private var heading: String {
        switch card.content {
        case .show(.link): "Link"
        case .show(.image): "Image"
        case .show(.text): "From \(card.agent.name)"
        case .show(.html): "Visual"
        case .permission: "\(card.agent.name) asks"
        }
    }

    @ViewBuilder private var content: some View {
        switch card.content {
        case .show(.link(let url)):
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "link").font(.system(size: 13)).foregroundStyle(Theme.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.host ?? url.absoluteString).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        Text(url.absoluteString).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text("Open").font(.system(size: 12.5)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 12)
        case .show(.image(let url)):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: Text("The image didn't load.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.vertical, 20)
                default: ProgressView().controlSize(.small).frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(12)
        case .show(.text(let text)):
            let code = text.contains("\n") && text.contains { "{}();=<>".contains($0) }
            ScrollView {
                Text(text)
                    .font(code ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
        case .show(.html(let html)):
            HTMLVisual(html: html, onHeight: onHeight)
                .frame(height: height ?? 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(10)
        case .permission(_, let phrase, let detail, let byVoice):
            VStack(alignment: .leading, spacing: 6) {
                Text(phrase).font(.system(size: 14, weight: .semibold))
                if detail != phrase, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Text(byVoice ? "Say yes or no" : "Saying no refuses it").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                    Button { onAnswer(false) } label: {
                        Text("Deny").font(.system(size: 12.5)).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                    }
                    Button { onAnswer(true) } label: {
                        Text("Allow").font(.system(size: 12.5)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        }
    }
}

/// A self-contained HTML snippet from the agent, such as a chart. Its scripts don't run and it loads nothing: a content
/// policy allows only inline styles and inline or data images, so a visual can't reach the network.
private struct HTMLVisual: NSViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    static let tallest: CGFloat = 420

    static func page(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <style>html,body{margin:0;padding:0;background:#000;color:#ECEDEE;font:13px -apple-system,system-ui,sans-serif}
        body{padding:12px;overflow:hidden}svg{max-width:100%;height:auto}</style></head><body>\(html)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page(html), baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(Self.page(html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onHeight: (CGFloat) -> Void
        var loaded = ""

        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                guard let height = value as? Double else { return }
                MainActor.assumeIsolated { self?.onHeight(min(HTMLVisual.tallest, CGFloat(height))) }
            }
        }

        /// Only the snippet itself loads. A link in it opens in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
