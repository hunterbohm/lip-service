import Foundation
import Testing
@testable import DictationCore

@Suite("Automatic order") struct AutomaticOrderTests {
    let shure = MicrophoneInput(uid: "usb:shure", kind: .wired, name: "Shure MV7+")
    let webcam = MicrophoneInput(uid: "usb:webcam", kind: .wired, name: "Webcam")
    let builtIn = MicrophoneInput(uid: "builtin", kind: .builtIn, name: "MacBook Pro Microphone")
    let airPods = MicrophoneInput(uid: "bt:airpods", kind: .bluetooth, name: "AirPods Pro")
    let headset = MicrophoneInput(uid: "bt:headset", kind: .bluetooth, name: "Headset")
    let blackHole = MicrophoneInput(uid: "blackhole", kind: .other, name: "BlackHole 2ch")

    private func device(_ input: MicrophoneInput) -> AutomaticOrder.Device { .init(uid: input.uid, name: input.name) }

    private func order(_ inputs: MicrophoneInput...) -> AutomaticOrder { AutomaticOrder(devices: inputs.map(device)) }

    private func source(_ order: AutomaticOrder, _ inputs: [MicrophoneInput], systemDefault: MicrophoneInput? = nil,
                        lidClosed: Bool = false) -> MicrophoneSource {
        MicrophoneChoice.automatic.source(among: inputs, systemDefault: systemDefault?.uid, lidClosed: lidClosed, order: order)
    }

    private func listed(_ order: AutomaticOrder, _ inputs: [MicrophoneInput], systemDefault: MicrophoneInput? = nil) -> [String] {
        order.listed(among: inputs, systemDefault: systemDefault?.uid).map(\.uid)
    }

    @Test func nothingPlacedPicksByKindAsItAlwaysDid() {
        let none = AutomaticOrder()
        #expect(source(none, [airPods, builtIn, shure], systemDefault: airPods) == .device(uid: shure.uid))
        #expect(source(none, [airPods, builtIn], systemDefault: airPods) == .device(uid: builtIn.uid))
        #expect(source(none, [airPods, blackHole], systemDefault: blackHole) == .device(uid: airPods.uid))
        #expect(source(none, [webcam, shure], systemDefault: shure) == .device(uid: shure.uid))
        #expect(source(none, [webcam, shure], systemDefault: builtIn) == .device(uid: webcam.uid))
        #expect(source(none, [blackHole]) == .systemDefault)
        #expect(source(none, []) == .systemDefault)
        #expect(AutomaticOrder().isDefault)
    }

    @Test func aPlacedMicrophoneBeatsTheKindOrder() {
        let airPodsFirst = order(airPods, shure)
        #expect(source(airPodsFirst, [builtIn, shure, airPods], systemDefault: builtIn) == .device(uid: airPods.uid))
        #expect(source(order(builtIn, shure), [shure, builtIn, airPods]) == .device(uid: builtIn.uid))
    }

    @Test func aPlacedMicrophoneThatIsUnpluggedIsSkipped() {
        #expect(source(order(airPods, shure), [builtIn, shure]) == .device(uid: shure.uid))
        #expect(source(order(airPods, shure), [builtIn]) == .device(uid: builtIn.uid))
    }

    @Test func aMicrophoneNotPlacedRanksAfterEveryPlacedOneByKind() {
        let placed = order(airPods)
        #expect(source(placed, [shure, builtIn, headset]) == .device(uid: shure.uid), "AirPods are away, so the kind order decides")
        #expect(source(order(headset, airPods), [airPods, builtIn, shure, headset]) == .device(uid: headset.uid))
        #expect(source(order(headset), [builtIn, shure, airPods]) == .device(uid: shure.uid), "unplaced ones keep the kind order")
        #expect(source(order(airPods), [builtIn, headset, airPods]) == .device(uid: airPods.uid))
    }

    @Test func theLidRuleHoldsForAPlacedBuiltInMicrophone() {
        #expect(source(order(builtIn, airPods), [builtIn, airPods], systemDefault: builtIn, lidClosed: true) == .device(uid: airPods.uid))
        #expect(source(order(builtIn), [builtIn, shure], lidClosed: true) == .device(uid: shure.uid))
        #expect(source(order(builtIn), [builtIn], lidClosed: true) == .systemDefault)
        #expect(source(order(builtIn, airPods), [builtIn, airPods], lidClosed: false) == .device(uid: builtIn.uid))
    }

    @Test func aVirtualDeviceIsNeverPickedEvenWhenPlaced() {
        #expect(source(order(blackHole), [blackHole, builtIn]) == .device(uid: builtIn.uid))
        #expect(source(order(blackHole), [blackHole]) == .systemDefault)
    }

    @Test func placedMicrophonesOfOneKindFollowTheirPlaces() {
        #expect(source(order(webcam, shure), [shure, webcam], systemDefault: shure) == .device(uid: webcam.uid))
    }

