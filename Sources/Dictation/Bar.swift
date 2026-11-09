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
    /// The smoothed microphone level the print draws from, sampled while listening.
    let meter = VoiceMeter()
    /// The talk island's place on screen while a talk runs, which messages hang under.
    var talkAnchor: NSRect? {
        didSet { if talkAnchor != oldValue, state.body.isTalk, state.toast != nil { layout(animated: false) } }
    }

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
    /// The area `screen` had clear of other apps' bars when the bar last came up, read once per showing.
    private var cleared = NSRect.zero
    private weak var clearedScreen: NSScreen?
    private var drag: Drag?
    private var sampler: Timer?
    /// The body's capsule on screen, which is smaller than its panel while the words bar shows.
    private var capsuleFrame = NSRect.zero
    /// Checks the pointer while the words bar takes the mouse, so its panel takes clicks only over the capsule.
    private var pointer: Timer?

    private struct Drag {
        /// Mouse position within the body when the drag began.
        var offset: NSPoint
        var area: NSRect
    }

    /// `level` is polled while listening, for the print. `area` replaces the screen, for --render-bar.
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
        if next.body.isActive && !state.body.isActive || toastOnHiddenBar { (screen, clearedScreen) = (nil, nil) }
        let movedEdge = nextEdge != edge
        (state, edge) = (next, nextEdge)
        sampleLevels(state.body.isListening || state.body.isTalk)
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
        if let area { return area(screen) }
        guard let screen else { return .zero }
        if screen !== clearedScreen { (clearedScreen, cleared) = (screen, OtherBars.clear(screen)) }
        return cleared
    }

    /// The body's frame, or nil when hidden.
    private func layoutBody(in area: NSRect, animated: Bool) -> NSRect? {
        guard let size = BarStyle.size(of: state.body, edge: edge, agent: state.agent) else {
            bodyPanel.orderOut(nil)
            // A panel out of view keeps its views running, and the spinner's timeline would redraw 60 times a second.
            bodyHost.rootView = AnyView(EmptyView())
            followPointer()
            return nil
        }
        bodyHost.rootView = AnyView(BodyView(shown: state.body, agent: state.agent, edge: edge, meter: meter, capsuleWidth: size.width,
                                             onEvent: { [weak self] in self?.onEvent?($0) },
                                             onDrag: { [weak self] ended in self?.dragged(ended: ended) }))
        let inset = BarStyle.inset(of: state.body, edge: edge)
        let frame = NSRect(edge.place(width: size.width, height: size.height, in: BarRect(area), inset: inset))
        // While the words bar shows, its panel covers the widest the capsule can be on this edge, and the halo past
        // it, and never resizes. A change of width animates inside it, so macOS never shows a panel mid-resize with its
        // old content stretched across the new frame.
        let panelFrame = state.body.wordsBar == nil ? frame
            : NSRect(edge.place(width: max(BarStyle.maxWidth, size.width), height: size.height, in: BarRect(area), inset: inset))
                .insetBy(dx: -BarStyle.haloMargin, dy: -BarStyle.haloMargin)
        capsuleFrame = frame
        followPointer()
        // The words bar draws its own shadow; the system's would follow the halo.
        bodyPanel.hasShadow = state.body.wordsBar == nil
        if animated, bodyPanel.isVisible, bodyPanel.frame.height == panelFrame.height, bodyPanel.frame != panelFrame, state.body.wordsBar == nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                bodyPanel.animator().setFrame(panelFrame, display: true)
            }
        } else if bodyPanel.frame != panelFrame {
            bodyPanel.setFrame(panelFrame, display: true)
        }
        bodyPanel.orderFrontRegardless()
        return frame
    }

    /// The words bar's panel is larger than its capsule, and an empty part of a panel still takes clicks. So while it
    /// shows, the panel takes the mouse only while the pointer is over the capsule or a drag is on, checked 30 times a
    /// second, and a click beside the bar reaches the app under it.
    private func followPointer() {
        guard state.body.acceptsMouse, state.body.wordsBar != nil else {
            pointer?.invalidate()
            pointer = nil
            bodyPanel.ignoresMouseEvents = !state.body.acceptsMouse
            return
        }
        updatePointer()
        guard pointer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointer = timer
    }

    private func updatePointer() {
        let over = drag != nil || capsuleFrame.contains(NSEvent.mouseLocation)
        if bodyPanel.ignoresMouseEvents == over { bodyPanel.ignoresMouseEvents = !over }
    }

    private func layoutToast(in area: NSRect, against bodyFrame: NSRect?) {
        guard let notice = state.toast else {
            toastPanel.orderOut(nil)
            return
        }
        toastHost.rootView = AnyView(ToastView(notice: notice, onAction: { [weak self] in self?.onEvent?(.toastAction($0)) }))
        let size = toastHost.fittingSize
        // During a talk the bar is hidden and a message hangs under the island at the top instead.
        let talkAnchor = state.body.isTalk ? talkAnchor : nil
        let toastEdge = talkAnchor == nil ? edge : .top
        let anchor = talkAnchor.map { BarRect($0) } ?? bodyFrame.map { BarRect($0) }
            ?? edge.place(width: 0, height: 0, in: BarRect(area), inset: BarStyle.inset(of: .listening(words: "", handsFree: false), edge: edge))
        let frame = toastEdge.placeToast(width: size.width, height: size.height, against: anchor, gap: BarStyle.toastGap)
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
                self.meter.hear(rms: self.level())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    /// Where the body is on screen, or where it would be, so the agent's card can sit just above it.
    func anchor() -> (frame: NSRect, edge: BarEdge) {
        if bodyPanel.isVisible { return (capsuleFrame, edge) }
        let area = currentArea()
        return (NSRect(edge.place(width: 0, height: BarStyle.height, in: BarRect(area),
                                  inset: BarStyle.inset(of: .listening(words: "", handsFree: false), edge: edge))), edge)
    }

    /// The panels as they are now, bottom first, for --render-bar. `shadow` is whether the system gives the panel one.
    var visiblePanels: [(panel: NSPanel, shadow: Bool)] {
        [(outlinePanel, true), (bodyPanel, bodyPanel.hasShadow), (toastPanel, true)].filter { $0.0.isVisible }
    }

    /// Shows the drag outlines as they look mid-drag with the mouse nearest `edge`, or hides them, for --render-bar.
    func showOutlines(nearest: BarEdge?) {
        guard let nearest else { return outlinePanel.orderOut(nil) }
        outlinePanel.setFrame(currentArea(), display: true)
        outlineHost.rootView = AnyView(SnapOutlines(nearest: nearest))
        outlinePanel.orderFrontRegardless()
    }
}

