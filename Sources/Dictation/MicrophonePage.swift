import AVFoundation
import DictationCore
import SwiftUI

struct MicrophonePage: View {
    let services: WindowServices

    var body: some View {
        let preferences = services.preferences
        let choice = preferences.current.settings.microphone
        let order = preferences.current.settings.automaticOrder
        let inputs = services.inputs
        let source = inputs.inUse(choice, order: order)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Microphone")
                if let missing = source.missing {
                    Notice(tone: .warning, title: "\(missing) isn't connected", detail: "Using \(source.name) until it's back.")
                        .padding(.bottom, 18)
                }
                VStack(spacing: 0) {
                    ForEach(Array(options(choice, inputs, order).enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Theme.line.frame(height: 1) }
                        OptionRow(option: option, chosen: option.choice == choice) {
                            preferences.change { $0.microphone = option.choice }
                        }
                    }
                }
                .frame(maxWidth: 680)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
                if choice == .automatic {
                    AutomaticOrderSection(order: order, inputs: inputs, preferences: preferences)
                        .padding(.top, 28)
                }
                HStack(spacing: 16) {
                    Text("Input level").font(.system(size: 13.5)).foregroundStyle(Theme.secondary).frame(width: 88, alignment: .leading)
                    LevelMeter(value: services.level.value)
                }
                .frame(maxWidth: 680)
                .padding(.top, 24)
                .help("Speak to see the level of \(source.name).")
            }
            .page()
        }
        .onAppear { services.level.start(choice) }
        .onDisappear { services.level.stop() }
        // The device, not the choice, because Automatic and System Default move to another device as they come and go.
        .onChange(of: source.uid) { services.level.start(choice) }
    }

    private func options(_ choice: MicrophoneChoice, _ inputs: Inputs, _ order: AutomaticOrder) -> [Option] {
        let defaultName = inputs.systemDefault?.name
        let rule = order.isDefault ? "A wired mic, then your Mac's, then Bluetooth" : "The first connected one in your order"
        var options = [
            Option(choice: .automatic, name: "Automatic",
                   detail: "\(rule). Now \(inputs.inUse(.automatic, order: order).name)"),
            Option(choice: .systemDefault, name: "System Default",
                   detail: defaultName.map { "Follows your Mac's sound settings, now \($0)" } ?? "Follows your Mac's sound settings"),
        ]
        options += inputs.all.map { input in
            let detail: String? = if input.kind == .bluetooth {
                "Slow to start, and lowers your headphones' sound while it records"
            } else if input.uid == inputs.systemDefault?.uid { "Your Mac's default" } else { nil }
            return Option(choice: .device(uid: input.uid, name: input.name), name: input.name, detail: detail)
        }
        if case .device(let uid, let name) = choice, !inputs.all.contains(where: { $0.uid == uid }) {
            options.append(Option(choice: choice, name: name, detail: "Not connected", missing: true))
        }
        return options
    }
}

private struct Option: Identifiable {
    var id: String {
        switch choice {
        case .automatic: "automatic"
        case .systemDefault: ""
        case .device(let uid, _): uid
        }
    }
    let choice: MicrophoneChoice
    let name: String
    let detail: String?
    var missing = false
}

