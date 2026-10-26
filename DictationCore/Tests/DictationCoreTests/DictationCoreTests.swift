import Foundation
import Testing
@testable import DictationCore

private func t(_ s: Double) -> Instant { Instant(seconds: s) }

/// Feeds a key timeline to a fresh machine and collects every command it issued.
private func press(_ inputs: [KeyInput], timing: HotkeyTiming = HotkeyTiming()) -> (phase: HotkeyMachine, commands: [CaptureCommand]) {
    var machine = HotkeyMachine.idle
    let commands = inputs.flatMap { machine.handle($0, timing: timing).commands }
    return (machine, commands)
}

@Suite("Hotkey state machine") struct HotkeyTests {
    @Test func holdThenReleaseFinishes() {
        #expect(press([.hotkeyDown(t(0)), .tick(t(0.12)), .hotkeyUp(t(1.5))]) == (.idle, [.start, .finish]))
    }

    @Test func releaseUnderMinHoldIsATapThatCancelsWhenTheWindowLapses() {
        let (phase, commands) = press([.hotkeyDown(t(0)), .hotkeyUp(t(0.1))])
        #expect(commands == [.start])
        #expect(phase == .tapped(captureStart: t(0), releasedAt: t(0.1), shown: false))
        #expect(press([.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .tick(t(0.45))]) == (.idle, [.start, .cancel]))
    }

