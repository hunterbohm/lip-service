/// The order Automatic picks a microphone in, which the user can set on the Microphone page.
///
/// It holds the microphones the user placed, by UID, first choice first, with the name each had when last seen, so one
/// that is unplugged can still be listed. A microphone that is not placed ranks after every placed one, in the built-in
/// kind order: a wired one, then the Mac's own, then Bluetooth. With nothing placed, which is how everyone starts, that
/// kind order is the whole rule, so Automatic picks as it always did.
public struct AutomaticOrder: Equatable, Codable, Sendable {
    public struct Device: Equatable, Codable, Sendable, Identifiable {
        public let uid: String
        public var name: String
        public var id: String { uid }

        public init(uid: String, name: String) {
            (self.uid, self.name) = (uid, name)
        }
    }

    /// The placed microphones, first choice first. Never two with one UID.
    public private(set) var devices: [Device]

    /// Nothing placed: the kind order alone.
    public init() { devices = [] }

    public init(devices: [Device]) {
        var seen = Set<String>()
        self.devices = devices.filter { !$0.uid.isEmpty && seen.insert($0.uid).inserted }
    }

    /// True while the user has placed nothing.
    public var isDefault: Bool { devices.isEmpty }

    /// What an unplaced microphone ranks by: a wired one, then the Mac's own, then Bluetooth. A kind not here, such as
    /// a virtual device or an iPhone, is never picked.
    static let kindOrder: [MicrophoneInput.Kind] = [.wired, .builtIn, .bluetooth]

    // MARK: Picking

    /// The UID Automatic records from, or nil when no connected microphone qualifies. Among microphones of one rank,
    /// the system default goes first, then the order CoreAudio lists them in. With the lid closed the Mac's own
    /// microphone is skipped, placed or not, since closing the lid disconnects it.
    func pick(among inputs: [MicrophoneInput], systemDefault: String?, lidClosed: Bool) -> String? {
        let placed = Dictionary(devices.enumerated().map { ($1.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = inputs.enumerated().compactMap { index, input -> (rank: [Int], uid: String)? in
            guard !(lidClosed && input.kind == .builtIn) else { return nil }
            let place: Int
            if let position = placed[input.uid], input.kind != .other {
                place = position
            } else if let kind = Self.kindOrder.firstIndex(of: input.kind) {
                place = devices.count + kind
            } else {
                return nil
            }
            return ([place, input.uid == systemDefault ? 0 : 1, index], input.uid)
        }
        return ranked.min { $0.rank.lexicographicallyPrecedes($1.rank) }?.uid
    }

    // MARK: Listing and editing

    /// What the Microphone page lists, first choice first: the placed microphones, then every other connected one in
    /// the order it would rank. This is the order Automatic follows, since a connected microphone that is not placed
    /// ranks right here. A placed one keeps its place when unplugged, and takes its current name when connected.
    /// Virtual devices and iPhones never appear.
    public func listed(among inputs: [MicrophoneInput], systemDefault: String?) -> [Device] {
        let connected = Dictionary(inputs.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = devices.map { device in
            Device(uid: device.uid, name: connected[device.uid].flatMap { $0.name.isEmpty ? nil : $0.name } ?? device.name)
        }
        let placedUIDs = Set(devices.map(\.uid))
        let rest = inputs.enumerated().compactMap { index, input -> (rank: [Int], device: Device)? in
            guard !placedUIDs.contains(input.uid), let kind = Self.kindOrder.firstIndex(of: input.kind) else { return nil }
            return ([kind, input.uid == systemDefault ? 0 : 1, index], Device(uid: input.uid, name: input.name.isEmpty ? input.uid : input.name))
        }
        .sorted { $0.rank.lexicographicallyPrecedes($1.rank) }
        .map(\.device)
        var seen = Set<String>()
        return (placed + rest).filter { seen.insert($0.uid).inserted }
    }

    /// The order after the user moved the listed microphone at `from` to `to`, where `to` is its place in the new list.
    /// Placing the microphones exactly as they would rank anyway leaves nothing placed.
    public func moving(from: Int, to: Int, among inputs: [MicrophoneInput], systemDefault: String?) -> AutomaticOrder {
        var list = listed(among: inputs, systemDefault: systemDefault)
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return self }
        list.insert(list.remove(at: from), at: to)
        return placing(list, among: inputs, systemDefault: systemDefault)
    }

    /// The order without the placed microphone `uid`. Only a placed microphone goes, and a connected one comes back
    /// among the unplaced.
    public func forgetting(_ uid: String) -> AutomaticOrder {
        AutomaticOrder(devices: devices.filter { $0.uid != uid })
    }

    private func placing(_ list: [Device], among inputs: [MicrophoneInput], systemDefault: String?) -> AutomaticOrder {
        let unplaced = AutomaticOrder().listed(among: inputs, systemDefault: systemDefault)
        return list == unplaced ? AutomaticOrder() : AutomaticOrder(devices: list)
    }

    /// Where a row dragged `translation` points down from `from` lands in a list of `count` rows each `rowHeight` tall:
    /// the place it would take if let go now, never past either end.
    public static func dropPlace(from: Int, translation: Double, rowHeight: Double, count: Int) -> Int {
        guard count > 0, rowHeight > 0, translation.isFinite else { return from }
        let shifted = from + Int((translation / rowHeight).rounded())
        return min(max(shifted, 0), count - 1)
    }

    // MARK: Storing

    private enum CodingKeys: String, CodingKey { case devices }

    /// One entry that does not read drops only itself.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(devices: (try? container.decodeIfPresent(LossyArray<Device>.self, forKey: .devices))?.elements ?? [])
    }
}
