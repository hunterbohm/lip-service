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
    /// The island's drawn size, reported by the view, so clicks beside it pass through and cards sit under it.
    var islandSize: CGSize = .zero
    /// Set by --render-bar: the time every view draws for.
    var frozenAt: Double?
    /// The level of whoever is talking, 0 to 1. Read every frame, not observed.
    @ObservationIgnored var level: () -> Double = { 0 }
    @ObservationIgnored var onEnd: () -> Void = {}
    /// The island's drawn size changed.
    @ObservationIgnored var sizeChanged: (() -> Void)?

    var open: Bool { visible && bar.map { TalkIsland.isOpen($0, hovering: hovering) } ?? false }
}

/// The island a live talk shows at the top of the screen, in a see-through panel across the top centre that never takes
/// focus and lets clicks through everywhere except over the island. While a talk runs the panel checks the pointer 30
/// times a second, so the island opens under it and its button can be clicked.
@MainActor final class TalkIslandPanel {
    static let size = NSSize(width: 680, height: 360)
    let model = TalkIslandModel()
    let window: NSPanel
    /// The island's place on screen changed: it opened, closed, or moved to another screen.
    var onMoved: ((NSRect) -> Void)?
    private var pointer: Timer?
    private var hiding: Task<Void, Never>?
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
        let top = model.screen.hasNotch ? 0 : TalkIsland.floatingGap
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - top - size.height, width: size.width, height: size.height)
    }

    /// Shows `bar`, or hides the island for nil. A new talk goes on the screen with the pointer, or on `screen`.
    func show(_ bar: TalkBar?, on screen: NSScreen? = nil) {
        guard let bar else { return hide() }
        hiding?.cancel()
        hiding = nil
        if model.bar == nil || !window.isVisible {
            if !placedByHand {
                place(on: screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
                watchPointer()
            }
            window.orderFrontRegardless()
        }
        model.bar = bar
        if !model.visible { DispatchQueue.main.async { self.model.visible = true } }
    }

    /// Places the panel at the top centre of `area`, a stand-in screen, for --render-bar.
    func place(in area: NSRect, screen: TalkIsland.Screen) {
        placedByHand = true
        model.screen = screen
        window.setFrame(NSRect(x: area.midX - Self.size.width / 2, y: area.maxY - Self.size.height,
                               width: Self.size.width, height: Self.size.height), display: true)
    }

    private func place(on screen: NSScreen?) {
        guard let screen else { return }
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.screen = TalkIsland.Screen(hasNotch: true, notchWidth: screen.frame.width - left.width - right.width, barHeight: top)
        } else {
            model.screen = .plain
        }
        let frame = screen.frame
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
                    .padding(.top, model.screen.hasNotch ? 0 : TalkIsland.floatingGap)
            }
            Spacer(minLength: 0)
        }
        .frame(width: TalkIslandPanel.size.width, height: TalkIslandPanel.size.height, alignment: .top)
    }
}