    @Test func doubleTapEntersHandsFreeAndTheNextPressFinishes() {
        let taps: [KeyInput] = [.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.3)), .hotkeyUp(t(0.4))]
        let handsFree = press(taps)
        #expect(handsFree == (.handsFree(captureStart: t(0)), [.start]))
        #expect(handsFree.phase.showsListening)
        #expect(press(taps + [.tick(t(5)), .hotkeyDown(t(8)), .hotkeyUp(t(8.1))]) == (.idle, [.start, .finish]))
    }

    @Test func tapThenHoldFinishesAsAHoldKeepingTheFirstTapsAudio() {
        let keys: [KeyInput] = [.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.3)), .hotkeyUp(t(2.0))]
        #expect(press(keys) == (.idle, [.start, .finish]))
    }

    @Test func aSecondPressAfterTheWindowIsAFreshPressEvenWhenTheTickIsLate() {
        let (phase, commands) = press([.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.6))])
        #expect(commands == [.start, .cancel, .start])
        #expect(phase == .pressed(since: t(0.6), shown: false))
        #expect(press([.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.6)), .hotkeyUp(t(2))]).commands
            == [.start, .cancel, .start, .finish])
    }

    @Test func chordCancelsAndItsReleaseIsIgnored() {
        let chord = press([.hotkeyDown(t(0)), .otherKey(t(0.05), isEscape: false)])
        #expect(chord == (.awaitingRelease, [.start, .cancel]))
        #expect(press([.hotkeyDown(t(0)), .otherKey(t(0.05), isEscape: false), .hotkeyUp(t(2))]) == (.idle, [.start, .cancel]))
    }

    @Test func typingDuringTheDoubleTapWindowCancels() {
        #expect(press([.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .otherKey(t(0.2), isEscape: false)]) == (.idle, [.start, .cancel]))
    }

    @Test func barStaysHiddenUntilBarDelaySoChordsNeverShowIt() {
        var machine = HotkeyMachine.idle
        let timing = HotkeyTiming()
        _ = machine.handle(.hotkeyDown(t(0)), timing: timing)
        #expect(!machine.showsListening)
        #expect(machine.deadline(timing) == t(0) + timing.barDelay)
        _ = machine.handle(.tick(t(0.05)), timing: timing)
        #expect(!machine.showsListening)
        _ = machine.handle(.tick(t(0.12)), timing: timing)
        #expect(machine.showsListening)
    }

    @Test func escapeCancelsHandsFreeAndIsConsumedButPassesThroughOtherwise() {
        var machine = HotkeyMachine.handsFree(captureStart: t(0))
        let timing = HotkeyTiming()
        #expect(machine.handle(.otherKey(t(3), isEscape: false), timing: timing) == HotkeyStep())
        #expect(machine == .handsFree(captureStart: t(0)))
        #expect(machine.handle(.otherKey(t(4), isEscape: true), timing: timing) == HotkeyStep([.cancel], consumeEvent: true))
        #expect(machine == .idle)

        var held = HotkeyMachine.idle
        _ = held.handle(.hotkeyDown(t(0)), timing: timing)
        #expect(held.handle(.otherKey(t(1), isEscape: true), timing: timing) == HotkeyStep([.cancel]))
    }

    @Test func captureFinishesItselfAtMaxCapture() {
        var timing = HotkeyTiming()
        timing.maxCapture = 10
        #expect(press([.hotkeyDown(t(0)), .tick(t(0.12)), .tick(t(9.9))], timing: timing).commands == [.start])
        #expect(press([.hotkeyDown(t(0)), .tick(t(0.12)), .tick(t(10))], timing: timing) == (.awaitingRelease, [.start, .finish]))
        let handsFree: [KeyInput] = [.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.3)), .hotkeyUp(t(0.4)), .tick(t(10))]
        #expect(press(handsFree, timing: timing) == (.idle, [.start, .finish]))
    }

    @Test func abortWhileHeldWaitsForTheReleaseAndStartsNothingNew() {
        var machine = HotkeyMachine.idle
        let timing = HotkeyTiming()
        _ = machine.handle(.hotkeyDown(t(0)), timing: timing)
        machine.abort()
        #expect(machine == .awaitingRelease)
        #expect(machine.handle(.hotkeyUp(t(1)), timing: timing) == HotkeyStep())
        #expect(machine == .idle)
    }

    @Test func aLostReleaseDoesNotSwallowTheNextPress() {
        var machine = HotkeyMachine.awaitingRelease
        #expect(machine.handle(.hotkeyDown(t(5)), timing: HotkeyTiming()).commands == [.start])
        #expect(machine == .pressed(since: t(5), shown: false))
    }

    @Test func aPressWhileHeldMeansTheReleaseWasLostSoTheOldCaptureIsDropped() {
        let (phase, commands) = press([.hotkeyDown(t(0)), .tick(t(0.12)), .hotkeyDown(t(30))])
        #expect(commands == [.start, .cancel, .start])
        #expect(phase == .pressed(since: t(30), shown: false))
        #expect(press([.hotkeyDown(t(0)), .hotkeyDown(t(30)), .hotkeyUp(t(31))]).commands == [.start, .cancel, .start, .finish])
    }

    func classify(_ kind: KeyInput.EventKind, _ keyCode: Int, _ flags: UInt64, _ shortcuts: [Shortcut], repeat isRepeat: Bool = false,
                  at time: Instant = t(1)) -> KeyInput? {
        KeyInput.classify(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat, shortcuts: shortcuts, at: time)
    }

    @Test func classifyReadsFnOnlyFromItsOwnFlagsChanged() {
        let fnBit: UInt64 = 0x80_0000
        #expect(classify(.flagsChanged, 63, fnBit, [.fn]) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 63, 0, [.fn]) == .hotkeyUp(t(1)))
        #expect(classify(.keyDown, 123, fnBit, [.fn]) == .otherKey(t(1), isEscape: false))
        #expect(classify(.keyDown, 53, 0, [.fn]) == .otherKey(t(1), isEscape: true))
    }

    @Test func anotherModifierPressedIsAChordButOneLetGoIsNothing() {
        let leftShift: UInt64 = 0x2_0002
        #expect(classify(.flagsChanged, 56, leftShift, [.fn]) == .otherKey(t(1), isEscape: false))
        #expect(classify(.flagsChanged, 56, 0, [.fn]) == nil)
        #expect(classify(.keyUp, 0, 0, [.fn]) == nil)
    }

    @Test func classifyUsesTheRightSideBitForRightOptionAndCommand() {
        let rightOption = Shortcut(key: 61), rightCommand = Shortcut(key: 54)
        #expect(classify(.flagsChanged, 61, 0x8_0040, [rightOption]) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 61, 0x8_0020, [rightOption]) == .hotkeyUp(t(1)))
        #expect(classify(.flagsChanged, 54, 0x10_0010, [rightCommand]) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 54, 0x10_0008, [rightCommand]) == .hotkeyUp(t(1)))
        #expect(classify(.flagsChanged, 62, 0x4_2000, [.rightControl]) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 62, 0x4_0001, [.rightControl]) == .hotkeyUp(t(1)))
    }

    @Test func aKeyWithModifiersGoesDownOnlyWithExactlyThoseAndUpOnItsOwnRelease() {
        let optionSpace = Shortcut(key: 49, modifiers: [.option])
        let option: UInt64 = 0x8_0020, shift: UInt64 = 0x2_0002
        #expect(classify(.keyDown, 49, option, [optionSpace]) == .hotkeyDown(t(1)))
        #expect(classify(.keyDown, 49, option, [optionSpace], repeat: true) == nil)
        #expect(classify(.keyDown, 49, option | shift, [optionSpace]) == .otherKey(t(1), isEscape: false))
        #expect(classify(.keyDown, 49, 0, [optionSpace]) == .otherKey(t(1), isEscape: false))
        #expect(classify(.keyUp, 49, 0, [optionSpace]) == .hotkeyUp(t(1)))
        #expect(classify(.flagsChanged, 58, 0, [optionSpace]) == nil, "letting go of Option first keeps the hold")
    }

    @Test func aFunctionKeyIgnoresTheFnFlagLaptopsAdd() {
        let f5 = Shortcut(key: 96)
        #expect(classify(.keyDown, 96, 0x80_0000, [f5]) == .hotkeyDown(t(1)))
        #expect(classify(.keyUp, 96, 0x80_0000, [f5]) == .hotkeyUp(t(1)))
    }

    @Test func aModifierKeyWithModifiersNeedsThemHeldWhenItGoesDown() {
        let commandRightOption = Shortcut(key: 61, modifiers: [.command])
        let command: UInt64 = 0x10_0008, rightOption: UInt64 = 0x8_0040
        #expect(classify(.flagsChanged, 61, command | rightOption, [commandRightOption]) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 61, rightOption, [commandRightOption]) == .otherKey(t(1), isEscape: false))
        #expect(classify(.flagsChanged, 61, command, [commandRightOption]) == .hotkeyUp(t(1)))
    }

    @Test func shortcutsReadAsTheirKeys() {
        #expect(Shortcut.fn.title == "fn")
        #expect(Shortcut.rightControl.title == "Right Control")
        #expect(Shortcut.pasteLast.title == "⌃⌘V")
        #expect(Shortcut(key: 49, modifiers: [.option]).title == "⌥Space")
        #expect(Shortcut(key: 61, modifiers: [.command]).title == "⌘ Right Option")
        #expect(Shortcut(key: 96).title == "F5")
        #expect(Shortcut(key: 2, modifiers: [.shift, .control, .option, .command]).title == "⌃⌥⇧⌘D")
        #expect(Shortcut.phrase([.fn, Shortcut(key: 49, modifiers: [.option])]) == "fn or ⌥Space")
    }

    @Test func aShortcutThatWouldStopTypingIsRefused() {
        #expect(Shortcut(key: 0).problem == "Add Control, Option or Command, so A still types.")
        #expect(Shortcut(key: 0, modifiers: [.shift]).problem != nil)
        #expect(Shortcut(key: 49, modifiers: [.option]).problem == nil)
        #expect(Shortcut(key: 96).problem == nil, "a function key needs no modifier")
        #expect(Shortcut(key: 61).problem == nil, "a modifier key alone is fine")
        #expect(Shortcut(key: 57).problem == "Caps Lock can't be a shortcut.")
        #expect(Shortcut(key: 53).problem != nil)
    }

    @Test func handsFreeStopButtonFinishesAndCancelButtonCancels() {
        let handsFree: [KeyInput] = [.hotkeyDown(t(0)), .hotkeyUp(t(0.1)), .hotkeyDown(t(0.3)), .hotkeyUp(t(0.4))]
        #expect(press(handsFree + [.stopClicked(t(6))]) == (.idle, [.start, .finish]))
        #expect(press(handsFree + [.cancelClicked(t(6))]) == (.idle, [.start, .cancel]))
    }

    @Test func buttonClicksOutsideHandsFreeChangeNothing() {
        let held = press([.hotkeyDown(t(0)), .tick(t(0.12)), .stopClicked(t(1)), .cancelClicked(t(1.1))])
        #expect(held == (.pressed(since: t(0), shown: true), [.start]))
        #expect(press([.stopClicked(t(0)), .cancelClicked(t(1))]) == (.idle, []))
    }

    @Test func classifyAnswersToEveryChosenHotkeyAndNoOther() {
        let both: [Shortcut] = [.fn, .rightControl]
        #expect(classify(.flagsChanged, 63, 0x80_0000, both, at: t(0)) == .hotkeyDown(t(0)))
        #expect(classify(.flagsChanged, 62, 0x4_2000, both, at: t(1)) == .hotkeyDown(t(1)))
        #expect(classify(.flagsChanged, 62, 0x4_2000, [.fn], at: t(2)) == .otherKey(t(2), isEscape: false))
    }
}

