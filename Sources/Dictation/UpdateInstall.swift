import AppKit
import DictationCore
import Foundation
import Security
import os

/// Installs a newer release from inside the app. It downloads the release's zip, unpacks it beside the installed app,
/// and installs only if the app inside is this app at the offered version, signed by the same Apple team with a
/// Developer ID certificate, and accepted by Gatekeeper, which means Apple notarized it. Then it quits, and a one-shot
/// launchd job swaps the bundle and opens the new one. Nothing is installed without the person clicking Update.
///
/// A build with no Developer ID signature of its own, such as one built from source, has no team to match, so it
/// offers the release page as before.
enum UpdateInstall {
    static let jobLabel = "com.hunterbohm.dictation.update"
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "update")
    private static let sizeLimit: Int64 = 400 << 20
    private static let stagingPrefix = ".lip-service-update."

    /// The requirement every update must meet, from the running app's own Developer ID signature. Nil when the running app
    /// has none, or when its signature does not satisfy the requirement it would hold updates to.
    static func requirement() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier, let code = selfStaticCode() else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let text = SignedUpdate.requirement(teamID: team, bundleID: bundleID) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        return text
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running, SecCodeCopyStaticCode(running, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// Whether this copy can update itself in place: it holds a Developer ID signature and sits where it can be replaced.
    static func isAvailable() -> Bool {
        guard requirement() != nil else { return false }
        let app = Bundle.main.bundleURL
        return SignedUpdate.canReplace(at: app, parentWritable: FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path))
    }

    /// Downloads, checks and hands over to the install job, then asks the app to quit. Throws a message for the person.
    @MainActor static func install(_ release: Release, running: Version) async throws {
        guard let archive = release.archive, let requirement = requirement() else { throw DictationError("This copy can't update itself. Use Release page.") }
        let app = Bundle.main.bundleURL
        guard let bundleID = Bundle.main.bundleIdentifier,
              SignedUpdate.canReplace(at: app, parentWritable: FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)) else {
            throw DictationError("Lip Service can't replace itself where it is. Move it to Applications and open it from there.")
        }
        let folder = SupportFolder.url.appending(path: "update", directoryHint: .isDirectory)
        let parent = app.deletingLastPathComponent()
        removeStaleStaging(in: parent)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appending(path: stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var handedOver = false
        defer {
            try? FileManager.default.removeItem(at: folder.appending(path: "download.zip"))
            if !handedOver { try? FileManager.default.removeItem(at: staging) }
        }
        do {
            let zip = folder.appending(path: "download.zip")
            try await download(archive, to: zip)
            let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            let unzip = try await run(SignedUpdate.unzip(zip, into: unpacked))
            guard unzip.status == 0 else { throw SignedUpdate.Refusal.notAnApp(unzip.text) }
            let items = try FileManager.default.contentsOfDirectory(atPath: unpacked.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            guard items.count == 1, let name = items.first, name.hasSuffix(".app") else {
                throw SignedUpdate.Refusal.notAnApp("expected one app, found \(items.sorted())")
            }
            // Hold the app at a fixed name inside a folder only this install uses, so nothing else can swap it between the checks and the install.
            let candidate = staging.appending(path: "Lip Service.app")
            try FileManager.default.moveItem(at: unpacked.appending(path: name), to: candidate)
            try? FileManager.default.removeItem(at: unpacked)
            let info = (FileManager.default.contents(atPath: candidate.appending(path: "Contents/Info.plist").path))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            try SignedUpdate.vet(info: info, bundleID: bundleID, offered: release.version, running: running)
            let signature = try await run(SignedUpdate.verifySignature(candidate, requirement: requirement))
            guard signature.status == 0 else { throw SignedUpdate.Refusal.signature(signature.text) }
            let gatekeeper = try await run(SignedUpdate.assess(candidate))
            guard gatekeeper.status == 0 else { throw SignedUpdate.Refusal.gatekeeper(gatekeeper.text) }

            let plist = folder.appending(path: "install.plist")
            let log = folder.appending(path: "install.log")
            let job = SignedUpdate.job(label: jobLabel, pid: ProcessInfo.processInfo.processIdentifier, new: candidate, destination: app, log: log)
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
            let started = try await Process.runToEnd("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path], input: Data(), timeout: 30)
            guard started.status == 0 else {
                throw DictationError("macOS would not start the installer: " + String(decoding: started.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            handedOver = true
        } catch let refusal as SignedUpdate.Refusal {
            log.error("update refused: \(refusal.description, privacy: .public)")
            throw DictationError(refusal.description)
        }
        NSApp.terminate(nil)
    }

    /// An earlier attempt that was killed leaves its folder beside the app.
    private static func removeStaleStaging(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) { try? FileManager.default.removeItem(at: parent.appending(path: name)) }
    }

    private static func download(_ url: URL, to file: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        var request = URLRequest(url: url)
        request.setValue("Lip Service", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DictationError("GitHub answered \(status) for the download.") }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard size > 0, size <= sizeLimit else { throw DictationError("The download is \(size) bytes, which is not a Lip Service release.") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private struct Ran { var status: Int32; var text: String }

    private static func run(_ command: SignedUpdate.Command) async throws -> Ran {
        let done = try await Process.runToEnd(command.executable, command.arguments, input: Data(), timeout: command.timeout)
        let text = String(decoding: done.output.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if done.timedOut { return Ran(status: -1, text: "timed out") }
        return Ran(status: done.status, text: text.isEmpty ? "exit \(done.status)" : text)
    }
}
