import AppKit
import DictationCore
import SwiftUI

/// The icons of the apps the agent's steps use, read from the apps on this Mac once each.
@MainActor enum AppIcons {
    private static var found: [StepApp: NSImage?] = [:]

    /// The app's own icon, or nil when it isn't installed or the step's app has none, such as Gmail.
    static func icon(_ app: StepApp) -> NSImage? {
        if let known = found[app] { return known }
        let image = location(app).map { NSWorkspace.shared.icon(forFile: $0.path) }
        found[app] = image
        return image
    }

    private static func location(_ app: StepApp) -> URL? {
        let workspace = NSWorkspace.shared
        // The browser is whichever one opens links here.
        if app == .browser { return URL(string: "https://example.com").flatMap { workspace.urlForApplication(toOpen: $0) } }
        for id in app.bundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let folders = [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for name in app.appNames {
            for folder in folders {
                let url = folder.appending(path: "\(name).app")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

private let islandGreen = Color(red: 0.3, green: 0.9, blue: 0.5)
private let islandAmber = Color(red: 1, green: 0.72, blue: 0.3)

/// A step's icon: the app's own when it uses one that is installed, a tile in the app's colour when it isn't, and a
/// plain tile with a symbol for the kind of step otherwise.
struct StepIcon: View {
    let app: StepApp?
    let line: String
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let app, let image = AppIcons.icon(app) {
                // An app icon keeps a clear margin inside its square, so it is drawn a little past the tile's size.
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size * 1.16, height: size * 1.16)
                    .frame(width: size, height: size)
            } else if let app {
                tile(app.symbol, fill: Color(red: app.tint.red, green: app.tint.green, blue: app.tint.blue), mark: .white)
            } else {
                tile(ToolLine.symbol(line), fill: .white.opacity(0.09), mark: .white.opacity(0.75))
            }
        }
        .accessibilityHidden(true)
    }

    private func tile(_ symbol: String, fill: Color, mark: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(mark)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// Text with a light sweeping across it, for what is under way.
struct ShimmerText: View {
    let model: TalkIslandModel
    let text: String
    var size: CGFloat = 16

    var body: some View {
        IslandClock(model: model) { time in
            let sweep = (time * 0.7).truncatingRemainder(dividingBy: 1.6) - 0.3
            let dim = Color.white.opacity(0.45)
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(LinearGradient(stops: [.init(color: dim, location: sweep - 0.25), .init(color: .white, location: sweep),
                                                        .init(color: dim, location: sweep + 0.25)],
                                                startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// How long the step on show has run, once that is long enough to matter, and `waiting` until then. It ticks once a
/// second, also with Reduce Motion, since a clock that stands still reads as stuck.
struct StepTimer<Waiting: View>: View {
    let model: TalkIslandModel
    let since: Instant?
    /// A ring that turns beside the time.
    var ring = false
    @ViewBuilder let waiting: () -> Waiting

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = model.frozenNow ?? .now
            if let since, now - since >= TalkIsland.timerFrom {
                HStack(spacing: 7) {
                    Text(TalkIsland.elapsed(now - since))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("Running for \(TalkIsland.elapsed(now - since))")
                    if ring { WorkRing(model: model) }
                }
            } else {
                waiting()
            }
        }
    }
}

/// A ring that turns while a long step runs.
private struct WorkRing: View {
    let model: TalkIslandModel

    var body: some View {
        IslandClock(model: model) { time in
            Circle().trim(from: 0, to: 0.3)
                .stroke(islandAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 1.2) * 300))
                .background(Circle().stroke(.white.opacity(0.12), lineWidth: 2))
                .frame(width: 13, height: 13)
        }
        .accessibilityHidden(true)
    }
}

/// The step the closed island carries: its icon and a word or two.
struct StepChip: View {
    let model: TalkIslandModel
    let step: TalkStep

    var body: some View {
        HStack(spacing: 6) {
            StepIcon(app: step.app, line: step.line, size: 18)
            Text(ToolLine.short(step.line))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .id(step.id)
        .transition(.opacity.combined(with: .offset(y: 4)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.line)
    }
}

/// What the agent is doing this turn: the steps it finished, small and checked, and under them the one it is on, with a
/// light across it and, once it has run a while, how long.
struct StepRows: View {
    let model: TalkIslandModel
    let bar: TalkBar

    var body: some View {
        // An activity that is no step of the work, such as waiting for your OK, shows as a row of its own.
        let current = bar.step ?? bar.activity.map { TalkStep(line: $0) }
        VStack(alignment: .leading, spacing: 7) {
            if bar.step != nil {
                ForEach(bar.trail) { step in
                    PastStep(step: step)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            if let current {
                HStack(spacing: 10) {
                    StepIcon(app: current.app, line: current.line)
                    if current.failed {
                        Text(current.line)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        FailedMark()
                    } else {
                        ShimmerText(model: model, text: current.line)
                        Spacer(minLength: 8)
                        if bar.step != nil { StepTimer(model: model, since: bar.since, ring: true) { EmptyView() } }
                    }
                }
                .id(current.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(current.failed ? "\(current.line), didn't work" : current.line)
            }
        }
        .animation(.easeOut(duration: 0.28), value: current?.id)
        .animation(.easeOut(duration: 0.28), value: bar.trail)
    }
}

private struct FailedMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
            Text("didn't work").font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(islandAmber)
    }
}

/// A step that is over: small and dim, in the past tense, with a check, or a mark when its tool failed.
private struct PastStep: View {
    let step: TalkStep

    var body: some View {
        HStack(spacing: 10) {
            StepIcon(app: step.app, line: step.line, size: 18)
                .opacity(0.75)
                .frame(width: 26)
            Text(step.failed ? step.line : ToolLine.done(step.line))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 8)
            if step.failed {
                FailedMark()
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(islandGreen.opacity(0.85))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.failed ? "\(step.line), didn't work" : ToolLine.done(step.line))
    }
}

/// One thing the island keeps under its header: a line of what the agent did, its word that it will call back, or a
/// result it draws.
struct NoticeView: View {
    let model: TalkIslandModel
    let notice: IslandNotice
    /// The agent is still working, so a result may grow.
    let working: Bool

    var body: some View {
        switch notice.content {
        case .text(let text):
            row(symbol: "checkmark", title: nil, text: text)
        case .callBack(let agent):
            row(symbol: "phone.arrow.up.right.fill", title: "\(agent) will call you back when it's done", text: "You can hang up. It rings here.")
        case .rich(let card):
            VStack(alignment: .leading, spacing: 10) {
                switch card.body {
                case .flights(let flights): FlightsView(model: model, flights: flights, working: working)
                case .rows(let rows): ResultRows(rows: rows)
                }
                if !card.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(card.actions.enumerated()), id: \.element) { index, label in
                            ActionButton(label: label, primary: index == 0, chosen: notice.chosen) { model.choose(label, on: notice.key) }
                        }
                    }
                }
            }
        }
    }

    /// A green mark in the step icon's style, and the words.
    private func row(symbol: String, title: String?, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.45, green: 0.95, blue: 0.6))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(islandGreen.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text)
                    .font(.system(size: title == nil ? 14 : 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(title == nil ? 0.88 : 0.5))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, title == nil ? 4 : 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A button on a result. Pressing it says its label to the agent as your next words, once.
private struct ActionButton: View {
    let label: String
    let primary: Bool
    /// The label already pressed on this result, if any.
    let chosen: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let picked = chosen == label
        Button(action: action) {
            HStack(spacing: 5) {
                if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(label).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(chosen != nil && !picked ? 0.4 : 1))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(fill(picked: picked)))
            .scaleEffect(hover && chosen == nil ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(chosen != nil)
        .accessibilityLabel(picked ? "\(label), sent" : label)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = inside } }
        .animation(.easeOut(duration: 0.2), value: chosen)
    }

    private func fill(picked: Bool) -> Color {
        if picked { return islandGreen.opacity(0.28) }
        if chosen != nil { return .white.opacity(0.06) }
        return primary ? Color(red: 0.2, green: 0.5, blue: 1) : .white.opacity(hover ? 0.2 : 0.13)
    }
}

/// A row that opens its link on a click, and lights under the pointer when it has one.
private struct LinkRow<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(hover && url != nil ? 0.07 : 0))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
            .accessibilityAddTraits(url == nil ? [] : .isLink)
    }
}

private struct RowDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 12) }
}

