import Foundation
import Testing
@testable import DictationCore

private func version(_ text: String) -> Version { Version(text)! }
private var info: [String: Any] { ["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.0.9"] }

@Suite("Signed update") struct SignedUpdateTests {
    @Test func theRequirementPinsTheTeamTheBundleAndDeveloperID() throws {
        let text = try #require(SignedUpdate.requirement(teamID: "ABCDE12345", bundleID: "com.example.app"))
        #expect(text.contains("anchor apple generic"))
        #expect(text.contains("identifier \"com.example.app\""))
        #expect(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(text.contains("field.1.2.840.113635.100.6.2.6"))
        #expect(text.contains("field.1.2.840.113635.100.6.1.13"))
    }

    @Test(arguments: ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE1234\"", "ABCDE 2345", "ÄBCDE12345"])
    func aTeamIdThatIsNotOneMakesNoRequirement(_ team: String) {
        #expect(SignedUpdate.requirement(teamID: team, bundleID: "com.example.app") == nil)
    }

    @Test(arguments: ["", "com.example.app\" or anchor apple", "com example", "a\nb"])
    func aBundleIdThatCouldBreakOutOfTheRequirementMakesNone(_ id: String) {
        #expect(SignedUpdate.requirement(teamID: "ABCDE12345", bundleID: id) == nil)
    }

    @Test func acceptsTheOfferedNewerVersionOfThisApp() throws {
        try SignedUpdate.vet(info: info, bundleID: "com.example.app", offered: version("1.0.9"), running: version("1.0.8"))
    }

    @Test func refusesAnotherApp() {
        var other = info
        other["CFBundleIdentifier"] = "com.example.other"
        #expect(throws: SignedUpdate.Refusal.identity("com.example.other")) {
            try SignedUpdate.vet(info: other, bundleID: "com.example.app", offered: version("1.0.9"), running: version("1.0.8"))
        }
    }

    @Test func refusesAVersionOtherThanTheOfferedOne() {
        #expect(throws: SignedUpdate.Refusal.version("1.0.9")) {
            try SignedUpdate.vet(info: info, bundleID: "com.example.app", offered: version("1.0.10"), running: version("1.0.8"))
        }
    }

    @Test func refusesAnOlderOrEqualAppSoAnUpdateCannotDowngrade() {
        for running in ["1.0.9", "1.0.10"] {
            #expect(throws: SignedUpdate.Refusal.version("1.0.9")) {
                try SignedUpdate.vet(info: info, bundleID: "com.example.app", offered: version("1.0.9"), running: version(running))
            }
        }
    }

    @Test func refusesAnAppWithNoInfoOrNoVersion() {
        #expect(throws: SignedUpdate.Refusal.notAnApp("no Info.plist")) {
            try SignedUpdate.vet(info: nil, bundleID: "com.example.app", offered: version("1.0.9"), running: version("1.0.8"))
        }
        #expect(throws: SignedUpdate.Refusal.version("unknown")) {
            try SignedUpdate.vet(info: ["CFBundleIdentifier": "com.example.app"], bundleID: "com.example.app", offered: version("1.0.9"), running: version("1.0.8"))
        }
    }

    @Test func theChecksRunTheSystemToolsAndKeepTheirMessages() {
        let app = URL(fileURLWithPath: "/tmp/x/Lip Service.app")
        let verify = SignedUpdate.verifySignature(app, requirement: "anchor apple")
        #expect(verify.executable == "/bin/bash")
        #expect(verify.arguments[1] == "\"$@\" 2>&1")
        #expect(Array(verify.arguments.suffix(7)) == ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=anchor apple", app.path])
        #expect(Array(SignedUpdate.assess(app).arguments.suffix(5)) == ["/usr/sbin/spctl", "--assess", "--type", "execute", app.path])
        #expect(Array(SignedUpdate.unzip(URL(fileURLWithPath: "/a.zip"), into: URL(fileURLWithPath: "/b")).arguments.suffix(5)) == ["/usr/bin/ditto", "-x", "-k", "/a.zip", "/b"])
    }

    @Test func theInstallJobWaitsForTheAppThenSwapsAndOpens() throws {
        let job = SignedUpdate.job(label: "x.update", pid: 42, new: URL(fileURLWithPath: "/Applications/.stage/Lip Service.app"),
                                   destination: URL(fileURLWithPath: "/Applications/Lip Service.app"), log: URL(fileURLWithPath: "/tmp/log"))
        let arguments = try #require(job["ProgramArguments"] as? [String])
        #expect(Array(arguments[4...]) == ["42", "/Applications/.stage/Lip Service.app", "/Applications/Lip Service.app", "x.update"])
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] == nil)
        #expect(SignedUpdate.installScript.contains("kill -0 \"$pid\""))
    }

    @Test func theInstallScriptSwapsTheBundleAndRestoresTheOldOneOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lip-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func make(_ path: String, _ mark: String) throws -> URL {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try mark.write(to: url.appending(path: "mark"), atomically: true, encoding: .utf8)
            return url
        }
        let destination = try make("Applications/Lip Service.app", "old")
        let new = try make("Applications/.stage/Lip Service.app", "new")
        // A script that treats `open` and `launchctl` as no-ops: the swap logic is what is under test.
        let script = SignedUpdate.installScript
            .replacingOccurrences(of: "/usr/bin/open \"$destination\"", with: "true")
            .replacingOccurrences(of: "/bin/launchctl bootout \"gui/$(id -u)/$job\"", with: "true")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "t", "999999", new.path, destination.path, "x"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: destination.appending(path: "mark"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: new.deletingLastPathComponent().path))

        let kept = try make("Kept/Lip Service.app", "old")
        // The stage folder exists, so the old app is moved aside; the candidate is missing, so the second move fails and the old app must come back.
        try FileManager.default.createDirectory(at: directory.appending(path: "Kept/.stage"), withIntermediateDirectories: true)
        let missing = directory.appending(path: "Kept/.stage/Lip Service.app")
        let failing = Process()
        failing.executableURL = URL(fileURLWithPath: "/bin/bash")
        failing.arguments = ["-c", script, "t", "999999", missing.path, kept.path, "x"]
        failing.standardOutput = FileHandle.nullDevice
        try failing.run()
        failing.waitUntilExit()
        #expect(try String(contentsOf: kept.appending(path: "mark"), encoding: .utf8) == "old")
    }

    @Test func anAppInTranslocationOrAReadOnlyFolderIsNotReplaced() {
        let app = URL(fileURLWithPath: "/Applications/Lip Service.app")
        #expect(SignedUpdate.canReplace(at: app, parentWritable: true))
        #expect(!SignedUpdate.canReplace(at: app, parentWritable: false))
        #expect(!SignedUpdate.canReplace(at: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Lip Service.app"), parentWritable: true))
    }
}