@Suite("Shortcut recorder") struct ShortcutRecorderTests {
    func record(_ events: [(KeyInput.EventKind, Int, UInt64)]) -> ShortcutRecorder.Outcome? {
        var recorder = ShortcutRecorder()
        for (kind, key, flags) in events {
            if let outcome = recorder.handle(kind: kind, keyCode: key, flags: flags) { return outcome }
        }
        return nil
    }

    @Test func aKeyPressedWithModifiersRecordsTheCombination() {
        let control: UInt64 = 0x4_0001, command: UInt64 = 0x10_0008
        #expect(record([(.flagsChanged, 59, control), (.flagsChanged, 55, control | command), (.keyDown, 9, control | command)])
            == .recorded(.pasteLast))
    }

    @Test func aModifierLetGoOnItsOwnRecordsThatKey() {
        #expect(record([(.flagsChanged, 63, 0x80_0000), (.flagsChanged, 63, 0)]) == .recorded(.fn))
        #expect(record([(.flagsChanged, 61, 0x8_0040), (.flagsChanged, 61, 0)]) == .recorded(Shortcut(key: 61)))
    }

    @Test func aModifierLetGoWithAnotherStillHeldKeepsTheOther() {
        let command: UInt64 = 0x10_0008, rightOption: UInt64 = 0x8_0040
        let events: [(KeyInput.EventKind, Int, UInt64)] = [
            (.flagsChanged, 55, command), (.flagsChanged, 61, command | rightOption), (.flagsChanged, 61, command),
        ]
        #expect(record(events) == .recorded(Shortcut(key: 61, modifiers: [.command])))
    }

    @Test func escapeCancelsAndATypingKeyAloneIsRejected() {
        #expect(record([(.keyDown, 53, 0)]) == .cancelled)
        #expect(record([(.keyDown, 0, 0)]) == .rejected("Add Control, Option or Command, so A still types."))
        #expect(record([(.flagsChanged, 57, 0x1_0000)]) == .rejected("Caps Lock can't be a shortcut."))
        #expect(record([(.keyDown, 96, 0x80_0000)]) == .recorded(Shortcut(key: 96)))
    }
}