/// Bars other apps draw along a screen's edges, which macOS leaves inside the visible frame: the top bar of a tiling
/// window manager such as OmniWM or AeroSpace with SketchyBar, or a strip another app keeps at a side. Read from the
/// window list, whose bounds need no permission.
@MainActor enum OtherBars {
    static func clear(_ screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        guard let bars = windows() else { return visible }
        return NSRect(BarRect(visible).clear(of: bars))
    }

    /// The whole screen less the strips other apps' bars cover, for the live-talk island, which sits above the macOS menu
    /// bar and so measures from the top of the screen, not from under the menu bar. A bar just under a visible menu bar
    /// counts too. The menu bar itself is not another app's bar.
    static func clearOfFrame(_ screen: NSScreen) -> NSRect {
        let frame = screen.frame
        guard let bars = windows() else { return frame }
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 0)
        return NSRect(BarRect(frame).clear(of: bars, touch: menuBar + 2))
    }

    /// Other apps' windows that could be a bar, in AppKit's coordinates, or nil when the window list cannot be read.
    private static func windows() -> [BarRect]? {
        guard let primary = NSScreen.screens.first?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let normal = Int(CGWindowLevelForKey(.normalWindow)), saver = Int(CGWindowLevelForKey(.screenSaverWindow))
        return list.compactMap { window in
            // Above ordinary windows but under the screen saver, and more than a hairline such as a window border.
            // The Dock, already outside the visible frame, and the hidden menu bar, which slides over everything only
            // while the mouse is at the top, are not bars to avoid.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer > normal, layer < saver,
                  window[kCGWindowOwnerPID as String] as? Int32 != me,
                  !["Dock", "Window Server"].contains(window[kCGWindowOwnerName as String] as? String ?? ""),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 4, rect.height >= 4
            else { return nil }
            // The window list measures from the top of the main screen, AppKit from its bottom.
            return BarRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
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
    /// Kept across dictations, so the next one starts already scaled to the speaker and the room.
    private var loudness = AutoLevel(rate: sampleRate)
    private var envelope = LevelEnvelope()
    /// The same voice smoothed once more, which lights the halo.
    private var glow = LevelEnvelope(stages: LevelEnvelope.glow)
    /// Set by --render-bar: the time every view draws for, and the envelope stays as `freeze` left it.
    private(set) var frozenAt: Double?

    func reset() {
        guard frozenAt == nil else { return }
        envelope.reset()
        glow.reset()
    }

    /// The RMS of the newest audio, scaled to the voice and the room.
    func hear(rms: Float) { follow(loudness.fraction(rms: rms)) }

    func follow(_ fraction: Float) {
        guard frozenAt == nil else { return }
        envelope.follow(fraction)
        glow.follow(fraction)
    }

    func freeze(at time: Double, profile: (Double) -> Float) {
        frozenAt = time
        envelope = LevelEnvelope(filling: profile)
        glow = LevelEnvelope(stages: LevelEnvelope.glow, filling: profile)
    }

    func reading(at time: Double) -> VoiceReading {
        if frozenAt == nil {
            envelope.advance(to: time)
            glow.advance(to: time)
        }
        return VoiceReading(envelope: envelope, glow: glow, time: frozenAt == nil ? time : envelope.clock ?? 0)
    }
}

struct VoiceReading {
    fileprivate let envelope: LevelEnvelope
    fileprivate let glow: LevelEnvelope
    fileprivate let time: Double

    func level(delay: Double) -> Double { Double(envelope.level(delay: delay, at: time)) }
    /// The level the halo glows with, `delay` seconds ago.
    func glow(delay: Double) -> Double { Double(glow.level(delay: delay, at: time)) }
}

/// Sizes shared by the views and the layout.
@MainActor enum BarStyle {
    static let height: CGFloat = 40
    /// The widest the words bar's panel is, so a capsule that widens, when a dictation becomes a Ghostwrite and its
    /// agent shows, or narrows, when hands-free ends, animates inside it instead of resizing the panel.
    static let maxWidth: CGFloat = 440
    static let padding: CGFloat = 18
    static let glyphGap: CGFloat = 13
    static let glyphWidth = CGFloat(HalftonePrint.width)
    static let buttonSize: CGFloat = 24
    static let buttonsWidth = 2 * buttonSize + 6
    static let idle = CGSize(width: 28, height: 14)
    static let toastGap: CGFloat = 8
    /// How far the words bar's panel reaches past the capsule on every side, for the halo: its reach, and two to spare.
    static let haloMargin = CGFloat(HaloGlow.reach) + 2
    static let toastMaxWidth: CGFloat = 520
    static let toastTitleFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let toastDetailFont = NSFont.systemFont(ofSize: 12.5)
    static let statusFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let fill = Theme.canvas.opacity(0.96)

    /// Distance from the screen edge: the idle pill sits at it, the body a little in.
    static func inset(of body: BarState.Body, edge: BarEdge) -> CGFloat {
        if body == .idle { return 3 }
        return edge.isSide ? 8 : 16
    }

    static func size(of body: BarState.Body, edge: BarEdge, agent: BarAgent? = nil) -> CGSize? {
        switch body {
        case .hidden, .talk: nil
        case .idle: edge.isSide ? CGSize(width: idle.height, height: idle.width) : idle
        case .listening(_, let handsFree): CGSize(width: wordsBarWidth(handsFree: handsFree, agent: agent), height: height)
        case .transcribing(_, nil): CGSize(width: wordsBarWidth(handsFree: false, agent: agent), height: height)
        case .working(let status, _):
            CGSize(width: padding + agentWidth(agent) + glyphWidth + glyphGap + measure(status, statusFont) + padding, height: height)
        case .transcribing(_, .some(let phase)), .preparing(let phase):
            CGSize(width: padding + 16 + 10 + measure(Self.describe(phase), statusFont) + padding, height: height)
        }
    }

    /// The agent's mark and name ahead of the print, and the gap after them.
    static func agentWidth(_ agent: BarAgent?) -> CGFloat {
        guard let agent else { return 0 }
        return avatarSize + 8 + measure(agent.name, agentFont) + glyphGap
    }

    static let avatarSize: CGFloat = 22
    static let agentFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// The words bar's width, the same whatever is said: the agent's mark, the waves, and the hands-free buttons.
    static func wordsBarWidth(handsFree: Bool, agent: BarAgent?) -> CGFloat {
        padding + agentWidth(agent) + CGFloat(LightWave.width) + (handsFree ? glyphGap + buttonsWidth : 0) + padding
    }

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
    var isTalk: Bool { if case .talk = self { true } else { false } }
    /// The capsule with the waves, while listening and while the last words are finished. It is one
    /// view in both, so the waves settle without starting over.
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

extension BarRect {
    init(_ rect: NSRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

extension NSRect {
    init(_ rect: BarRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

private struct BodyView: View {
    let shown: BarState.Body
    let agent: BarAgent?
    let edge: BarEdge
    let meter: VoiceMeter
    /// The words bar's capsule width. Its panel is wider, and a new width animates inside it.
    let capsuleWidth: CGFloat
    let onEvent: (BarEvent) -> Void
    let onDrag: (_ ended: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let bar = shown.wordsBar {
            GrowingBar(width: capsuleWidth, meter: meter, listening: !bar.finishing, capsule: wordsBar(bar))
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.9, 0.3, 1, duration: 0.25), value: capsuleWidth)
                .gesture(dragging)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .left ? .leading : edge == .right ? .trailing : .center)
                .padding(BarStyle.haloMargin)
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(dragging)
        }
    }

    private var dragging: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) }
    }

    private func wordsBar(_ bar: (words: String, handsFree: Bool, finishing: Bool)) -> some View {
        capsule(behind: EmptyView()) {
            if let agent { AgentChip(agent: agent) }
            WaveView(meter: meter, finishing: bar.finishing)
                .frame(width: CGFloat(LightWave.width), height: BarStyle.height)
            Spacer(minLength: 0)
            if bar.handsFree { HandsFreeButtons(onEvent: onEvent) }
        }
    }

    @ViewBuilder private var content: some View {
        if shown.wordsBar != nil {
            EmptyView()
        } else {
            switch shown {
            case .hidden, .listening, .transcribing(_, nil), .talk:
                EmptyView()
            case .working(let status, let busy):
                capsule(behind: Print(meter: meter, finishing: true, resting: !busy, offset: BarStyle.agentWidth(agent))) {
                    if let agent { AgentChip(agent: agent) }
                    Color.clear.frame(width: BarStyle.glyphWidth)
                    Text(status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, BarStyle.glyphGap)
                    Spacer(minLength: 0)
                }
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

/// The words bar's capsule at `width`, with its shadow and its halo. Animatable, so while a new width animates SwiftUI
/// draws it at every width in between, and the capsule and the halo grow together frame by frame.
private struct GrowingBar<Capsule: View>: View, Animatable {
    // SwiftUI reads and writes the animated width off the main actor; a CGFloat is safe to share.
    nonisolated(unsafe) var width: CGFloat
    let meter: VoiceMeter
    let listening: Bool
    let capsule: Capsule

    nonisolated var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    var body: some View {
        capsule
            .frame(width: width, height: BarStyle.height)
            .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
            .background { HaloView(meter: meter, listening: listening).padding(-BarStyle.haloMargin) }
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

/// A distance that grows with time at a pace that can change, so speeding up never jumps the waves.
@MainActor private final class Travel {
    private var distance = 0.0
    private var last: Double?

    func step(at time: Double, pace: Double) -> Double {
        defer { last = time }
        if let last { distance += min(0.05, max(0, time - last)) * pace }
        return distance
    }
}

/// Redraws at most 60 times a second, even on a faster screen, or once at the time --render-bar froze, or once when
/// `still` is set. Nothing here runs once the view is out of the window.
private struct Ticker<Content: View>: View {
    let frozenAt: Double?
    var still = false
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        if let frozenAt {
            content(frozenAt)
        } else if still {
            content(0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in content(context.date.timeIntervalSinceReferenceDate) }
        }
    }
}

/// The glyph ahead of an agent's status: a halftone print in white dots on a fine 45-degree screen, settled to a dim
/// baseline with a light running along it while the agent works, and still while it waits on you. It can also print
/// the voice, newest at the left. With Reduce Motion it is a still dim baseline.
private struct Print: View {
    let meter: VoiceMeter
    let finishing: Bool
    /// Waiting on the user: drawn once as the still dim baseline, so a card left open costs no frames.
    var resting = false
    /// Room left of the print for the agent's mark.
    var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listening = Eased()
    @State private var turning = Eased()

    private static let ink = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF5 / 255).opacity(0.96)

    private var still: Bool { reduceMotion || resting }

    var body: some View {
        Ticker(frozenAt: meter.frozenAt, still: still) { time in
            Canvas { context, size in draw(into: &context, size: size, time: time) }
        }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, time: Double) {
        let settled = meter.frozenAt != nil || still
        let listen = settled ? listening.settle(at: finishing ? 0 : 1) : listening.step(toward: finishing ? 0 : 1, tau: 0.12, at: time)
        let spin = settled ? turning.settle(at: finishing ? 1 : 0) : turning.step(toward: finishing ? 1 : 0, tau: 0.12, at: time)
        let voice = still ? nil : meter.reading(at: time)
        let light = still ? HalftonePrint.Light.still : .running(time: time)
        let left = BarStyle.padding + offset, centerY = size.height / 2

        for dot in HalftonePrint.dots {
            let heard = (voice?.level(delay: dot.delay) ?? 0) * listen
            let covered = HalftonePrint.coverage(of: dot, voice: heard, spin: spin, light: light)
            guard let radius = HalftonePrint.radius(coverage: covered) else { continue }
            let x = left + dot.x, y = centerY - dot.y
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)), with: .color(Self.ink))
        }
    }
}

/// The glow around the capsule, drawn behind it and reaching `BarStyle.haloMargin` past it on every side, so it grows
/// with the capsule frame by frame: a blurred halo and a soft rim in shades of blue that turn slowly around the capsule, and a bright beam that
/// runs around the rim. All three brighten with the voice. It fades in while listening and out while the words are
/// finished. With Reduce Motion the rim and halo stay still, with no beam. Each frame blurs three layers, the halo, the
/// rim's feather and the beam's bloom; the rim and beam themselves are drawn sharp, since a blur under a point wide
/// did not show and cost a layer each.
private struct HaloView: View {
    let meter: VoiceMeter
    let listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var aura = Eased()

    private static let blues = Gradient(colors: (HaloGlow.rimColors + [HaloGlow.rimColors[0]]).map { Color(red: $0.red, green: $0.green, blue: $0.blue) })

    var body: some View {
        Ticker(frozenAt: meter.frozenAt, still: reduceMotion) { time in
            Canvas { context, size in draw(into: &context, size: size, time: time) }
        }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, time: Double) {
        let target = listening ? 1.0 : 0.0
        let fade = meter.frozenAt != nil || reduceMotion ? aura.settle(at: target) : aura.step(toward: target, tau: listening ? 0.35 : 0.5, at: time)
        guard fade > 0.004 else { return }
        let margin = BarStyle.haloMargin, rim = CGFloat(HaloGlow.rimWidth)
        let capsule = CGRect(x: margin, y: margin, width: size.width - 2 * margin, height: size.height - 2 * margin)
        let ring = capsule.insetBy(dx: -rim / 2, dy: -rim / 2)
        let rimPath = Path(roundedRect: ring, cornerRadius: ring.height / 2)
        let haloRing = capsule.insetBy(dx: -3, dy: -3)
        let light = reduceMotion ? HaloGlow.restingLight : HaloGlow.light(glow: meter.reading(at: time).glow(delay: 0))
        let blues = GraphicsContext.Shading.conicGradient(Self.blues, center: CGPoint(x: capsule.midX, y: capsule.midY),
                                                          angle: .radians(reduceMotion ? 0 : HaloGlow.turn(at: time)))

        var halo = context
        halo.opacity = HaloGlow.haloOpacity(light: light) * fade
        halo.addFilter(.blur(radius: HaloGlow.haloRadius(light: light)))
        halo.stroke(Path(roundedRect: haloRing, cornerRadius: haloRing.height / 2), with: blues, lineWidth: 10)

        let rimOpacity = HaloGlow.rimOpacity(light: light) * fade
        var feather = context
        feather.opacity = rimOpacity * 0.7
        feather.addFilter(.blur(radius: 2.5))
        feather.stroke(rimPath, with: blues, lineWidth: rim * 2.2)
        var core = context
        core.opacity = rimOpacity
        core.stroke(rimPath, with: blues, lineWidth: rim)
        guard !reduceMotion else { return }

        let perimeter = HaloGlow.perimeter(capsuleWidth: capsule.width, capsuleHeight: capsule.height)
        let beamOpacity = HaloGlow.beamOpacity(light: light) * fade
        var bloom = context
        bloom.opacity = 0.9
        bloom.addFilter(.blur(radius: 5))
        for slice in HaloGlow.beam(at: time, perimeter: perimeter) {
            let piece = rimPath.trimmedPath(from: slice.from, to: slice.to)
            let rgb = HaloGlow.beamColor(along: slice.along)
            let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(slice.light * beamOpacity)
            bloom.stroke(piece, with: .color(color), style: StrokeStyle(lineWidth: rim * 3, lineCap: .round))
            context.stroke(piece, with: .color(color), style: StrokeStyle(lineWidth: rim, lineCap: .butt))
        }
    }
}

/// The words bar's inside: three soft blue waves that follow the voice. Each sound starts in the middle and ripples out
/// to both ends, and the waves run faster and glow brighter as the voice rises. While the words are finished they
/// settle to a dim, almost flat line that breathes. Each frame blurs one layer, the glow under the waves. With Reduce
/// Motion the waves are drawn once, still.
private struct WaveView: View {
    let meter: VoiceMeter
    let finishing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 while you talk, easing to 0 once the words are finished.
    @State private var live = Eased()
    /// How far the waves have travelled, at their resting speed; it runs faster while you talk.
    @State private var travel = Travel()

    var body: some View {
        Ticker(frozenAt: meter.frozenAt, still: reduceMotion) { time in
            Canvas { context, size in draw(into: &context, size: size, time: time) }
        }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, time: Double) {
        let settled = meter.frozenAt != nil || reduceMotion
        let reading = meter.reading(at: time)
        let now = reduceMotion ? 0 : reading.level(delay: 0)
        let liveness = settled ? live.settle(at: finishing ? 0 : 1) : live.step(toward: finishing ? 0 : 1, tau: 0.15, at: time)
        let travelled = reduceMotion ? 0 : meter.frozenAt != nil ? time : travel.step(at: time, pace: LightWave.pace(level: now * liveness))
        let width = size.width, mid = size.height / 2

        let steps = Int(width / 2)
        let swell = (0...steps).map { index -> Double in
            let along = Double(index) / Double(steps)
            let voice = reduceMotion ? LightWave.restingAmplitude : LightWave.amplitude(level: reading.level(delay: LightWave.delay(along: along)))
            return LightWave.finishingAmplitude + (voice - LightWave.finishingAmplitude) * liveness
        }
        let paths = LightWave.strands.map { strand in
            var path = Path()
            for index in 0...steps {
                let along = Double(index) / Double(steps)
                let point = CGPoint(x: along * width, y: mid - LightWave.offset(strand, along: along, travel: travelled, amplitude: swell[index]))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }

        let speaking = LightWave.brightness(level: now)
        let resting = reduceMotion ? 0.45 : LightWave.finishingBrightness(at: time)
        context.opacity = resting + (speaking - resting) * liveness
        var glow = context
        glow.addFilter(.blur(radius: 4))
        for (path, strand) in zip(paths, LightWave.strands) {
            glow.stroke(path, with: shading(strand, 0.8, width: width), lineWidth: 3 + 2 * now * liveness)
        }
        for (path, strand) in zip(paths, LightWave.strands) {
            context.stroke(path, with: shading(strand, 0.9, width: width), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    /// A wave's colour, faded in from each end.
    private func shading(_ strand: LightWave.Strand, _ opacity: Double, width: CGFloat) -> GraphicsContext.Shading {
        let color = Color(red: strand.red, green: strand.green, blue: strand.blue).opacity(opacity)
        let fade = LightWave.fade
        return .linearGradient(Gradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: fade),
                                                .init(color: color, location: 1 - fade), .init(color: color.opacity(0), location: 1)]),
                               startPoint: .zero, endPoint: CGPoint(x: width, y: 0))
    }
}

/// The agent's round mark and its name, as on the card.
struct AgentChip: View {
    let agent: BarAgent

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(initial: agent.initial, size: BarStyle.avatarSize)
            Text(agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
        }
        .padding(.trailing, BarStyle.glyphGap)
    }
}

struct AgentAvatar: View {
    let initial: String
    let size: CGFloat

    var body: some View {
        Circle().fill(Theme.blue).frame(width: size, height: size)
            .overlay(Text(initial).font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(.white))
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