private struct OptionRow: View {
    let option: Option
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .strokeBorder(chosen ? Theme.blue : Theme.text.opacity(0.45), lineWidth: chosen ? 6.5 : 1.5)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).font(.system(size: 15, weight: .medium))
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(option.missing ? Theme.amber : Theme.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(chosen ? Color(hex: 0x262A35) : hovering ? Theme.raised : Theme.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LevelMeter: View {
    let value: Float
    static let segments = 16

    var body: some View {
        let lit = Int((value * Float(Self.segments)).rounded())
        HStack(spacing: 5) {
            ForEach(0..<Self.segments, id: \.self) { index in
                Capsule().fill(index < lit ? Theme.green : Theme.raised).frame(height: 8)
            }
        }
        .animation(.easeOut(duration: 0.08), value: lit)
    }
}

/// The input devices, read again while the window is open, since they come and go.
@MainActor @Observable final class Inputs {
    /// The microphones as Automatic's order sees them.
    var choiceInputs: [MicrophoneInput] { all.map(\.choiceInput) }

    private(set) var all: [AudioDevices.Input] = []
    private(set) var systemDefault: AudioDevices.Input?
    private(set) var lidClosed = false
    @ObservationIgnored private let read: @MainActor () -> (all: [AudioDevices.Input], systemDefault: AudioDevices.Input?, lidClosed: Bool)

    init(read: @escaping @MainActor () -> (all: [AudioDevices.Input], systemDefault: AudioDevices.Input?, lidClosed: Bool) = {
        let all = AudioDevices.inputs()
        return (all, AudioDevices.defaultInput(among: all), AudioDevices.lidClosed())
    }) {
        self.read = read
        refresh()
    }

    func refresh() {
        let next = read()
        if next.all != all { all = next.all }
        if next.systemDefault != systemDefault { systemDefault = next.systemDefault }
        if next.lidClosed != lidClosed { lidClosed = next.lidClosed }
    }

    /// The device a dictation would record from now, and the chosen one when it is missing.
    func inUse(_ choice: MicrophoneChoice, order: AutomaticOrder) -> (name: String, uid: String?, missing: String?) {
        let fallback = systemDefault?.name ?? "no microphone"
        return switch choice.source(among: all.map(\.choiceInput), systemDefault: systemDefault?.uid, lidClosed: lidClosed, order: order) {
        case .systemDefault: (fallback, systemDefault?.uid, nil)
        case .device(let uid): (all.first { $0.uid == uid }?.name ?? fallback, uid, nil)
        case .fallback(let missing): (fallback, systemDefault?.uid, missing)
        }
    }
}

/// The level on the Microphone page. It records only while that page shows, with its own engine, because dictation
/// keeps none running between dictations.
@MainActor @Observable final class InputLevel {
    private(set) var value: Float
    @ObservationIgnored private let tap: LevelTap?

    init() {
        value = 0
        tap = LevelTap()
    }

    /// For rendering: a fixed level and no microphone.
    init(fixed: Float) {
        value = fixed
        tap = nil
    }

    func start(_ choice: MicrophoneChoice) {
        tap?.start(choice) { level in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.value = level }
            }
        }
    }

    func stop() {
        guard let tap else { return }
        tap.stop()
        value = 0
    }
}

/// AVAudioEngine, touched only on `queue`, since starting one can block for hundreds of milliseconds.
private final class LevelTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hunterbohm.dictation.level", qos: .userInitiated)
    private var engine: AVAudioEngine?

    func start(_ choice: MicrophoneChoice, report: @escaping @Sendable (Float) -> Void) {
        queue.async { [self] in
            end()
            let engine = AVAudioEngine()
            // Bound to the device even on System Default, so the page restarts the meter when the device in use changes.
            let inputs = AudioDevices.inputs()
            if let input = AudioDevices.input(for: AudioDevices.source(for: choice, among: inputs), among: inputs) {
                _ = AudioDevices.select(input.deviceID, for: engine)
            }
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }
            do {
                try node.installTapOrThrow(bufferSize: 2048, format: nil) { buffer, _ in
                    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                    let count = Int(buffer.frameLength)
                    var sum: Float = 0
                    for index in 0..<count { sum += samples[index] * samples[index] }
                    report(Loudness.fraction(rms: (sum / Float(count)).squareRoot()))
                }
            } catch { return }
            engine.prepare()
            do {
                try engine.start()
                self.engine = engine
            } catch {
                node.removeTap(onBus: 0)
            }
        }
    }

    func stop() { queue.async { [self] in end() } }

    private func end() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

/// Automatic's order: the microphones it picks from, first choice first. Drag a row by its handle, or use the arrows.
private struct AutomaticOrderSection: View {
    let order: AutomaticOrder
    let inputs: Inputs
    let preferences: Preferences

