import AppKit
import DictationCore
import Observation
import SwiftUI

/// Everything the island shows. Changed only on main.
@MainActor @Observable final class TalkIslandModel {
    /// The talk under way, or nil when none is.
    var bar: TalkBar?
    /// Whether the island is on screen; it shrinks away before its panel goes.
    var visible = false
    var hovering = false
    var screen = TalkIsland.Screen.plain
    /// How far below the top of the screen the island's top sits: nothing under a notch, a small gap on a plain screen,
    /// and the depth of another app's bar plus a gap when one covers the top.
    var drop = TalkIsland.floatingGap
    /// The island's drawn size, reported by the view, so clicks beside it pass through and cards sit under it.
    var islandSize: CGSize = .zero
    /// What the agent put on screen that the island keeps: a line of what it just did, its word that it will call back,
    /// or a result such as flights, newest first. The island opens to show a new one for a while, and again under the
    /// pointer.
    var notices: [IslandNotice] = []
    var noticeOpen = false
    /// The agent has been on one step long enough that the island folded down; the step shows beside the notch.
    var settled = false
    /// Set by --render-bar: the time every view draws for, and the moment its timers read.
    var frozenAt: Double?
    var frozenNow: Instant?
    /// The level of whoever is talking, 0 to 1. Read every frame, not observed.
    @ObservationIgnored var level: () -> Double = { 0 }
    @ObservationIgnored var onEnd: () -> Void = {}
    /// Answer and Decline on a call back that is ringing.
    @ObservationIgnored var onAnswer: () -> Void = {}
    @ObservationIgnored var onDecline: () -> Void = {}
    /// A button on a result was pressed: its label, to send as your next words. False when the talk can't take it now.
    @ObservationIgnored var onAction: (String) -> Bool = { _ in false }
    /// The island's drawn size changed.
    @ObservationIgnored var sizeChanged: (() -> Void)?

    var open: Bool { visible && bar.map { TalkIsland.isOpen($0, hovering: hovering, settled: settled) || showsNotices } ?? false }
    /// Whether the notices are on the island now: a new one just came, or the pointer is over it.
    var showsNotices: Bool { !notices.isEmpty && (noticeOpen || hovering) && bar?.phase != .ringing }
    /// Something waits to be read again under the pointer, which a dot on the globe says.
    var keepsNotices: Bool { !notices.isEmpty && !showsNotices && bar?.phase != .ringing }
    /// The step the closed island carries beside the notch.
    var compactStep: TalkStep? { open ? nil : bar.flatMap { TalkIsland.showsStep($0) ? $0.step : nil } }

    /// Presses `label` on the result `key`. A result's buttons work once, and a press the talk can't take, as while it
    /// waits on a permission, leaves them to press again.
    func choose(_ label: String, on key: String) {
        guard let index = notices.firstIndex(where: { $0.key == key }), notices[index].chosen == nil, onAction(label) else { return }
        notices[index].chosen = label
    }
}

/// The island a live talk shows at the top of the screen, in a see-through panel across the top centre that never takes
/// focus and lets clicks through everywhere except over the island. While a talk runs the panel checks the pointer 30
/// times a second, so the island opens under it and its button can be clicked.
@MainActor final class TalkIslandPanel {
    /// Tall enough for the steps and a card of flights under them.
    static let size = NSSize(width: 680, height: 660)
    let model = TalkIslandModel()
    let window: NSPanel
    /// The island's place on screen changed: it opened, closed, or moved to another screen.
    var onMoved: ((NSRect) -> Void)?
    private var pointer: Timer?
    private var hiding: Task<Void, Never>?
    private var noticeClosing: Task<Void, Never>?
    private var noticeExpiry: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    /// Placed on a stand-in screen by --render-bar: shown there, with no pointer watching.
    private var placedByHand = false

    init() {
        window = IslandWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the menu bar, so the island can grow out of the notch.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let host = IslandHost(rootView: IslandRoot(model: model))
        host.sizingOptions = []
        window.contentView = host
        model.sizeChanged = { [weak self] in self?.moved() }
    }

    var isVisible: Bool { window.isVisible }

