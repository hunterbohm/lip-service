import Testing
@testable import DictationCore

@Suite("Starting a copy") struct LaunchTests {
    @Test func aCopyBesideAnotherCopyEnds() {
        for startedByLaunchd in [true, false] {
            for agentOn in [true, false] {
                #expect(Launch.decide(startedByLaunchd: startedByLaunchd, otherCopyRuns: true, agentOn: agentOn) == .yield)
            }
        }
    }

    @Test func launchdsCopyRuns() {
        #expect(Launch.decide(startedByLaunchd: true, otherCopyRuns: false, agentOn: true) == .run)
    }

    @Test func aCopyOpenedByHandPassesToTheAgentWhenItIsOn() {
        #expect(Launch.decide(startedByLaunchd: false, otherCopyRuns: false, agentOn: true) == .handToAgent)
    }

    @Test func aCopyOpenedByHandRunsAloneWhenTheAgentIsOff() {
        #expect(Launch.decide(startedByLaunchd: false, otherCopyRuns: false, agentOn: false) == .run)
    }
}

@Suite("Hand-over note") struct HandOverTests {
    @Test func aFreshNoteSaysWhyTheCopyBeforeHandedOver() {
        #expect(HandOver(note: "window", age: 1) == .window)
        #expect(HandOver(note: "opened", age: 29) == .opened)
    }

    @Test func aNoteFromAHandOverThatNeverFinishedIsIgnored() {
        #expect(HandOver(note: "window", age: 30) == nil)
        #expect(HandOver(note: "window", age: 3600) == nil)
    }

    @Test func aNoteInTheFutureOrOfAnUnknownKindIsIgnored() {
        #expect(HandOver(note: "window", age: -5) == nil)
        #expect(HandOver(note: "reopen", age: 1) == nil)
        #expect(HandOver(note: "", age: 1) == nil)
    }
}
