// Churns the Mac's audio devices the way plugging AirPods or a USB microphone in and out does, so a running Lip Service
// sees the device list and the default input change many times. It makes aggregate input devices over the real input,
// moves the default input between them and the real one, destroys them, and changes the real device's sample rate.
// It leaves the Mac as it found it. Build and run through scripts/hidden-mac-verify.sh, never on a Mac someone uses.
//
// usage: audio-churn [--cycles N] [--pause MS] [--seed N] [--rates]
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var cycles = 200
    var pauseMs = 40
    var seed: UInt64 = 1
    var rates = false
}

var options = Options()
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--cycles": options.cycles = Int(arguments.popFirst() ?? "") ?? options.cycles
    case "--pause": options.pauseMs = Int(arguments.popFirst() ?? "") ?? options.pauseMs
    case "--seed": options.seed = UInt64(arguments.popFirst() ?? "") ?? options.seed
    case "--rates": options.rates = true
    default:
        FileHandle.standardError.write(Data("usage: audio-churn [--cycles N] [--pause MS] [--seed N] [--rates]\n".utf8))
        exit(2)
    }
}

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func devices() -> [AudioDeviceID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultInput() -> AudioDeviceID? {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

@discardableResult func setDefaultInput(_ id: AudioDeviceID) -> Bool {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var value = id
    return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}

func rates(of id: AudioDeviceID) -> [Double] {
    var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges) == noErr else { return [] }
    return Array(Set(ranges.map(\.mMinimum))).sorted()
}

func nominalRate(of id: AudioDeviceID) -> Double? {
    var a = address(kAudioDevicePropertyNominalSampleRate)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate) == noErr ? rate : nil
}

@discardableResult func setNominalRate(_ rate: Double, of id: AudioDeviceID) -> Bool {
    var a = address(kAudioDevicePropertyNominalSampleRate)
    var value = Float64(rate)
    return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
}

let prefix = "LSChurn"

func removeLeftovers() {
    for id in devices() where string(id, kAudioObjectPropertyName)?.hasPrefix(prefix) == true {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("audio-churn: \(message)\n".utf8))
    exit(1)
}

removeLeftovers()
guard let original = defaultInput(), let baseUID = string(original, kAudioDevicePropertyDeviceUID) else { fail("no default input device") }
let baseRates = rates(of: original)
let originalRate = nominalRate(of: original)
print("base: \(string(original, kAudioObjectPropertyName) ?? "?") \(baseUID) rates \(baseRates.map { Int($0) })")

var created: [AudioDeviceID] = []
var serial = 0

func makeAggregate() -> AudioDeviceID? {
    serial += 1
    let uid = "\(prefix)-\(getpid())-\(serial)"
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "\(prefix) \(serial)",
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: baseUID]],
        kAudioAggregateDeviceMainSubDeviceKey: baseUID,
        kAudioAggregateDeviceIsPrivateKey: 0,
        kAudioAggregateDeviceIsStackedKey: 0,
    ]
    var id = AudioObjectID(0)
    guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr, id != 0 else { return nil }
    for _ in 0..<50 where inputChannels(id) == 0 { usleep(10_000) }
    created.append(id)
    return id
}

func destroyOldest() {
    guard !created.isEmpty else { return }
    AudioHardwareDestroyAggregateDevice(created.removeFirst())
}

func restore() {
    if defaultInput() != original { setDefaultInput(original) }
    while !created.isEmpty { destroyOldest() }
    removeLeftovers()
    if let originalRate, nominalRate(of: original) != originalRate { setNominalRate(originalRate, of: original) }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var generator = SplitMix64(seed: options.seed)

// A stop signal puts the Mac back as it was. The work runs on a global queue, so the main queue is free to take it.
let stopSignals = [SIGINT, SIGTERM].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { restore(); exit(130) }
    source.resume()
    return source
}

var counts = (created: 0, destroyed: 0, defaultChanges: 0, rateChanges: 0, refused: 0)
let started = Date()
for cycle in 1...options.cycles {
    DispatchQueue.global().sync {
        switch Int.random(in: 0..<5, using: &generator) {
        case 0, 1:
            if let id = makeAggregate() {
                counts.created += 1
                if setDefaultInput(id) { counts.defaultChanges += 1 } else { counts.refused += 1 }
            } else { counts.refused += 1 }
        case 2:
            if setDefaultInput(original) { counts.defaultChanges += 1 } else { counts.refused += 1 }
        case 3:
            if created.count > 1 {
                destroyOldest()
                counts.destroyed += 1
            }
            if let target = created.randomElement(using: &generator), setDefaultInput(target) { counts.defaultChanges += 1 }
        default:
            if options.rates, baseRates.count > 1, let rate = baseRates.randomElement(using: &generator) {
                if setNominalRate(rate, of: original) { counts.rateChanges += 1 } else { counts.refused += 1 }
            } else if setDefaultInput(original) { counts.defaultChanges += 1 }
        }
        if created.count > 4 {
            destroyOldest()
            counts.destroyed += 1
        }
    }
    if cycle % 50 == 0 { print("cycle \(cycle) of \(options.cycles)") }
    usleep(UInt32(options.pauseMs) * 1000 + UInt32.random(in: 0..<20_000, using: &generator))
}
restore()
print(String(format: "done: %d cycles in %.1f s, aggregates made %d, destroyed %d, default input changes %d, rate changes %d, refused %d",
             options.cycles, Date().timeIntervalSince(started), counts.created, counts.destroyed, counts.defaultChanges,
             counts.rateChanges, counts.refused))
