import AppKit
import DictationCore
import SwiftUI

/// What the bar asks of its owner.
enum BarEvent: Equatable {
    case stop, cancel
    case moved(BarEdge)
    case toastAction(BarToastAction)
}

/// The floating bar: a body at the chosen screen edge and a toast attached to it, each in its own panel. Renders a
/// BarState. It owns only what it shows: the screen it sits on, the voice meter, and a drag in progress.
@MainActor final class Bar {
    var onEvent: ((BarEvent) -> Void)?
    /// The smoothed microphone level the scope draws from, sampled while listening.
    let meter = VoiceMeter()

    private let bodyPanel = BarPanel()
    private let toastPanel = BarPanel()
    private let outlinePanel = BarPanel()
    private let bodyHost = BarHostingView(rootView: AnyView(EmptyView()))
    private let toastHost = BarHostingView(rootView: AnyView(EmptyView()))
    private let outlineHost = BarHostingView(rootView: AnyView(EmptyView()))
    private let level: @MainActor () -> Float
    /// The visible frame of the screen to use. Defaults to the screen the bar is on, or the mouse's.
    private let area: (@MainActor (_ current: NSScreen?) -> NSRect)?
    private var state = BarState(body: .hidden)
    private var edge = BarEdge.bottom
    private var screen: NSScreen?
    private var drag: Drag?
    private var sampler: Timer?

    private struct Drag {
        /// Mouse position within the body when the drag began.
        var offset: NSPoint
        var area: NSRect
    }

    /// `level` is polled while listening, for the scope. `area` replaces the screen, for --render-bar.
    init(level: @escaping @MainActor () -> Float, area: (@MainActor (_ current: NSScreen?) -> NSRect)? = nil) {
        self.level = level
        self.area = area
        for (panel, host) in [(bodyPanel, bodyHost), (toastPanel, toastHost), (outlinePanel, outlineHost)] {
            panel.contentView = host
        }
        toastHost.sizingOptions = [.intrinsicContentSize]
        outlinePanel.hasShadow = false
    }

    /// Shown with orderFrontRegardless, never makeKeyAndOrderFront, so the app never activates and focus stays in
    /// the user's text field.
    func render(_ next: BarState, edge nextEdge: BarEdge) {
        let toastOnHiddenBar = next.body == .hidden && next.toast != nil && state.toast == nil
        if next.body.isActive && !state.body.isActive || toastOnHiddenBar { screen = nil }
        let movedEdge = nextEdge != edge
        (state, edge) = (next, nextEdge)
        sampleLevels(state.body.isListening)
        guard drag == nil else { return }
        layout(animated: !movedEdge)
    }

    private func layout(animated: Bool) {
        let area = currentArea()
        let bodyFrame = layoutBody(in: area, animated: animated)
        layoutToast(in: area, against: bodyFrame)
    }