    /// Where the island is now, in screen coordinates.
    var islandRect: NSRect {
        let size = model.islandSize, frame = window.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - model.drop - size.height, width: size.width, height: size.height)
    }

    /// Shows `bar`, or hides the island for nil. A new talk goes on the screen with the pointer, or on `screen`.
    func show(_ bar: TalkBar?, on screen: NSScreen? = nil) {
        guard let bar else { return hide() }
        hiding?.cancel()
        hiding = nil
        if model.bar == nil || !window.isVisible {
            if !placedByHand { place(on: screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main) }
            window.orderFrontRegardless()
        }
        // Also after a hide that a new talk cut short, which had stopped the watching.
        if !placedByHand { watchPointer() }
        model.bar = bar
        settle()
        if !model.visible { DispatchQueue.main.async { self.model.visible = true } }
    }

    /// Folds the island down once the agent has been on one step for `settleAfter`, and opens it again for the next.
    private func settle() {
        settling?.cancel()
        settling = nil
        let now = model.frozenNow ?? .now
        let settled = model.bar.map { TalkIsland.isSettled($0, at: now) } ?? false
        if model.settled != settled { model.settled = settled }
        guard !settled, let bar = model.bar, bar.phase == .thinking, let since = bar.since, model.frozenNow == nil else { return }
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, since + TalkIsland.settleAfter - now)))
            guard let self, !Task.isCancelled else { return }
            settle()
        }
    }

    /// Takes what the agent put on screen when the island shows it itself: a short line, a result such as flights, or
    /// its word that it will call back. False for anything the cards show instead.
    func take(_ event: TalkCardEvent) -> Bool {
        let content: IslandNotice.Content
        switch event {
        case .show(let card):
            guard let text = TalkIsland.notice(card) else { return false }
            content = .text(text)
        case .result(let card): content = .rich(card)
        case .callBackPromised(let agent): content = .callBack(agent: agent)
        case .permission, .permissionAnswered: return false
        }
        let now = model.frozenNow ?? .now
        model.notices = TalkIsland.adding(content, to: model.notices, at: now)
        model.noticeOpen = true
        noticeClosing?.cancel()
        // Open until the last of them has had its time.
        let until = model.notices.map { $0.added + TalkIsland.noticeHold($0.content) }.max() ?? now
        noticeClosing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, until - now)))
            guard let self, !Task.isCancelled else { return }
            model.noticeOpen = false
        }
        expireNotices()
        return true
    }

    /// Drops each notice once its time is up, whether or not another comes.
    private func expireNotices() {
        noticeExpiry?.cancel()
        let now = model.frozenNow ?? .now
        model.notices.removeAll { now - $0.added >= TalkIsland.noticeLife($0.content) }
        guard let first = model.notices.map({ $0.added + TalkIsland.noticeLife($0.content) }).min() else { return }
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, first - now)))
            guard let self, !Task.isCancelled else { return }
            expireNotices()
        }
    }

    /// Places the panel at the top centre of `area`, a stand-in screen, for --render-bar.
    func place(in area: NSRect, placement: TalkIsland.Placement) {
        placedByHand = true
        (model.screen, model.drop) = (placement.screen, placement.drop)
        window.setFrame(NSRect(x: area.midX - Self.size.width / 2, y: area.maxY - Self.size.height,
                               width: Self.size.width, height: Self.size.height), display: true)
    }

    private func place(on screen: NSScreen?) {
        guard let screen else { return }
        let top = screen.safeAreaInsets.top
        let look: TalkIsland.Screen
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            look = TalkIsland.Screen(hasNotch: true, notchWidth: screen.frame.width - left.width - right.width, barHeight: top)
        } else {
            look = .plain
        }
        let frame = screen.frame
        // Read once per talk: another app's bar across the top, such as a tiling window manager's, would cover the island.
        let placement = TalkIsland.placement(frame: BarRect(frame), screen: look, clear: BarRect(OtherBars.clearOfFrame(screen)))
        (model.screen, model.drop) = (placement.screen, placement.drop)
        window.setFrame(NSRect(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height,
                               width: Self.size.width, height: Self.size.height), display: true)
    }

    private func hide() {
        guard model.bar != nil, hiding == nil else { return }
        pointer?.invalidate()
        pointer = nil
        window.ignoresMouseEvents = true
        if !placedByHand { model.hovering = false }
        model.visible = false
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            // Gone, not just invisible: nothing animates or redraws between talks.
            model.bar = nil
            (model.notices, model.noticeOpen, model.settled) = ([], false, false)
            settling?.cancel()
            window.orderOut(nil)
            hiding = nil
        }
    }

    private func watchPointer() {
        guard pointer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointer = timer
    }

    private func followPointer() {
        let inside = model.visible && islandRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
        if model.hovering != inside { withAnimation(islandSpring) { model.hovering = inside } }
    }

    private func moved() { onMoved?(islandRect) }
}

