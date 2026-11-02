/// Whether Lip Service holds the Mac's sound off while you talk, and what it must put back. The output is muted only
/// once the start cue has played, only if it was not muted already, and it is unmuted only if Lip Service muted it.
public struct OutputMute: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Listening, until the start cue has played. `serial` names this capture's wait, so a late answer for an
        /// earlier capture changes nothing.
        case waiting(serial: Int)
        /// Lip Service muted the output with this UID.
        case muted(device: String)
        /// Listening, with the output left as it was: muted already, or with no mute control.
        case untouched
    }

    public enum Action: Equatable, Sendable {
        case mute(device: String)
        case unmute(device: String)
    }

    /// The default output when the cue ended.
    public struct Output: Equatable, Sendable {
        public var device: String
        public var muted: Bool
        public init(device: String, muted: Bool) { (self.device, self.muted) = (device, muted) }
    }

    public private(set) var phase = Phase.idle
    private var serial = 0

    public init() {}

    /// Listening started. Returns the serial to pass to `cueEnded`. Output muted for an earlier capture stays muted.
    public mutating func listen() -> Int {
        serial += 1
        if case .muted = phase { return serial }
        phase = .waiting(serial: serial)
        return serial
    }

    /// `output` is nil when the default output has no mute control.
    public mutating func cueEnded(_ serial: Int, output: Output?) -> Action? {
        guard phase == .waiting(serial: serial) else { return nil }
        guard let output, !output.muted else {
            phase = .untouched
            return nil
        }
        phase = .muted(device: output.device)
        return .mute(device: output.device)
    }

    /// Listening ended, by finishing, cancelling or failing, or the setting went off.
    public mutating func stop() -> Action? {
        defer { phase = .idle }
        if case .muted(let device) = phase { return .unmute(device: device) }
        return nil
    }
}

/// The mute marker's text: every output Lip Service muted and has not unmuted yet, one UID per line. An output that
/// stays listed gets its sound back once it can, at the next launch, on wake, or when a device comes or goes.
public struct MutedOutputs: Equatable, Sendable {
    public private(set) var devices: [String]

    public init(text: String?) {
        devices = []
        for line in (text ?? "").split(whereSeparator: \.isNewline) { add(line.trimmingCharacters(in: .whitespaces)) }
    }

    /// Nil when nothing is listed, so the marker can go.
    public var text: String? { devices.isEmpty ? nil : devices.joined(separator: "\n") + "\n" }

    public mutating func add(_ device: String) {
        if !device.isEmpty, !devices.contains(device) { devices.append(device) }
    }

    public mutating func remove(_ device: String) { devices.removeAll { $0 == device } }
}
