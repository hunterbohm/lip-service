import Testing
@testable import DictationCore

@Suite("Press Return") struct PressReturnTests {
    private static let seen = PressReturn.Check(sameFocus: true, exposesElement: true, pasteSeen: true, takesText: false,
                                                appStayedInFront: true, sincePaste: 0.1)

    private static func allows(_ change: (inout PressReturn.Check) -> Void) -> Bool {
        var check = seen
        change(&check)
        return PressReturn.allows(check)
    }

    @Test func aSeenPasteInTheSameFieldSends() {
        #expect(PressReturn.allows(Self.seen))
    }

    @Test func focusThatMovedNeverSends() {
        #expect(!Self.allows { $0.sameFocus = false })
    }

    @Test func anUnseenPasteSendsOnlyIntoATextElement() {
        #expect(!Self.allows { $0.pasteSeen = false })
        #expect(Self.allows { $0.pasteSeen = false; $0.takesText = true })
    }

    @Test func anAppWithNoFocusedElementSendsOnlyWhileItStayedInFront() {
        #expect(Self.allows { $0.exposesElement = false; $0.pasteSeen = false })
        #expect(!Self.allows { $0.exposesElement = false; $0.pasteSeen = false; $0.appStayedInFront = false })
    }

    @Test func aLateReturnIsSkipped() {
        #expect(Self.allows { $0.sincePaste = PressReturn.deadline })
        #expect(!Self.allows { $0.sincePaste = PressReturn.deadline + 0.01 })
    }
}

@Suite("Private apps") struct PrivateAppsTests {
    @Test func passwordManagersAndTheirEditionsAreNeverRead() {
        for id in ["com.1password.1password", "me.proton.pass.electron", "org.keepassxc.keepassxc", "com.nordsec.nordpass",
                   "in.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop.App", "com.keepersecurity.passwordmanager",
                   "com.callpod.keepermac.lite", "com.markmcguill.strongbox.mac.pro", "com.apple.Passwords"] {
            #expect(PrivateApps.contains(id), "\(id)")
        }
    }

    @Test func otherAppsAndUnknownOnes() {
        #expect(!PrivateApps.contains("com.apple.TextEdit"))
        #expect(!PrivateApps.contains("com.tinyspeck.slackmacgap"))
        #expect(PrivateApps.contains(nil))
    }
}

@Suite("Capture in progress") struct CaptureInProgressTests {
    @Test func aCaptureCountsFromKeyDownBeforeTheBarShows() {
        #expect(HotkeyMachine.pressed(since: Instant(seconds: 1), shown: false).isCapturing)
        #expect(!HotkeyMachine.pressed(since: Instant(seconds: 1), shown: false).showsListening)
        #expect(HotkeyMachine.handsFree(captureStart: Instant(seconds: 1)).isCapturing)
        #expect(!HotkeyMachine.idle.isCapturing)
        #expect(!HotkeyMachine.awaitingRelease.isCapturing)
    }
}
