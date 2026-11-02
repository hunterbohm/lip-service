import Testing
@testable import DictationCore

@Suite("Output mute") struct OutputMuteTests {
    private static let speakers = OutputMute.Output(device: "BuiltInSpeakerDevice", muted: false)

    @Test func mutesAfterTheCueAndPutsTheSoundBack() {
        var mute = OutputMute()
        let serial = mute.listen()
        #expect(mute.cueEnded(serial, output: Self.speakers) == .mute(device: "BuiltInSpeakerDevice"))
        #expect(mute.stop() == .unmute(device: "BuiltInSpeakerDevice"))
        #expect(mute.phase == .idle)
        #expect(mute.stop() == nil)
    }

    @Test func aDictationThatEndsBeforeTheCueNeverMutes() {
        var mute = OutputMute()
        let serial = mute.listen()
        #expect(mute.stop() == nil)
        #expect(mute.cueEnded(serial, output: Self.speakers) == nil)
        #expect(mute.phase == .idle)
    }

    @Test func aLateCueFromAnEarlierCaptureIsIgnored() {
        var mute = OutputMute()
        let first = mute.listen()
        _ = mute.stop()
        let second = mute.listen()
        #expect(mute.cueEnded(first, output: Self.speakers) == nil)
        #expect(mute.cueEnded(second, output: Self.speakers) == .mute(device: "BuiltInSpeakerDevice"))
    }

    @Test func outputMutedAlreadyOrWithoutAMuteIsLeftAlone() {
        var mute = OutputMute()
        let serial = mute.listen()
        #expect(mute.cueEnded(serial, output: .init(device: "Display", muted: true)) == nil)
        #expect(mute.stop() == nil)
        let again = mute.listen()
        #expect(mute.cueEnded(again, output: nil) == nil)
        #expect(mute.stop() == nil)
    }

    @Test func aNewCaptureWhileMutedKeepsTheDeviceToRestore() {
        var mute = OutputMute()
        let serial = mute.listen()
        _ = mute.cueEnded(serial, output: Self.speakers)
        let next = mute.listen()
        #expect(mute.cueEnded(next, output: .init(device: "BuiltInSpeakerDevice", muted: true)) == nil)
        #expect(mute.stop() == .unmute(device: "BuiltInSpeakerDevice"))
    }
}

@Suite("Muted outputs marker") struct MutedOutputsTests {
    @Test func listsEachMutedOutputOnceUntilItIsUnmuted() {
        var outputs = MutedOutputs(text: nil)
        #expect(outputs.text == nil)
        outputs.add("Speakers")
        outputs.add("USB")
        outputs.add("Speakers")
        #expect(outputs.text == "Speakers\nUSB\n")
        outputs.remove("Speakers")
        #expect(MutedOutputs(text: outputs.text).devices == ["USB"])
        outputs.remove("USB")
        #expect(outputs.text == nil)
    }

    @Test func readsAMarkerFromTheEarlierSingleDeviceFormat() {
        #expect(MutedOutputs(text: "BuiltInSpeakerDevice").devices == ["BuiltInSpeakerDevice"])
    }
}