    private func currentArea() -> NSRect {
        if screen == nil || !NSScreen.screens.contains(where: { $0 === screen }) {
            screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        return area?(screen) ?? screen?.visibleFrame ?? .zero
    }

    /// The body's frame, or nil when hidden.
    private func layoutBody(in area: NSRect, animated: Bool) -> NSRect? {
        guard let size = BarStyle.size(of: state.body, edge: edge) else {
            bodyPanel.orderOut(nil)
            // A panel out of view keeps its views running, and the spinner's timeline would redraw 60 times a second.
            bodyHost.rootView = AnyView(EmptyView())
            return nil
        }
        bodyHost.rootView = AnyView(BodyView(shown: state.body, edge: edge, meter: meter,
                                             onEvent: { [weak self] in self?.onEvent?($0) },
                                             onDrag: { [weak self] ended in self?.dragged(ended: ended) }))
        let frame = NSRect(edge.place(width: size.width, height: size.height, in: BarRect(area),
                                      inset: BarStyle.inset(of: state.body, edge: edge)))
        bodyPanel.ignoresMouseEvents = !state.body.acceptsMouse
        if animated, bodyPanel.isVisible, bodyPanel.frame.height == frame.height, bodyPanel.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                bodyPanel.animator().setFrame(frame, display: true)
            }
        } else {
            bodyPanel.setFrame(frame, display: true)
        }
        bodyPanel.orderFrontRegardless()
        return frame
    }

    private func layoutToast(in area: NSRect, against bodyFrame: NSRect?) {
        guard let notice = state.toast else {
            toastPanel.orderOut(nil)
            return
        }
        toastHost.rootView = AnyView(ToastView(notice: notice, onAction: { [weak self] in self?.onEvent?(.toastAction($0)) }))
        let size = toastHost.fittingSize
        let anchor = bodyFrame.map { BarRect($0) } ?? edge.place(width: 0, height: 0, in: BarRect(area),
                                                               inset: BarStyle.inset(of: .listening(words: "", handsFree: false), edge: edge))
        let frame = edge.placeToast(width: size.width, height: size.height, against: anchor, gap: BarStyle.toastGap)
        toastPanel.ignoresMouseEvents = notice.action == nil
        toastPanel.setFrame(NSRect(frame), display: true)
        toastPanel.orderFrontRegardless()
    }

    /// The body follows the mouse while dashed outlines mark the four snap spots. The drop snaps to the nearest,
    /// which the owner saves.
    private func dragged(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        let drag = drag ?? beginDrag(at: mouse)
        let nearest = BarEdge.nearest(x: mouse.x, y: mouse.y, in: BarRect(drag.area))
        if ended {
            self.drag = nil
            outlinePanel.orderOut(nil)
            if nearest == edge { layout(animated: false) } else { onEvent?(.moved(nearest)) }
            return
        }
        outlineHost.rootView = AnyView(SnapOutlines(nearest: nearest))
        bodyPanel.setFrameOrigin(NSPoint(x: mouse.x - drag.offset.x, y: mouse.y - drag.offset.y))
    }

    private func beginDrag(at mouse: NSPoint) -> Drag {
        let started = Drag(offset: NSPoint(x: mouse.x - bodyPanel.frame.minX, y: mouse.y - bodyPanel.frame.minY), area: currentArea())
        drag = started
        outlinePanel.setFrame(started.area, display: true)
        outlinePanel.order(.below, relativeTo: bodyPanel.windowNumber)
        toastPanel.orderOut(nil)
        return started
    }

    private func sampleLevels(_ listening: Bool) {
        guard listening != (sampler != nil) else { return }
        sampler?.invalidate()
        sampler = nil
        guard listening else { return meter.follow(0) }
        meter.reset()
        let timer = Timer(timeInterval: 1.0 / VoiceMeter.sampleRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.meter.follow(Loudness.fraction(rms: self.level()))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    /// The panels as they are now, for --render-bar.
    var visiblePanels: [NSPanel] { [outlinePanel, bodyPanel, toastPanel].filter(\.isVisible) }

    /// Shows the drag outlines as they look mid-drag with the mouse nearest `edge`, or hides them, for --render-bar.
    func showOutlines(nearest: BarEdge?) {
        guard let nearest else { return outlinePanel.orderOut(nil) }
        outlinePanel.setFrame(currentArea(), display: true)
        outlineHost.rootView = AnyView(SnapOutlines(nearest: nearest))
        outlinePanel.orderFrontRegardless()
    }
}

/// Cannot become key or main, never activates the app, and stays out of window cycling. AeroSpace, which tiles
/// standard windows, sees no window to manage. It takes the mouse only while it shows something to click or drag.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
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

/// Takes the first click, so a button works in a panel that is never key.
private final class BarHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The voice as the bar draws it: the microphone level, smoothed, with the last two seconds kept. Views read it with
/// the time they are drawing for, and it moves its own clock up to that time, so every dot is continuous.
/// Not observable: the views run on a timeline and look at it each frame.
@MainActor final class VoiceMeter {
    nonisolated static let sampleRate = 60.0
    private var envelope = LevelEnvelope()
    /// Set by --render-bar: the time every view draws for, and the envelope stays as `freeze` left it.
    private(set) var frozenAt: Double?

    func reset() {
        guard frozenAt == nil else { return }
        envelope.reset()
    }

    func follow(_ fraction: Float) {
        guard frozenAt == nil else { return }
        envelope.follow(fraction)
    }

    func freeze(at time: Double, profile: (Double) -> Float) {
        frozenAt = time
        envelope = LevelEnvelope(filling: profile)
    }

    func reading(at time: Double) -> VoiceReading {
        if frozenAt == nil { envelope.advance(to: time) }
        return VoiceReading(envelope: envelope, time: frozenAt == nil ? time : envelope.clock ?? 0)
    }
}

struct VoiceReading {
    fileprivate let envelope: LevelEnvelope
    fileprivate let time: Double

    func level(delay: Double) -> Double { Double(envelope.level(delay: delay, at: time)) }
}

/// Sizes shared by the views and the layout.
@MainActor enum BarStyle {
    static let height: CGFloat = 40
    static let maxWidth: CGFloat = 560
    static let padding: CGFloat = 18
    static let glyphGap: CGFloat = 13
    /// The scope: 15 columns by 7 rows of dots, 3 pt apart.
    static let scopePitch: CGFloat = 3
    static let glyphWidth = CGFloat(HalftoneScope.columns - 1) * scopePitch + 3
    static let buttonSize: CGFloat = 24
    static let buttonsWidth = 2 * buttonSize + 6
    static let idle = CGSize(width: 28, height: 14)
    static let toastGap: CGFloat = 8
    static let toastMaxWidth: CGFloat = 520
    static let toastTitleFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let toastDetailFont = NSFont.systemFont(ofSize: 12.5)
    static let wordsFont = NSFont.systemFont(ofSize: 15)
    static let statusFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let fill = Theme.canvas.opacity(0.96)

    /// Distance from the screen edge: the idle pill sits at it, the body a little in.
    static func inset(of body: BarState.Body, edge: BarEdge) -> CGFloat {
        if body == .idle { return 3 }
        return edge.isSide ? 8 : 16
    }

    static func size(of body: BarState.Body, edge: BarEdge) -> CGSize? {
        switch body {
        case .hidden: nil
        case .idle: edge.isSide ? CGSize(width: idle.height, height: idle.width) : idle
        case .listening(let words, let handsFree): CGSize(width: wordsLayout(words, handsFree: handsFree).capsuleWidth, height: height)
        case .transcribing(let words, nil): CGSize(width: wordsLayout(words, handsFree: false).capsuleWidth, height: height)
        case .transcribing(_, .some(let phase)), .preparing(let phase):
            CGSize(width: padding + 16 + 10 + measure(Self.describe(phase), statusFont) + padding, height: height)
        }
    }

    struct WordsLayout: Equatable {
        /// The words' frame. Narrower than the words when they overflow, and then the newest words show.
        var textWidth: CGFloat
        /// The whole line's width.
        var naturalWidth: CGFloat
        var overflows: Bool
        var capsuleWidth: CGFloat
    }

    static func wordsLayout(_ words: String, handsFree: Bool) -> WordsLayout {
        let fixed = padding + glyphWidth + (handsFree ? glyphGap + buttonsWidth : 0) + padding
        let line = tokens(words).joined(separator: " ")
        guard !line.isEmpty else { return WordsLayout(textWidth: 0, naturalWidth: 0, overflows: false, capsuleWidth: fixed) }
        let natural = measure(line, wordsFont)
        let room = maxWidth - fixed - glyphGap
        let textWidth = min(natural, room)
        return WordsLayout(textWidth: textWidth, naturalWidth: natural, overflows: natural > room,
                           capsuleWidth: fixed + glyphGap + textWidth)
    }

    /// The words one by one, which is how they fade in.
    static func tokens(_ words: String) -> [Substring] { words.split(whereSeparator: \.isWhitespace) }

    static let spaceWidth = rawWidth(" ")

    /// A word's width as the line was measured. SwiftUI rounds each word's own width up, which over a line adds up to
    /// several points, so the words are framed to this instead.
    static func rawWidth(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: wordsFont]).size().width }

    /// The text column's width in a toast: each line on one line when it fits, else the widest the toast allows,
    /// wrapping.
    static func toastTextWidth(_ notice: BarNotice) -> CGFloat {
        let icon: CGFloat = 24, spacing: CGFloat = 12, leading: CGFloat = 12, trailing: CGFloat = 18
        let button = notice.action.map { measure($0.title, .systemFont(ofSize: 12, weight: .semibold)) + 24 + spacing } ?? 0
        let natural = max(measure(notice.title, toastTitleFont), notice.detail.map { measure($0, toastDetailFont) } ?? 0)
        return min(natural, toastMaxWidth - leading - trailing - icon - spacing - button)
    }

    static func describe(_ phase: LoadPhase) -> String {
        switch phase {
        case .downloading(let fraction): "Downloading model \(Int(fraction * 100))%"
        case .compiling: "Preparing model, first run takes about a minute"
        case .preparingVocabulary: "Preparing vocabulary"
        }
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (NSAttributedString(string: text, attributes: [.font: font]).size().width + 1).rounded(.up)
    }
}