@Suite("Settings") struct SettingsTests {
    @Test func storedSettingsMissingKeysTakeTheDefaults() throws {
        let stored = try JSONDecoder().decode(Settings.self, from: Data(#"{"sounds": false, "barEdge": "right"}"#.utf8))
        var expected = Settings()
        expected.sounds = false
        expected.barEdge = .right
        #expect(stored == expected)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var settings = Settings()
        settings.microphone = .device(uid: "AppleUSBAudioEngine:Shure Inc:Shure MV7+", name: "Shure MV7+")
        settings.hotkeys = [Shortcut(key: 61), Shortcut(key: 49, modifiers: [.option])]
        settings.pasteLast = nil
        settings.vocabularyEnabled = false
        settings.sounds = false
        settings.barEdge = .left
        settings.hideBarWhenIdle = false
        settings.keepHistory = false
        settings.showMenuBarIcon = false
        settings.smartSpacing = false
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func hotkeysStoredByTheFirstVersionsStillLoad() throws {
        let stored = try JSONDecoder().decode(Settings.self, from: Data(#"{"hotkeys": ["rightControl", "fn"]}"#.utf8))
        #expect(stored.hotkeys == [.rightControl, .fn])
        #expect(stored.pasteLast == .pasteLast, "a value saved before the setting existed gets the default")
        let empty = try JSONDecoder().decode(Settings.self, from: Data(#"{"hotkeys": []}"#.utf8))
        #expect(empty.hotkeys == Settings().hotkeys)
        let twice = try JSONDecoder().decode(Settings.self, from: Data(#"{"hotkeys": ["fn", {"key": 63, "modifiers": 0}]}"#.utf8))
        #expect(twice.hotkeys == [.fn])
    }

    @Test func dictationKeysCanBeAddedReplacedAndRemovedButNotAll() {
        var settings = Settings()
        let optionSpace = Shortcut(key: 49, modifiers: [.option])
        #expect(settings.setHotkey(optionSpace) == nil)
        #expect(settings.hotkeys == [.fn, .rightControl, optionSpace])
        #expect(settings.setHotkey(Shortcut(key: 96), replacing: .rightControl) == nil)
        #expect(settings.hotkeys == [.fn, Shortcut(key: 96), optionSpace])
        #expect(settings.setHotkey(.fn) == "fn is already a dictation key.")
        #expect(settings.setHotkey(.pasteLast) == "⌃⌘V already pastes your last dictation.")
        #expect(settings.setHotkey(Shortcut(key: 0)) != nil)
        settings.removeHotkey(.fn)
        settings.removeHotkey(Shortcut(key: 96))
        settings.removeHotkey(optionSpace)
        #expect(settings.hotkeys == [optionSpace])
    }

    @Test func thePasteShortcutNeedsAKeyAndCanBeTurnedOff() {
        var settings = Settings()
        #expect(settings.setPasteLast(Shortcut(key: 61)) != nil)
        #expect(settings.setPasteLast(.fn) != nil)
        #expect(settings.setPasteLast(Shortcut(key: 9, modifiers: [.option, .command])) == nil)
        #expect(settings.pasteLast?.title == "⌥⌘V")
        #expect(settings.setPasteLast(nil) == nil)
        #expect(settings.pasteLast == nil)
    }
}

@Suite("Cleanup rules") struct CleanupTests {
    let cleanup = Cleanup(properNouns: ["Tailscale"] + Cleanup.calendarNames)

    @Test func removesFillersAndCapitalizes() {
        #expect(cleanup.apply("um so i think, uh, we should go") == "So I think we should go.")
    }

    @Test func questionStartsEndWithQuestionMark() {
        #expect(cleanup.apply("can you check the tailscale node") == "Can you check the Tailscale node?")
    }

    @Test func calendarCasingSkipsMay() {
        #expect(cleanup.apply("we may meet in may on friday") == "We may meet in may on Friday.")
    }

    @Test func youKnowBetweenCommasBecomesOneCommaAndIsKeptMidSentence() {
        #expect(cleanup.apply("so, you know, it works") == "So, it works.")
        #expect(cleanup.apply("it works, you know") == "It works.")
        #expect(cleanup.apply("it works you know") == "It works you know.")
    }

    @Test func tidiesSpacingAndRepeatedPunctuation() {
        #expect(cleanup.apply("Hello , world ,, again ;; done") == "Hello, world, again; done.")
    }

    @Test func fillerOnlyDictationBecomesEmpty() {
        #expect(cleanup.apply("um, uh") == "")
    }

    @Test(arguments: cleanupFixtures.indices)
    func matchesThePythonReference(_ index: Int) {
        let reference = Cleanup(properNouns: cleanupFixtureProperNouns)
        let fixture = cleanupFixtures[index]
        #expect(reference.apply(fixture.input) == fixture.expected, "input: \(fixture.input)")
    }
}

@Suite("Alias replacement") struct AliasTests {
    let rules = AliasRules(terms: [.init(text: "Beehiiv", aliases: ["behive", "bee hive"]),
                                   .init(text: "Infisical", aliases: ["in physical"])])

    @Test func replacesWholeWordsKeepingSuffixAndPunctuation() {
        #expect(rules.apply("check behive's key in physical, then") == "check Beehiiv's key Infisical, then")
    }

    @Test func isCaseInsensitiveAndToleratesExtraSpaces() {
        #expect(rules.apply("Bee  Hive. In Physical?") == "Beehiiv. Infisical?")
    }

    @Test func leavesLongerWordsAlone() {
        #expect(rules.apply("behives and abehive") == "behives and abehive")
    }

    @Test func longestAliasWins() {
        let overlapping = AliasRules(terms: [.init(text: "Pi", aliases: ["pie"]), .init(text: "PieChart", aliases: ["pie chart"])])
        #expect(overlapping.apply("a pie chart and a pie") == "a PieChart and a Pi")
    }

    @Test func finisherWithVocabularyOffAppliesNoAliasesButKeepsCalendarCasing() {
        let off = TextFinisher(vocabulary: nil)
        #expect(off.finish(raw: "send it to behive on friday", boosted: nil) == "Send it to behive on Friday.")
    }
}

@Suite("Punctuation restore after boosting") struct PunctuationTests {
    @Test func carriesTheCommaTheReplacementSwallowed() {
        #expect(PunctuationRestore.restore(raw: "ask profit pilot, put it", boosted: "ask ProfitPilot put it")
            == "ask ProfitPilot, put it")
    }

    @Test func carriesSentenceEndWithoutDuplicating() {
        #expect(PunctuationRestore.restore(raw: "launch it in bee hive.", boosted: "launch it in Beehiiv") == "launch it in Beehiiv.")
        #expect(PunctuationRestore.restore(raw: "launch it in bee hive.", boosted: "launch it in Beehiiv.") == "launch it in Beehiiv.")
    }

    @Test func handlesTwoReplacementsAndOneAtTheStart() {
        #expect(PunctuationRestore.restore(raw: "bee hive, then profit pilot. Done", boosted: "Beehiiv then ProfitPilot Done")
            == "Beehiiv, then ProfitPilot. Done")
    }

    @Test func nothingReplacedLeavesTheBoostedTextAlone() {
        #expect(PunctuationRestore.restore(raw: "all good here.", boosted: "all good here.") == "all good here.")
    }

    @Test func finisherRestoresThenAliasesThenCleans() {
        let finisher = TextFinisher(vocabulary: Vocabulary(terms: [.init(text: "ProfitPilot"), .init(text: "Infisical", aliases: ["in physical"])]))
        let text = finisher.finish(raw: "um ask profit pilot, then rotate in physical tokens", boosted: "um ask ProfitPilot then rotate in physical tokens")
        #expect(text == "Ask ProfitPilot, then rotate Infisical tokens.")
    }
}

/// An in-memory pasteboard that records whether its current text carries the transient marker.
private final class FakePasteboard: Pasteboard {
    private(set) var changeCount = 0
    private(set) var items: [[String: Data]] = []
    static let transientType = "org.nspasteboard.TransientType"

    init(text: String? = nil) {
        if let text { items = [["public.utf8-plain-text": Data(text.utf8)]] }
    }

    var text: String? { items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
    var isTransient: Bool { items.first?[Self.transientType] != nil }

    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: items) }

    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items
        changeCount += 1
    }

    func write(_ text: String, transient: Bool) {
        var item = ["public.utf8-plain-text": Data(text.utf8)]
        if transient { item[Self.transientType] = Data() }
        items = [item]
        changeCount += 1
    }

    /// Another app copying something.
    func userCopies(_ text: String) { write(text, transient: false) }
}

@Suite("Clipboard restore") struct ClipboardTests {
    @Test func restoresEveryItemAndTypeAfterAPaste() throws {
        let original = [["public.utf8-plain-text": Data("mine".utf8), "public.rtf": Data("{\\rtf1 mine}".utf8)],
                        ["public.png": Data([0x89, 0x50])]]
        let pb = FakePasteboard()
        pb.restore(PasteboardSnapshot(items: original))
        var transaction = ClipboardTransaction()
        var pastedText: String?
        let ticket = try #require(transaction.paste("dictated", on: pb) { pastedText = pb.text; return true })
        #expect(pastedText == "dictated")
        #expect(pb.isTransient)
        transaction.restore(ticket, on: pb)
        #expect(pb.items == original)
    }

    @Test func aCopyDuringTheSettleWindowIsNotOverwritten() throws {
        let pb = FakePasteboard(text: "mine")
        var transaction = ClipboardTransaction()
        let ticket = try #require(transaction.paste("dictated", on: pb) { true })
        pb.userCopies("copied meanwhile")
        transaction.restore(ticket, on: pb)
        #expect(pb.text == "copied meanwhile")
    }

    @Test func failedPostKeepsTheTextWithoutTheTransientMarker() {
        let pb = FakePasteboard(text: "mine")
        var transaction = ClipboardTransaction()
        #expect(transaction.paste("dictated", on: pb) { false } == nil)
        #expect(pb.text == "dictated")
        #expect(!pb.isTransient)
    }

    @Test func backToBackPastesRestoreTheUsersOriginal() throws {
        let pb = FakePasteboard(text: "mine")
        var transaction = ClipboardTransaction()
        let first = try #require(transaction.paste("first", on: pb) { true })
        let second = try #require(transaction.paste("second", on: pb) { true })
        transaction.restore(first, on: pb)
        #expect(pb.text == "second")
        transaction.restore(second, on: pb)
        #expect(pb.text == "mine")
    }

    @Test func aStaleTicketIsIgnoredAfterACopyOnly() throws {
        let pb = FakePasteboard(text: "mine")
        var transaction = ClipboardTransaction()
        let ticket = try #require(transaction.paste("pasted", on: pb) { true })
        transaction.copy("copied again from the menu", on: pb)
        transaction.restore(ticket, on: pb)
        #expect(pb.text == "copied again from the menu")
        #expect(!pb.isTransient)
    }

    @Test func emptyOriginalIsRestoredAsEmpty() throws {
        let pb = FakePasteboard()
        var transaction = ClipboardTransaction()
        let ticket = try #require(transaction.paste("dictated", on: pb) { true })
        transaction.restore(ticket, on: pb)
        #expect(pb.items.isEmpty)
    }
}

@Suite("Insert decision") struct InsertDecisionTests {
    let ready = InsertConditions(trusted: true, secureInput: false, sameFocus: true, waited: 0.3)

    @Test func pastesWhenNothingStandsInTheWay() {
        #expect(InsertDecision.decide(ready) == .paste)
        var atLimit = ready
        atLimit.waited = InsertDecision.maxWait
        #expect(InsertDecision.decide(atLimit) == .paste)
    }

    @Test func copiesForEachReason() {
        var c = ready
        c.trusted = false
        #expect(InsertDecision.decide(c) == .copyOnly(.notTrusted))
        c = ready
        c.secureInput = true
        #expect(InsertDecision.decide(c) == .copyOnly(.secureInput))
        c = ready
        c.sameFocus = false
        #expect(InsertDecision.decide(c) == .copyOnly(.focusMoved))
        c = ready
        c.waited = 10.5
        #expect(InsertDecision.decide(c) == .copyOnly(.waitedTooLong))
    }
}

@Suite("Vocabulary file") struct VocabularyTests {
    @Test func missingDirectiveMeansPointSeven() {
        #expect(Vocabulary.parse("Beehiiv").vocabulary.minSimilarity == 0.7)
    }

    @Test func readsTheDirectiveTermsAndAliases() {
        let (vocabulary, issues) = Vocabulary.parse("# names\n@min-similarity 0.85\n\nProfitPilot\nBeehiiv: behive , bee hive\r\n")
        #expect(issues.isEmpty)
        #expect(vocabulary == Vocabulary(terms: [.init(text: "ProfitPilot"), .init(text: "Beehiiv", aliases: ["behive", "bee hive"])],
                                         minSimilarity: 0.85))
    }

    @Test func badLinesBecomeIssuesWithLineNumbersAndAreSkipped() {
        let file = "Hermes\n@min-similarity 0.2\n: orphan\nBeehiiv: behive,\n@max-terms 4\nhermes\nCodex"
        let (vocabulary, issues) = Vocabulary.parse(file)
        #expect(vocabulary.terms.map(\.text) == ["Hermes", "Codex"])
        #expect(vocabulary.minSimilarity == 0.7)
        #expect(issues.map(\.line) == [2, 3, 4, 5, 6])
    }

    @Test func bundledDefaultParsesCleanWithTheBakeoffTermsAndAliases() {
        let (vocabulary, issues) = Vocabulary.parse(Vocabulary.bundledDefault)
        #expect(issues.isEmpty)
        #expect(vocabulary.minSimilarity == 0.7)
        #expect(vocabulary.terms.map(\.text) == Array(cleanupFixtureProperNouns.prefix(13)))
        #expect(vocabulary.terms.first { $0.text == "Beehiiv" }?.aliases == ["behive", "beehive", "bee hive"])
        #expect(vocabulary.terms.first { $0.text == "Infisical" }?.aliases == ["in physical", "infisical"])
    }
}

@Suite("Sound cues") struct CueTests {
    @Test func startPlaysWhenTheBarFirstShowsNotAtKeyDown() {
        #expect(Cue.after([.start], wasListening: false, isListening: false) == nil)
        #expect(Cue.after([], wasListening: false, isListening: true) == .start)
        #expect(Cue.after([], wasListening: true, isListening: true) == nil)
    }

    @Test func finishStopsAndOnlyASeenCaptureMakesTheCancelSound() {
        #expect(Cue.after([.finish], wasListening: true, isListening: false) == .stop)
        #expect(Cue.after([.cancel], wasListening: true, isListening: false) == .cancel)
        #expect(Cue.after([.cancel], wasListening: false, isListening: false) == nil)
        #expect(Cue.after([.finish], wasListening: false, isListening: false) == nil)
    }

    @Test func aChordBeforeTheBarDelayIsSilentFromPressToRelease() {
        var machine = HotkeyMachine.idle
        let timing = HotkeyTiming()
        var cues: [Cue] = []
        for input in [KeyInput.hotkeyDown(t(0)), .otherKey(t(0.05), isEscape: false), .hotkeyUp(t(0.2))] {
            let before = machine.showsListening
            let step = machine.handle(input, timing: timing)
            if let cue = Cue.after(step.commands, wasListening: before, isListening: machine.showsListening) { cues.append(cue) }
        }
        #expect(cues.isEmpty)
    }
}

@Suite("Bar state") struct BarStateTests {
    let listening = HotkeyMachine.pressed(since: t(0), shown: true)
    let ready = EngineStatus.ready(boosting: .on(terms: 13))
    let notice = BarNotice.copied(.focusMoved)

    @Test func bodyPriorityIsListeningThenPendingThenLoadingThenIdle() {
        let loading = EngineStatus.loading(.compiling)
        #expect(BarState.derive(hotkey: listening, words: "hi", pending: 1, engine: loading, notice: notice, showsIdle: true)
            == BarState(body: .listening(words: "hi", handsFree: false), toast: notice))
        #expect(BarState.derive(hotkey: .idle, words: "hi", pending: 1, engine: loading, notice: nil, showsIdle: true).body
            == .transcribing(words: "hi", waitingOn: .compiling))
        #expect(BarState.derive(hotkey: .idle, words: "hi", pending: 1, engine: ready, notice: nil, showsIdle: true).body
            == .transcribing(words: "hi", waitingOn: nil))
        #expect(BarState.derive(hotkey: .idle, words: "", pending: 0, engine: loading, notice: notice, showsIdle: true)
            == BarState(body: .preparing(.compiling), toast: notice))
        #expect(BarState.derive(hotkey: .idle, words: "", pending: 0, engine: ready, notice: nil, showsIdle: true).body == .idle)
        #expect(BarState.derive(hotkey: .idle, words: "", pending: 0, engine: ready, notice: nil, showsIdle: false).body == .hidden)
    }

    @Test func handsFreeIsShownAsSuchAndAnUnshownPressStaysHidden() {
        #expect(BarState.derive(hotkey: .handsFree(captureStart: t(0)), words: "", pending: 0, engine: ready, notice: nil,
                                showsIdle: false).body == .listening(words: "", handsFree: true))
        #expect(BarState.derive(hotkey: .pressed(since: t(0), shown: false), words: "", pending: 0, engine: ready, notice: nil,
                                showsIdle: false).body == .hidden)
    }

    @Test func aDictationWaitingOnAFailedModelGetsARetryToastOverAnyOtherNotice() {
        let state = BarState.derive(hotkey: .idle, words: "hi", pending: 1, engine: .failed("no network"), notice: notice,
                                    showsIdle: false)
        #expect(state == BarState(body: .hidden, toast: .modelFailed("no network")))
        #expect(state.toast?.detail == "no network")
        #expect(state.toast?.tone == .failure)
        #expect(state.toast?.action == .retryModel)
        #expect(notice.action == nil)
    }

    @Test func aMissingMicrophoneToastNamesBothDevicesAsAWarning() {
        let missing = BarNotice.microphoneMissing(chosen: "Shure MV7+", using: "MacBook Pro Microphone")
        #expect(missing.title == "Shure MV7+ isn't connected")
        #expect(missing.detail == "Using MacBook Pro Microphone until it's back.")
        #expect(missing.tone == .warning)
    }

    @Test func aCopiedToastSaysWhyItCouldNotPaste() {
        #expect(BarNotice.copied(.secureInput).title == "Copied. Press ⌘V to paste.")
        #expect(BarNotice.copied(.secureInput).detail == "A password field doesn't allow pasting.")
        #expect(BarNotice.copied(.focusMoved).detail != BarNotice.copied(.waitedTooLong).detail)
        #expect(BarNotice.copied(.notTrusted).tone == .info)
    }
}

