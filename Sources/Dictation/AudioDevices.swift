import AudioToolbox
import AVFoundation
import CoreAudio
import DictationCore
import Foundation
import IOKit

/// Devices as CoreAudio reports them. Read fresh on each call, since devices come and go.
enum AudioDevices {
    struct Input: Equatable, Identifiable {
        var id: String { uid }
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
        var kind = MicrophoneInput.Kind.other

        var choiceInput: MicrophoneInput { MicrophoneInput(uid: uid, kind: kind) }
    }

    /// Where `choice` records from now, among `inputs`.
    static func source(for choice: MicrophoneChoice, among inputs: [Input]) -> MicrophoneSource {
        choice.source(among: inputs.map(\.choiceInput), systemDefault: defaultInput(among: inputs)?.uid, lidClosed: lidClosed())
    }

    /// True while a MacBook's lid is closed, which disconnects its microphone in hardware.
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    static func inputs() -> [Input] {
        guard let ids: [AudioDeviceID] = arrayProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return Input(uid: uid, name: name, deviceID: id, kind: kind(of: id))
        }
    }

    static func defaultInput() -> Input? { defaultInput(among: inputs()) }

    static func defaultInput(among inputs: [Input]) -> Input? {
        defaultInputID().flatMap { id in inputs.first { $0.deviceID == id } }
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                                        mElement: kAudioObjectPropertyElementMain)

    private static func kind(of id: AudioDeviceID) -> MicrophoneInput.Kind {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return .other }
        return switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeAVB: .wired
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        default: .other
        }
    }

    static func input(uid: String) -> Input? { inputs().first { $0.uid == uid } }

    /// Points a fresh engine's input at `device`. False when CoreAudio refuses, and the engine keeps the default.
    static func select(_ device: AudioDeviceID, for engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// The device a running or stopped engine's input points at.
    static func current(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr ? id : nil
    }

    /// The default output and whether it is muted, or nil when it has no mute control that can be set, as with most
    /// HDMI and DisplayPort displays.
    static func defaultOutputMute() -> OutputMute.Output? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), let muted = outputMuted(id)
        else { return nil }
        return OutputMute.Output(device: uid, muted: muted)
    }

    /// Sets the mute of the output with this UID. False when it is gone or refuses.
    @discardableResult static func setOutputMute(_ muted: Bool, uid: String) -> Bool {
        guard let ids: [AudioDeviceID] = arrayProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
              let id = ids.first(where: { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }), outputMuted(id) != nil
        else { return false }
        var address = muteAddress
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Calls `handler` on `queue` whenever a device is added or removed, for as long as the app runs.
    static func onDeviceListChange(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in handler() }
    }

    /// Calls `handler` on `queue` whenever the system default input changes, for as long as the app runs.
    static func onDefaultInputChange(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        var address = defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in handler() }
    }

    private static let muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                                mElement: kAudioObjectPropertyElementMain)

    /// Nil when the device has no settable output mute.
    private static func outputMuted(_ id: AudioDeviceID) -> Bool? {
        var address = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(id, &address), AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func arrayProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        return [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buffer, count in
            count = 0
            var bytes = size
            if AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, buffer.baseAddress!) == noErr {
                count = Int(bytes) / MemoryLayout<T>.stride
            }
        }
    }
}