private extension BarState.Body {
    var isListening: Bool { if case .listening = self { true } else { false } }
    /// The capsule with the glyph and the words, while listening and while the last words are finished. It is one
    /// view in both, so the glyph can crossfade from one to the other.
    var wordsBar: (words: String, handsFree: Bool, finishing: Bool)? {
        switch self {
        case .listening(let words, let handsFree): (words, handsFree, false)
        case .transcribing(let words, nil): (words, false, true)
        default: nil
        }
    }
    /// Anything but hidden and idle, which keep the screen the bar was last on.
    var isActive: Bool { self != .hidden && self != .idle }
    /// The idle pill and the listening capsule can be dragged, and hands-free has buttons.
    var acceptsMouse: Bool { self == .idle || isListening }
}

private extension BarRect {
    init(_ rect: NSRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

private extension NSRect {
    init(_ rect: BarRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

private struct BodyView: View {
    let shown: BarState.Body
    let edge: BarEdge
    let meter: VoiceMeter
    let onEvent: (BarEvent) -> Void
    let onDrag: (_ ended: Bool) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
    }

    @ViewBuilder private var content: some View {
        if let bar = shown.wordsBar {
            capsule(behind: Scope(meter: meter, finishing: bar.finishing)) {
                Color.clear.frame(width: BarStyle.glyphWidth)
                if !bar.words.isEmpty {
                    Words(words: bar.words, layout: BarStyle.wordsLayout(bar.words, handsFree: bar.handsFree), dimmed: bar.finishing)
                }
                Spacer(minLength: 0)
                if bar.handsFree { HandsFreeButtons(onEvent: onEvent) }
            }
        } else {
            switch shown {
            case .hidden, .listening, .transcribing(_, nil):
                EmptyView()
            case .idle:
                IdlePill(upright: edge.isSide)
            case .transcribing(_, .some(let phase)), .preparing(let phase):
                capsule(behind: EmptyView()) {
                    Spinner()
                    Text(BarStyle.describe(phase))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 10)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// `behind` fills the capsule under its content and is clipped to it.
    private func capsule(behind: some View, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, BarStyle.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(alignment: .leading) { behind }
            .background(Capsule().fill(BarStyle.fill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07)))
            .clipShape(Capsule())
    }
}

/// Runs a time to a value the way a spring-less ease does: each frame closes a share of the gap.
@MainActor private final class Eased {
    private var value = 0.0
    private var last: Double?

    func step(toward target: Double, tau: Double, at time: Double) -> Double {
        defer { last = time }
        guard let last else { return value }
        value += (target - value) * (1 - exp(-min(0.05, max(0, time - last)) / tau))
        return value
    }

    func settle(at target: Double) -> Double {
        value = target
        return target
    }
}

/// Redraws every frame, or once at the time --render-bar froze. Nothing here runs once the view is out of the window.
private struct Ticker<Content: View>: View {
    let frozenAt: Double?
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        if let frozenAt {
            content(frozenAt)
        } else {
            TimelineView(.animation) { context in content(context.date.timeIntervalSinceReferenceDate) }
        }
    }
}

/// The scope, a fine halftone grid under the capsule's content. The newest voice is the column next to the words, and
/// older voice moves left and fades, so it reads as flowing into the text. Speaking grows dots out from the middle row.
/// While the words are being finished the grid settles to the middle row and a ripple runs toward the words. A soft
/// blue light rises behind it with the voice.
private struct Scope: View {
    let meter: VoiceMeter
    let finishing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listening = Eased()
    @State private var turning = Eased()

    private static let base = (r: 90.0, g: 132.0, b: 240.0), core = (r: 238.0, g: 242.0, b: 255.0)
    private static let light = Color(red: 0x3E / 255, green: 0x6A / 255, blue: 0xE1 / 255)

    var body: some View {
        Ticker(frozenAt: meter.frozenAt) { time in
            Canvas { context, size in draw(into: &context, size: size, time: time) }
        }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, time: Double) {
        let frozen = meter.frozenAt != nil
        let listen = frozen ? listening.settle(at: finishing ? 0 : 1) : listening.step(toward: finishing ? 0 : 1, tau: 0.12, at: time)
        let spin = frozen ? turning.settle(at: finishing ? 1 : 0) : turning.step(toward: finishing ? 1 : 0, tau: 0.12, at: time)
        let voice = meter.reading(at: time)
        let pitch = BarStyle.scopePitch
        let left = BarStyle.padding + 1.5, centerY = size.height / 2

        let glow = voice.level(delay: 0.04) * listen
        if glow > 0.01 {
            let center = CGPoint(x: left + Double(HalftoneScope.lastColumn) * pitch * 0.7, y: centerY)
            var lit = context
            lit.opacity = glow
            lit.fill(Path(CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60)),
                     with: .radialGradient(Gradient(colors: [Self.light.opacity(0.2), Self.light.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: 30))
        }

        for column in 0..<HalftoneScope.columns {
            let heard = voice.level(delay: HalftoneScope.delay(column: column)) * listen
            for row in 0..<HalftoneScope.rows {
                let s = HalftoneScope.brightness(column: column, row: row, voice: heard, spin: spin, time: time, still: reduceMotion)
                let radius = 0.38 + 1.02 * s
                let mix = s * s
                let color = Color(red: (Self.base.r + (Self.core.r - Self.base.r) * mix) / 255,
                                  green: (Self.base.g + (Self.core.g - Self.base.g) * mix) / 255,
                                  blue: (Self.base.b + (Self.core.b - Self.base.b) * mix) / 255)
                let x = left + Double(column) * pitch, y = centerY + Double(row - HalftoneScope.middleRow) * pitch
                context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(color.opacity(0.11 + 0.89 * s)))
            }
        }
    }
}

/// A white arc turning once a second, drawn here so it matches the bar in any appearance.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 14, height: 14)
        .frame(width: 16)
    }
}

/// One line. Each new word fades in out of a blur, rising a little. When the line overflows, the newest words stay and
/// the start fades out; the line slides over to make room.
private struct Words: View {
    let words: String
    let layout: BarStyle.WordsLayout
    let dimmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shift = layout.overflows ? layout.naturalWidth - layout.textWidth : 0
        HStack(spacing: BarStyle.spaceWidth) {
            ForEach(Array(BarStyle.tokens(words).enumerated()), id: \.offset) { _, token in
                Word(text: String(token), width: BarStyle.rawWidth(String(token)))
            }
        }
        .fixedSize()
        .offset(x: -shift)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.55), value: shift)
        .frame(width: layout.textWidth, height: BarStyle.height, alignment: .leading)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .black.opacity(layout.overflows ? 0 : 1), location: 0), .init(color: .black, location: 0.12)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .opacity(dimmed ? 0.5 : 1)
        .animation(.easeOut(duration: 0.3), value: dimmed)
        .padding(.leading, BarStyle.glyphGap)
    }
}

