import AVFoundation
import DictationCore
import SwiftUI

struct MicrophonePage: View {
    let services: WindowServices

    var body: some View {
        let preferences = services.preferences
        let choice = preferences.current.settings.microphone
        let inputs = services.inputs
        let source = inputs.inUse(choice)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Microphone")
                if let missing = source.missing {
                    Notice(tone: .warning, title: "\(missing) isn't connected", detail: "Using \(source.name) until it's back.")
                        .padding(.bottom, 18)
                }
                VStack(spacing: 0) {
                    ForEach(Array(options(choice, inputs).enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Theme.line.frame(height: 1) }
                        OptionRow(option: option, chosen: option.choice == choice) {
                            preferences.change { $0.microphone = option.choice }
                        }
                    }
                }
                .frame(maxWidth: 680)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
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
        .onChange(of: choice) { _, next in services.level.start(next) }
    }

    private func options(_ choice: MicrophoneChoice, _ inputs: Inputs) -> [Option] {
        let defaultName = inputs.systemDefault?.name
        var options = [Option(choice: .systemDefault, name: "System Default",
                              detail: defaultName.map { "Follows your Mac's sound settings, now \($0)" } ?? "Follows your Mac's sound settings")]
        options += inputs.all.map { input in
            Option(choice: .device(uid: input.uid, name: input.name), name: input.name,
                   detail: input.uid == inputs.systemDefault?.uid ? "Your Mac's default" : nil)
        }
        if case .device(let uid, let name) = choice, !inputs.all.contains(where: { $0.uid == uid }) {
            options.append(Option(choice: choice, name: name, detail: "Not connected", missing: true))
        }
        return options
    }
}

private struct Option: Identifiable {
    var id: String { if case .device(let uid, _) = choice { uid } else { "" } }
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
    private(set) var all: [AudioDevices.Input] = []
    private(set) var systemDefault: AudioDevices.Input?
    @ObservationIgnored private let read: @MainActor () -> (all: [AudioDevices.Input], systemDefault: AudioDevices.Input?)

    init(read: @escaping @MainActor () -> (all: [AudioDevices.Input], systemDefault: AudioDevices.Input?) = {
        (AudioDevices.inputs(), AudioDevices.defaultInput())
    }) {
        self.read = read
        refresh()
    }

    func refresh() {
        let next = read()
        if next.all != all { all = next.all }
        if next.systemDefault != systemDefault { systemDefault = next.systemDefault }
    }

    /// The device a dictation would record from now, and the chosen one when it is missing.
    func inUse(_ choice: MicrophoneChoice) -> (name: String, missing: String?) {
        let fallback = systemDefault?.name ?? "no microphone"
        return switch choice.source(connected: all.map(\.uid)) {
        case .systemDefault: (fallback, nil)
        case .device(let uid): (all.first { $0.uid == uid }?.name ?? fallback, nil)
        case .fallback(let missing): (fallback, missing)
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
            if case .device(let uid, _) = choice, let input = AudioDevices.input(uid: uid) {
                _ = AudioDevices.select(input.deviceID, for: engine)
            }
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }
            node.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for index in 0..<count { sum += samples[index] * samples[index] }
                report(Loudness.fraction(rms: (sum / Float(count)).squareRoot()))
            }
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