@Suite("Bar placement") struct BarPlacementTests {
    let screen = BarRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func topAndBottomCenterTheBodyAndSidesHugTheirEdge() {
        #expect(BarEdge.bottom.place(width: 200, height: 40, in: screen, inset: 16) == BarRect(x: 620, y: 56, width: 200, height: 40))
        #expect(BarEdge.top.place(width: 200, height: 40, in: screen, inset: 16) == BarRect(x: 620, y: 844, width: 200, height: 40))
        #expect(BarEdge.left.place(width: 200, height: 40, in: screen, inset: 8) == BarRect(x: 8, y: 450, width: 200, height: 40))
        #expect(BarEdge.right.place(width: 200, height: 40, in: screen, inset: 8) == BarRect(x: 1232, y: 450, width: 200, height: 40))
    }

    @Test func aSideBodyGrowsAwayFromItsEdge() {
        let narrow = BarEdge.right.place(width: 100, height: 40, in: screen, inset: 8)
        let wide = BarEdge.right.place(width: 400, height: 40, in: screen, inset: 8)
        #expect(narrow.maxX == wide.maxX)
        #expect(BarEdge.left.place(width: 100, height: 40, in: screen, inset: 8).minX
            == BarEdge.left.place(width: 400, height: 40, in: screen, inset: 8).minX)
    }

    @Test func toastsSitAboveTheBodyExceptOnTheTopEdgeAndAlignLikeIt() {
        let body = BarRect(x: 1232, y: 450, width: 200, height: 40)
        #expect(BarEdge.right.placeToast(width: 300, height: 30, against: body, gap: 8) == BarRect(x: 1132, y: 498, width: 300, height: 30))
        #expect(BarEdge.left.placeToast(width: 300, height: 30, against: body, gap: 8).minX == body.minX)
        #expect(BarEdge.top.placeToast(width: 100, height: 30, against: body, gap: 8) == BarRect(x: 1282, y: 412, width: 100, height: 30))
    }

    @Test func aDropSnapsToTheNearestEdgeMiddle() {
        #expect(BarEdge.nearest(x: 700, y: 60, in: screen) == .bottom)
        #expect(BarEdge.nearest(x: 700, y: 880, in: screen) == .top)
        #expect(BarEdge.nearest(x: 30, y: 400, in: screen) == .left)
        #expect(BarEdge.nearest(x: 1400, y: 820, in: screen) == .right)
    }
}