private final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

private struct IslandRoot: View {
    @Bindable var model: TalkIslandModel

    var body: some View {
        VStack(spacing: 0) {
            if let bar = model.bar {
                IslandView(model: model, bar: bar)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        model.islandSize = size
                        model.sizeChanged?()
                    }
                    .padding(.top, CGFloat(model.drop))
            }
            Spacer(minLength: 0)
        }
        .frame(width: TalkIslandPanel.size.width, height: TalkIslandPanel.size.height, alignment: .top)
    }
}

/// The black island: compact with the globe and the voice in its ears, open with what is being said.
private struct IslandView: View {
    @Bindable var model: TalkIslandModel
    let bar: TalkBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.open, screen = model.screen, step = model.compactStep
        let rim = TalkIsland.edgeColor(TalkIsland.mood(bar.phase)), light = Color(red: rim.red, green: rim.green, blue: rim.blue)
        VStack(spacing: 0) {
            header(open: open)
            if open {
                details
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(islandSpring.delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .frame(width: CGFloat(open ? TalkIsland.openWidth(screen) : TalkIsland.compactWidth(screen, step: step != nil)))
        .padding(.horizontal, screen.hasNotch ? CGFloat(TalkIsland.earCurve) : 0)
        .background { shape(open: open).fill(.black) }
        .clipShape(shape(open: open))
        .overlay { IslandEdge(shape: shape(open: open), notch: screen.hasNotch, light: light) }
        // A glow in the rim's colour lifts it off a black window; the dark shadow lifts it off a light one.
        .background { shape(open: open).fill(.black).shadow(color: light.opacity(TalkIsland.glowOpacity), radius: CGFloat(TalkIsland.glowReach)) }
        .shadow(color: .black.opacity(open ? 0.5 : 0.3), radius: open ? 22 : 10, y: open ? 10 : 4)
        .scaleEffect(model.visible ? 1 : (screen.hasNotch ? 0.55 : 0.7), anchor: .top)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : islandSpring, value: open)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : islandSpring, value: model.visible)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : islandSpring, value: step?.id)
        .animation(.easeInOut(duration: 0.25), value: bar.phase)
    }

    private func shape(open: Bool) -> IslandShape {
        let screen = model.screen, height = CGFloat(screen.barHeight)
        return IslandShape(topCurve: screen.hasNotch ? CGFloat(TalkIsland.earCurve) : 0,
                           topRadius: screen.hasNotch ? 0 : (open ? CGFloat(TalkIsland.openRadius) : height / 2),
                           bottomRadius: open ? CGFloat(TalkIsland.openRadius) : (screen.hasNotch ? CGFloat(TalkIsland.notchRadius) : height / 2))
    }

    private func header(open: Bool) -> some View {
        let screen = model.screen, step = model.compactStep
        let width = open ? TalkIsland.openWidth(screen) : TalkIsland.compactWidth(screen, step: step != nil)
        let center = TalkIsland.centerWidth(screen, step: !open && step != nil)
        let side = CGFloat(width - center) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Globe(model: model, mood: TalkIsland.mood(bar.phase), size: CGFloat(TalkIsland.globeSize(screen)))
                    .overlay(alignment: .topTrailing) {
                        if model.keepsNotices {
                            Circle().fill(Color(red: 0.3, green: 0.9, blue: 0.5))
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                                .offset(x: 2, y: -1)
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityLabel("Results to read again")
                        }
                    }
                if open {
                    Text(TalkIsland.headline(bar))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .offset(x: -6)))
                } else if step != nil, screen.hasNotch {
                    // Beside a notch the step takes the right ear, so the time, or the dots until it shows, sit here.
                    StepTimer(model: model, since: bar.since) { EarView(model: model, ear: .working) }
                        .transition(.opacity)
                }
            }
            .padding(.leading, open ? 18 : (screen.hasNotch ? 10 : 12))
            .frame(width: side, alignment: .leading)

            Group {
                if let step, !screen.hasNotch {
                    StepChip(model: model, step: step)
                } else if !screen.hasNotch && !open {
                    Text(TalkIsland.headline(bar))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(width: CGFloat(center))

            Group {
                if let step, screen.hasNotch {
                    StepChip(model: model, step: step)
                } else if step != nil {
                    StepTimer(model: model, since: bar.since) { EarView(model: model, ear: .working) }
                } else {
                    EarView(model: model, ear: TalkIsland.ear(bar.phase))
                }
            }
            .padding(.trailing, open ? 20 : (screen.hasNotch ? 14 : 18))
            .frame(width: side, alignment: .trailing)
        }
        .frame(height: CGFloat(screen.barHeight))
        .animation(.easeOut(duration: 0.25), value: model.keepsNotices)
    }

    private var details: some View {
        let showsResult = model.showsNotices && model.notices.contains(where: \.isRich)
        return VStack(alignment: .leading, spacing: 10) {
            if bar.phase == .ringing {
                if !bar.line.isEmpty {
                    Text("About \(bar.line)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Text("Double-tap Left Control to answer")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    CallButton(symbol: "phone.down.fill", color: Color(red: 1, green: 0.27, blue: 0.27), label: "Decline") { model.onDecline() }
                    CallButton(symbol: "phone.fill", color: Color(red: 0.2, green: 0.8, blue: 0.4), label: "Answer") { model.onAnswer() }
                }
            } else if bar.endingSoon && bar.phase == .listening {
                Text("Still there? This talk ends soon unless you say something.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else if bar.phase == .thinking {
                if !bar.line.isEmpty {
                    Text(bar.line)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                StepRows(model: model, bar: bar)
            } else if bar.phase == .speaking && !bar.line.isEmpty {
                Text(bar.line)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    // A result under it needs the room.
                    .lineLimit(showsResult ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(bar.line)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            if model.showsNotices {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.notices) { NoticeView(model: model, notice: $0, working: bar.phase == .thinking) }
                }
                .padding(.top, TalkIsland.isOpen(bar, hovering: false, settled: model.settled) ? 4 : 0)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if model.hovering && bar.phase != .ringing {
                HStack(spacing: 12) {
                    Text(TalkIsland.endHint)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    Spacer()
                    EndButton { model.onEnd() }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: bar.line)
        .animation(.easeOut(duration: 0.3), value: model.notices)
        .animation(.easeOut(duration: 0.3), value: model.showsNotices)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rectangle whose top corners curve outward into the screen edge, like the notch, with round bottom corners. With no
/// curve it is a rounded rectangle.
private struct IslandShape: Shape {
    var topCurve: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(topCurve, .init(topRadius, bottomRadius)) }
        set { (topCurve, topRadius, bottomRadius) = (newValue.first, newValue.second.first, newValue.second.second) }
    }

    func path(in r: CGRect) -> Path {
        let c = topCurve
        let body = CGRect(x: r.minX + c, y: r.minY, width: r.width - 2 * c, height: r.height)
        let b = min(bottomRadius, body.height / 2, body.width / 2)
        let t = min(topRadius, body.height / 2, body.width / 2)
        var p = Path()
        if c > 0 {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: body.minX, y: r.minY + c), control: CGPoint(x: body.minX, y: r.minY))
        } else {
            p.move(to: CGPoint(x: body.minX, y: body.minY + t))
            p.addQuadCurve(to: CGPoint(x: body.minX + t, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
            p.addLine(to: CGPoint(x: body.maxX - t, y: body.minY))
            p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + t), control: CGPoint(x: body.maxX, y: body.minY))
        }
        if c > 0 {
            p.addLine(to: CGPoint(x: body.minX, y: body.maxY - b))
            p.addQuadCurve(to: CGPoint(x: body.minX + b, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
            p.addLine(to: CGPoint(x: body.maxX - b, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - b), control: CGPoint(x: body.maxX, y: body.maxY))
            p.addLine(to: CGPoint(x: body.maxX, y: r.minY + c))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: body.maxX, y: r.minY))
        } else {
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - b))
            p.addQuadCurve(to: CGPoint(x: body.maxX - b, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY))
            p.addLine(to: CGPoint(x: body.minX + b, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - b), control: CGPoint(x: body.minX, y: body.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// The island's edge, so it reads on a black window: a rim of light in the mood's colour, brightest along the top.
/// Under a notch the top edge is the screen's, so the line starts below it.
private struct IslandEdge: View {
    let shape: IslandShape
    let notch: Bool
    let light: Color

    var body: some View {
        shape
            // Half of a stroke falls outside the shape and is clipped away, so it is drawn twice as wide.
            .stroke(LinearGradient(colors: [light.opacity(TalkIsland.edgeBrightest), light.opacity(TalkIsland.edgeFaintest)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 2 * CGFloat(TalkIsland.edgeWidth))
            .clipShape(shape)
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: notch ? 3 : 0)
                    Color.black
                }
            }
            .allowsHitTesting(false)
    }
}

/// Redraws at most 60 times a second, or once at the time --render-bar froze, or once with Reduce Motion.
struct IslandClock<Content: View>: View {
    let model: TalkIslandModel
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let frozen = model.frozenAt {
            content(frozen)
        } else if reduceMotion {
            content(0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in content(context.date.timeIntervalSinceReferenceDate) }
        }
    }
}

/// The agent's globe: a grid of dots, like ASCII art, that turns and floats. Its colours say what is happening, the land
/// drifts past faster while the agent works, and the voice swells it, brightens it and sends ripples across it.
private struct Globe: View {
    let model: TalkIslandModel
    let mood: TalkIsland.Mood
    let size: CGFloat

    var body: some View {
        let colors = TalkIsland.orbColors(mood).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        IslandClock(model: model) { time in
            let level = model.level()
            Canvas { context, canvas in
                let grid = TalkIsland.globeGrid, cell = canvas.width / CGFloat(grid)
                for dot in TalkIsland.globeDots(time: time, level: level, mood: mood, grid: grid) {
                    let diameter = cell * CGFloat(dot.size)
                    let center = CGPoint(x: (CGFloat(dot.column) + 0.5) * cell, y: (CGFloat(dot.row) + 0.5) * cell)
                    let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: rect), with: .color(Self.tint(colors, dot.tint).opacity(dot.brightness)))
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(TalkIsland.globeScale(level: level, mood: mood, time: time))
            .shadow(color: colors[0].opacity(0.55), radius: 3 + level * 6)
            .offset(y: CGFloat(TalkIsland.globeFloat(time: time)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The colour `at` of the way around the mood's three, 0 to 3, blended between neighbours.
    private static func tint(_ colors: [Color], _ at: Double) -> Color {
        let index = Int(at) % colors.count, next = (index + 1) % colors.count
        return colors[index].mix(with: colors[next], by: at - floor(at))
    }
}

/// The right ear: bars that move with the voice while someone talks, three rising dots while the agent works.
struct EarView: View {
    let model: TalkIslandModel
    let ear: TalkIsland.Ear

    var body: some View {
        IslandClock(model: model) { time in
            switch ear {
            case .working:
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        let lift = TalkIsland.dotLift(index: index, time: time)
                        Circle().fill(.white.opacity(0.45 + 0.5 * lift)).frame(width: 5, height: 5).offset(y: -2.5 * lift)
                    }
                }
            case .voice(let agent):
                let level = model.level()
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule().fill(agent ? Color(red: 1, green: 0.78, blue: 0.4) : .white)
                            .frame(width: 3, height: CGFloat(TalkIsland.barHeight(index: index, level: level, time: time)))
                    }
                }
            }
        }
        .frame(height: CGFloat(TalkIsland.barTallest))
    }
}

/// A round button to answer or decline a call back.
private struct CallButton: View {
    let symbol: String
    let color: Color
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(color))
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = inside } }
    }
}

private struct EndButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help("End the talk")
        .accessibilityLabel("End the talk")
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = inside } }
    }
}