private struct Word: View {
    let text: String
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, alignment: .leading)
            .opacity(arrived ? 1 : 0)
            .blur(radius: arrived || reduceMotion ? 0 : 6)
            .offset(y: arrived || reduceMotion ? 0 : 3)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.6)) { arrived = true }
            }
    }
}

private struct HandsFreeButtons: View {
    let onEvent: (BarEvent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { onEvent(.stop) } label: {
                Circle().fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: 9, height: 9))
            }
            .accessibilityLabel("Stop and insert")
            Button { onEvent(.cancel) } label: {
                Circle().fill(Color.white.opacity(0.16))
                    .overlay(Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            }
            .accessibilityLabel("Cancel recording")
        }
        .buttonStyle(.plain)
        .frame(width: BarStyle.buttonsWidth, height: BarStyle.buttonSize)
        .padding(.leading, BarStyle.glyphGap)
        .padding(.trailing, -6)
    }
}

private struct IdlePill: View {
    let upright: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(BarStyle.fill)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12)))
            .overlay {
                HStack(spacing: 2.6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.72)).frame(width: 2.4, height: 2.4) }
                }
                .rotationEffect(.degrees(upright ? 90 : 0))
            }
    }
}

private struct ToastView: View {
    let notice: BarNotice
    let onAction: (BarToastAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Theme.symbol(notice.tone))
                .font(.system(size: 21))
                .foregroundStyle(Theme.color(notice.tone))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                if let detail = notice.detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.72))
                }
            }
            .frame(width: BarStyle.toastTextWidth(notice), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.blue))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.toast.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

/// The four places a drop can snap to, the nearest brighter.
private struct SnapOutlines: View {
    let nearest: BarEdge

    var body: some View {
        GeometryReader { proxy in
            let area = BarRect(x: 0, y: 0, width: proxy.size.width, height: proxy.size.height)
            ForEach(BarEdge.allCases, id: \.self) { edge in
                let size = edge.isSide ? CGSize(width: 22, height: 44) : CGSize(width: 44, height: 22)
                let spot = edge.place(width: size.width, height: size.height, in: area, inset: 3)
                let highlighted = edge == nearest
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.black.opacity(highlighted ? 0.32 : 0.14))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Color.white.opacity(highlighted ? 1 : 0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .frame(width: size.width, height: size.height)
                    .position(x: spot.midX, y: proxy.size.height - spot.midY)
            }
        }
    }
}