@Suite("Microphone choice") struct MicrophoneChoiceTests {
    @Test func aChosenDeviceIsUsedWhenConnectedAndFallsBackByNameWhenNot() {
        let shure = MicrophoneChoice.device(uid: "AppleUSBAudioEngine:Shure", name: "Shure MV7+")
        #expect(shure.source(connected: ["BuiltInMic", "AppleUSBAudioEngine:Shure"]) == .device(uid: "AppleUSBAudioEngine:Shure"))
        #expect(shure.source(connected: ["BuiltInMic"]) == .fallback(missing: "Shure MV7+"))
        #expect(MicrophoneChoice.systemDefault.source(connected: []) == .systemDefault)
    }

    @Test func anUnpluggedMicrophoneIsMentionedOnceUntilItIsSeenAgain() {
        let shure = MicrophoneSource.fallback(missing: "Shure MV7+")
        var missing = MissingMicrophone()
        #expect(missing.toMention(for: shure) == "Shure MV7+")
        #expect(missing.toMention(for: shure) == "Shure MV7+", "a chord that never showed the bar does not count")
        missing.didMention("Shure MV7+")
        #expect(missing.toMention(for: shure) == nil)
        #expect(missing.toMention(for: .fallback(missing: "AirPods Pro")) == "AirPods Pro")
        #expect(missing.toMention(for: shure) == nil)
        #expect(missing.toMention(for: .device(uid: "AppleUSBAudioEngine:Shure")) == nil)
        #expect(missing.toMention(for: shure) == "Shure MV7+", "unplugged again after it was back")
        missing.didMention("Shure MV7+")
        #expect(missing.toMention(for: .systemDefault) == nil)
        #expect(missing.toMention(for: shure) == "Shure MV7+", "chosen again after System Default")
    }
}