/// The black island: compact with the orb and the voice in its ears, open with what is being said.
private struct IslandView: View {
    @Bindable var model: TalkIslandModel
    let bar: TalkBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.open, screen = model.screen
        VStack(spacing: 0) {
            header(open: open)
            if open {
                details
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(islandSpring.delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .frame(width: CGFloat(open ? TalkIsland.openWidth(screen) : TalkIsland.compactWidth(screen)))
        .padding(.horizontal, screen.hasNotch ? CGFloat(TalkIsland.earCurve) : 0)
        .background { shape(open: open).fill(.black) }
        .clipShape(shape(open: open))
        .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 22, y: 10)
        .scaleEffect(model.visible ? 1 : (screen.hasNotch ? 0.55 : 0.7), anchor: .top)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : islandSpring, value: open)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : islandSpring, value: model.visible)
        .animation(.easeInOut(duration: 0.25), value: bar.phase)
    }

    private func shape(open: Bool) -> IslandShape {
        let screen = model.screen, height = CGFloat(screen.barHeight)
        return IslandShape(topCurve: screen.hasNotch ? CGFloat(TalkIsland.earCurve) : 0,
                           topRadius: screen.hasNotch ? 0 : (open ? CGFloat(TalkIsland.openRadius) : height / 2),
                           bottomRadius: open ? CGFloat(TalkIsland.openRadius) : (screen.hasNotch ? CGFloat(TalkIsland.notchRadius) : height / 2))
    }

    private func header(open: Bool) -> some View {
        let screen = model.screen
        let side = CGFloat((open ? TalkIsland.openWidth(screen) : TalkIsland.compactWidth(screen)) - TalkIsland.centerWidth(screen)) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Orb(model: model, mood: TalkIsland.mood(bar.phase), size: open ? 20 : 18)
                if open {
                    Text(TalkIsland.headline(bar))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            .padding(.leading, open ? 16 : 12)
            .frame(width: side, alignment: .leading)

            Group {
                if !screen.hasNotch && !open {
                    Text(TalkIsland.headline(bar))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(width: CGFloat(TalkIsland.centerWidth(screen)))

            EarView(model: model, ear: TalkIsland.ear(bar.phase))
                .padding(.trailing, open ? 18 : 12)
                .frame(width: side, alignment: .trailing)
        }
        .frame(height: CGFloat(screen.barHeight))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if bar.endingSoon && bar.phase == .listening {
                Text("Still there? This talk ends soon unless you say something.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else if bar.phase == .thinking {
                if !bar.line.isEmpty {
                    Text(bar.line)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ThinkingText(model: model, text: bar.activity ?? "Thinking")
                    .id(bar.activity ?? "")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            } else if bar.phase == .speaking && !bar.line.isEmpty {
                Text(bar.line)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(bar.line)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            if model.hovering {
                HStack {
                    Spacer()
                    EndButton { model.onEnd() }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: bar.line)
        .animation(.easeOut(duration: 0.25), value: bar.activity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
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

/// Redraws at most 60 times a second, or once at the time --render-bar froze, or once with Reduce Motion.
private struct IslandClock<Content: View>: View {
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

/// The agent's living orb: its colours say what is happening, and it swells with the voice.
private struct Orb: View {
    let model: TalkIslandModel
    let mood: TalkIsland.Mood
    let size: CGFloat

    var body: some View {
        let colors = TalkIsland.orbColors(mood).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        IslandClock(model: model) { time in
            let level = model.level()
            ZStack {
                Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center,
                                              angle: .radians(time * TalkIsland.orbSpeed(mood))))
                    .blur(radius: size * 0.14)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.85), .clear],
                                             center: UnitPoint(x: 0.34, y: 0.3), startRadius: 0, endRadius: size * 0.55))
                    .blendMode(.plusLighter)
                    .opacity(0.55)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .scaleEffect(TalkIsland.orbScale(level: level, mood: mood, time: time))
            .shadow(color: colors[0].opacity(0.75), radius: 5 + level * 6)
        }
        .frame(width: size, height: size)
    }
}

/// The right ear: bars that move with the voice while someone talks, three rising dots while the agent works.
private struct EarView: View {
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

/// The agent's activity, with a light sweeping across it.
private struct ThinkingText: View {
    let model: TalkIslandModel
    let text: String

    var body: some View {
        IslandClock(model: model) { time in
            let sweep = (time * 0.7).truncatingRemainder(dividingBy: 1.6) - 0.3
            let dim = Color.white.opacity(0.3)
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LinearGradient(stops: [.init(color: dim, location: sweep - 0.25), .init(color: .white, location: sweep),
                                                        .init(color: dim, location: sweep + 0.25)],
                                                startPoint: .leading, endPoint: .trailing))
        }
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
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help("End the talk")
        .accessibilityLabel("End the talk")
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = inside } }
    }
}