private extension View {
    /// The card a result's rows sit in, a shade lighter than the island.
    func resultCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Flights for a route: the route on top, then each option as it comes, the best one marked.
private struct FlightsView: View {
    let model: TalkIslandModel
    let flights: Flights
    let working: Bool
    /// How many options have come in to view; they arrive one after another.
    @State private var revealed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(flights.from)
                    Image(systemName: "airplane").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(flights.to)
                }
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Flights from \(flights.from) to \(flights.to)")
                if !flights.subtitle.isEmpty {
                    Text(flights.subtitle).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            if !flights.options.isEmpty || working {
                VStack(spacing: 0) {
                    ForEach(Array(flights.options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { RowDivider().opacity(index < revealed ? 1 : 0) }
                        LinkRow(url: option.url) { row(option) }
                            .opacity(index < revealed ? 1 : 0)
                            .offset(y: index < revealed ? 0 : 6)
                    }
                    if working {
                        if !flights.options.isEmpty { RowDivider() }
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                            ShimmerText(model: model, text: "Looking for more…", size: 13)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .resultCard()
            }
        }
        .task(id: flights.options.count) {
            let count = flights.options.count
            if reduceMotion || model.frozenAt != nil || revealed > count { revealed = count }
            while revealed < count {
                try? await Task.sleep(for: .milliseconds(revealed == 0 ? 120 : 260))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { revealed += 1 }
            }
        }
    }

    private func row(_ option: FlightOption) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("\(option.depart) → \(option.arrive)").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                    if option.best {
                        Text("Best")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.95, blue: 0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(islandGreen.opacity(0.16)))
                    }
                }
                if !option.detail.isEmpty {
                    Text(option.detail).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let price = option.price {
                Text(price).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(option.best ? Color(red: 0.45, green: 0.95, blue: 0.6) : .white.opacity(0.9))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the agent found or made, a row each: a task with its state, a meeting with its date, an email with who sent it.
private struct ResultRows: View {
    let rows: [ResultRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { RowDivider() }
                LinkRow(url: row.url) {
                    HStack(spacing: 12) {
                        lead(row).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                            if !row.detail.isEmpty {
                                Text(row.detail).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        // A task keeps its circle in front, so the app it lives in goes at the end.
                        if case .task = row.kind, let app = row.app { StepIcon(app: app, line: "", size: 18) }
                        if row.url != nil {
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .resultCard()
    }

    @ViewBuilder private func lead(_ row: ResultRow) -> some View {
        switch row.kind {
        case .task(let done):
            if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 21)).foregroundStyle(islandGreen)
            } else {
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.8).frame(width: 20, height: 20)
            }
        case .event(let month, let day) where !day.isEmpty:
            VStack(spacing: 0) {
                Text(month).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 11).background(Color(red: 0.95, green: 0.3, blue: 0.28))
                Text(day).font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .event, .email, .item:
            StepIcon(app: row.app, line: row.kind == .item ? "Reading" : "", size: 28)
        }
    }
}