@Suite("Boosting windows") struct CtcWindowTests {
    @Test func audioUpToFifteenSecondsIsOneWindow() {
        #expect(CtcWindows.ranges(count: 16_000) == [0..<16_000])
        #expect(CtcWindows.ranges(count: 240_000) == [0..<240_000])
    }

    @Test func longerAudioRunsFifteenSecondWindowsEveryThirteenSeconds() {
        #expect(CtcWindows.ranges(count: 500_000) == [0..<240_000, 208_000..<448_000, 416_000..<500_000])
        #expect(CtcWindows.ranges(count: 448_000) == [0..<240_000, 208_000..<448_000])
    }

    @Test func aWindowCompletedWhileHeldIsTheSameWindowAtRelease() {
        for count in [240_000, 240_001, 447_999, 448_000, 448_001, 1_744_000] {
            for (index, range) in CtcWindows.ranges(count: count).enumerated() where CtcWindows.window(index).upperBound <= count {
                #expect(range == CtcWindows.window(index), "count \(count), window \(index)")
            }
        }
    }

    @Test func overlappingFramesAverageInProbabilitySpace() {
        let first = Array(repeating: [Float(log(0.2)), Float(log(0.8))], count: 40)
        let second = Array(repeating: [Float(log(0.6)), Float(log(0.4))], count: 40)
        let merged = CtcWindows.merge([first, second], frameDuration: 0.0625, sampleRate: 16_000)
        #expect(merged.count == 48)
        #expect(merged[7] == first[7])
        #expect(abs(exp(Double(merged[8][0])) - 0.4) < 1e-6)
        #expect(abs(exp(Double(merged[39][1])) - 0.6) < 1e-6)
        #expect(merged[40] == second[32])
    }

    @Test func oneWindowIsReturnedAsIs() {
        let frames: [[Float]] = [[-1, -2], [-3, -4]]
        #expect(CtcWindows.merge([frames], frameDuration: 0.08, sampleRate: 16_000) == frames)
    }
}
