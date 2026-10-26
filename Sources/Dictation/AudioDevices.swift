import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Input devices as CoreAudio reports them. Read fresh on each call, since devices come and go.
enum AudioDevices {
    struct Input: Equatable, Identifiable {
        var id: String { uid }
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
    }

    static func inputs() -> [Input] {
        guard let ids: [AudioDeviceID] = arrayProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return Input(uid: uid, name: name, deviceID: id)
        }
    }

    static func defaultInput() -> Input? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return inputs().first { $0.deviceID == id }
    }

    static func input(uid: String) -> Input? { inputs().first { $0.uid == uid } }

    /// Points a fresh engine's input at `device`. False when CoreAudio refuses, and the engine keeps the default.
    static func select(_ device: AudioDeviceID, for engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
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