    var body: some View {
        let listed = order.listed(among: inputs.choiceInputs, systemDefault: inputs.systemDefault?.uid)
        let picked = inputs.inUse(.automatic, order: order)
        let rows = listed.map { device -> OrderRow in
            let input = inputs.all.first { $0.uid == device.uid }
            let detail: (text: String, amber: Bool) = switch (input?.kind, inputs.lidClosed) {
            case (nil, _): ("Not connected", true)
            case (.builtIn, true): ("Skipped while the lid is closed", true)
            case (.bluetooth, _): ("Bluetooth, slow to start", false)
            case (.builtIn, false): ("This Mac", false)
            default: ("Wired", false)
            }
            return OrderRow(device: device, detail: detail.text, amber: detail.amber, connected: input != nil,
                            inUse: input != nil && picked.missing == nil && picked.uid == device.uid)
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                SectionHeader(title: "Automatic order",
                              detail: order.isDefault
                                  ? "Drag to choose which microphone Automatic tries first. Until you do, it takes a wired one, then your Mac's, then Bluetooth."
                                  : "Automatic uses the first of these that's connected. A microphone you plug in later goes to the bottom until you move it.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !order.isDefault {
                    Button("Reset") { preferences.change { $0.automaticOrder = AutomaticOrder() } }
                        .buttonStyle(DarkButtonStyle())
                        .help("Go back to a wired one, then your Mac's, then Bluetooth")
                }
            }
            if rows.isEmpty {
                Notice(tone: .info, title: "No microphone to choose from", detail: "Automatic uses the system default.")
            } else {
                OrderList(rows: rows, move: { from, to in
                    preferences.change {
                        $0.automaticOrder = $0.automaticOrder.moving(from: from, to: to, among: inputs.choiceInputs,
                                                                     systemDefault: inputs.systemDefault?.uid)
                    }
                }, forget: { uid in preferences.change { $0.automaticOrder = $0.automaticOrder.forgetting(uid) } })
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

private struct OrderRow: Identifiable {
    var id: String { device.uid }
    let device: AutomaticOrder.Device
    let detail: String
    let amber: Bool
    let connected: Bool
    let inUse: Bool
}

private struct OrderList: View {
    static let rowHeight: CGFloat = 56

    let rows: [OrderRow]
    let move: (_ from: Int, _ to: Int) -> Void
    let forget: (String) -> Void
    @State private var dragging: String?
    @State private var offset: CGFloat = 0

    /// Where the dragged row would land if let go now.
    private var target: Int? {
        guard let dragging, let from = rows.firstIndex(where: { $0.id == dragging }) else { return nil }
        return AutomaticOrder.dropPlace(from: from, translation: offset, rowHeight: Self.rowHeight, count: rows.count)
    }

    var body: some View {
        let from = dragging.flatMap { id in rows.firstIndex { $0.id == id } }
        let target = target
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isDragged = row.id == dragging
                // The other rows make room: the ones between the drag's start and its target shift by one place.
                let place = if let from, let target, !isDragged {
                    index > from && index <= target ? index - 1 : index < from && index >= target ? index + 1 : index
                } else { index }
                let lifted = isDragged ? min(max(CGFloat(index) * Self.rowHeight + offset, 0), CGFloat(rows.count - 1) * Self.rowHeight)
                    : CGFloat(place) * Self.rowHeight
                OrderRowView(row: row, number: (isDragged ? target ?? index : place) + 1, lifted: isDragged,
                             canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                             up: { move(index, index - 1) }, down: { move(index, index + 1) }, forget: { forget(row.id) },
                             dragged: { offset in dragChanged(row.id, offset) }, dropped: { dropped(row.id) })
                    .offset(y: lifted)
                    .zIndex(isDragged ? 1 : 0)
                    .animation(isDragged ? nil : .snappy(duration: 0.18), value: place)
            }
        }
        .frame(height: CGFloat(rows.count) * Self.rowHeight, alignment: .top)
        .coordinateSpace(name: "order")
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    private func dragChanged(_ id: String, _ translation: CGFloat) {
        if dragging == nil { dragging = id }
        if dragging == id { offset = translation }
    }

    private func dropped(_ id: String) {
        let from = rows.firstIndex { $0.id == id }, to = target
        dragging = nil
        offset = 0
        if let from, let to, from != to { move(from, to) }
    }
}

private struct OrderRowView: View {
    let row: OrderRow
    let number: Int
    let lifted: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let up: () -> Void
    let down: () -> Void
    let forget: () -> Void
    let dragged: (CGFloat) -> Void
    let dropped: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.system(size: 13.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                .frame(width: 16)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(lifted || hovering ? Theme.secondary : Theme.tertiary)
                .frame(width: 22, height: 36)
                .contentShape(Rectangle())
                // In the list's space, not the row's own, which moves with the drag.
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("order"))
                    .onChanged { dragged($0.translation.height) }
                    .onEnded { _ in dropped() })
                .help("Drag to reorder")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.device.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(row.detail).font(.system(size: 12.5)).foregroundStyle(row.amber ? Theme.amber : Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.inUse {
                HStack(spacing: 6) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("In use").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .padding(.trailing, 6)
            }
            if !row.connected {
                StepButton(symbol: "xmark", label: "Forget \(row.device.name)", enabled: true, action: forget)
            }
            StepButton(symbol: "chevron.up", label: "Move \(row.device.name) up", enabled: canMoveUp, action: up)
            StepButton(symbol: "chevron.down", label: "Move \(row.device.name) down", enabled: canMoveDown, action: down)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: OrderList.rowHeight)
        .background(lifted ? Color(hex: 0x30343F) : hovering ? Theme.raised : Theme.tile)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 8, y: 2)
        .onHover { hovering = $0 }
    }
}

private struct StepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && enabled ? Color.white.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}