    @Test func theOrderDoesNotChangeAChosenDeviceOrSystemDefault() {
        let placed = order(airPods)
        #expect(MicrophoneChoice.systemDefault.source(among: [airPods], systemDefault: nil, lidClosed: false, order: placed) == .systemDefault)
        #expect(MicrophoneChoice.device(uid: shure.uid, name: "Shure").source(among: [shure, airPods], systemDefault: nil, lidClosed: false, order: placed)
            == .device(uid: shure.uid))
    }

    // MARK: Listing

    @Test func withNothingPlacedTheListIsTheKindOrderWithoutVirtualDevices() {
        #expect(listed(AutomaticOrder(), [airPods, blackHole, builtIn, shure]) == [shure.uid, builtIn.uid, airPods.uid])
        #expect(listed(AutomaticOrder(), [webcam, shure], systemDefault: shure) == [shure.uid, webcam.uid])
        #expect(listed(AutomaticOrder(), [blackHole]).isEmpty)
    }

    @Test func theListPutsPlacedMicrophonesFirstAndKeepsUnpluggedOnes() {
        let placed = order(airPods, shure)
        #expect(listed(placed, [builtIn, shure, headset]) == [airPods.uid, shure.uid, builtIn.uid, headset.uid])
        let renamed = AutomaticOrder(devices: [.init(uid: shure.uid, name: "Old name")])
        #expect(renamed.listed(among: [shure], systemDefault: nil).map(\.name) == ["Shure MV7+"])
        #expect(renamed.listed(among: [], systemDefault: nil).map(\.name) == ["Old name"], "unplugged keeps the name it had")
    }

    @Test func theListIsTheOrderAutomaticFollows() {
        let placed = order(headset, builtIn)
        for connected in [[builtIn, shure, airPods, headset], [builtIn, shure, airPods], [shure, airPods], [airPods]] {
            let uids = Set(connected.map(\.uid))
            let top = placed.listed(among: connected, systemDefault: nil).first { uids.contains($0.uid) }?.uid
            #expect(source(placed, connected) == .device(uid: top ?? ""))
        }
    }

    // MARK: Editing

    @Test func movingPlacesTheWholeListAsItWasShown() {
        let inputs = [builtIn, shure, airPods]
        let moved = AutomaticOrder().moving(from: 2, to: 0, among: inputs, systemDefault: nil)
        #expect(moved.devices.map(\.uid) == [airPods.uid, shure.uid, builtIn.uid])
        let again = moved.moving(from: 0, to: 1, among: inputs, systemDefault: nil)
        #expect(again.devices.map(\.uid) == [shure.uid, airPods.uid, builtIn.uid])
    }

    @Test func movingBackToTheDefaultOrderLeavesNothingPlaced() {
        let inputs = [builtIn, shure, airPods]
        let moved = AutomaticOrder().moving(from: 2, to: 0, among: inputs, systemDefault: nil)
        #expect(!moved.isDefault)
        #expect(moved.moving(from: 0, to: 2, among: inputs, systemDefault: nil).isDefault)
    }

    @Test func aMoveOutOfRangeChangesNothing() {
        let inputs = [builtIn, shure]
        let placed = order(builtIn, shure)
        #expect(placed.moving(from: 0, to: 5, among: inputs, systemDefault: nil) == placed)
        #expect(placed.moving(from: -1, to: 0, among: inputs, systemDefault: nil) == placed)
        #expect(placed.moving(from: 1, to: 1, among: inputs, systemDefault: nil) == placed)
    }

    @Test func aPlacedMicrophoneThatIsAwayStaysThroughMovesUntilForgotten() {
        let placed = order(airPods, shure, builtIn)
        let inputs = [builtIn, shure]
        let moved = placed.moving(from: 2, to: 1, among: inputs, systemDefault: nil)
        #expect(moved.devices.map(\.uid) == [airPods.uid, builtIn.uid, shure.uid])
        #expect(moved.forgetting(airPods.uid).devices.map(\.uid) == [builtIn.uid, shure.uid])
        #expect(moved.forgetting("nothing") == moved)
    }

    @Test func aDraggedRowLandsWhereItsMiddleIsAndNeverPastTheEnds() {
        func place(_ from: Int, _ translation: Double) -> Int { AutomaticOrder.dropPlace(from: from, translation: translation, rowHeight: 56, count: 4) }
        #expect(place(1, 0) == 1)
        #expect(place(1, 27) == 1, "under half a row stays")
        #expect(place(1, 29) == 2)
        #expect(place(1, -29) == 0)
        #expect(place(0, -300) == 0)
        #expect(place(3, 300) == 3)
        #expect(place(0, 170) == 3)
        #expect(AutomaticOrder.dropPlace(from: 2, translation: .nan, rowHeight: 56, count: 4) == 2)
        #expect(AutomaticOrder.dropPlace(from: 0, translation: 90, rowHeight: 56, count: 0) == 0)
    }

    // MARK: Storing

    @Test func aNewInstallAndAnOldStoredSettingsValueStartWithNothingPlaced() throws {
        #expect(Settings().automaticOrder.isDefault)
        let old = #"{"microphone":{"automatic":{}},"sounds":false}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(decoded.automaticOrder.isDefault)
        #expect(decoded.microphone == .automatic)
        #expect(decoded.sounds == false)
    }

    @Test func theOrderIsStoredAndKeptAcrossARoundTrip() throws {
        var settings = Settings()
        settings.automaticOrder = order(airPods, shure)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.automaticOrder == settings.automaticOrder)
        #expect(decoded == settings)
    }

    @Test func anEntryThatDoesNotReadDropsOnlyItselfAndAWholeBadValueFallsBack() throws {
        let partly = #"{"automaticOrder":{"devices":[{"uid":"a","name":"A"},{"nope":1},{"uid":"a","name":"Again"},{"uid":"","name":"Empty"},{"uid":"b","name":"B"}]}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(partly.utf8))
        #expect(decoded.automaticOrder.devices.map(\.uid) == ["a", "b"])
        let wrong = #"{"automaticOrder":7,"sounds":false}"#
        let fallback = try JSONDecoder().decode(Settings.self, from: Data(wrong.utf8))
        #expect(fallback.automaticOrder.isDefault)
        #expect(fallback.sounds == false)
    }
}
