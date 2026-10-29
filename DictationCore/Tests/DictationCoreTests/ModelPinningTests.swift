import CryptoKit
import Foundation
import Testing
@testable import DictationCore

/// A small model folder on disk and the table that describes it.
private struct Fixture {
    let directory: URL
    let model: PinnedModel

    static let contents: [String: String] = [
        "Encoder.mlmodelc/coremldata.bin": "encoder header",
        "Encoder.mlmodelc/weights/weight.bin": String(repeating: "weights", count: 1000),
        "Decoder.mlmodelc/model.mil": "decoder program",
        "vocab.json": "{\"0\": \"a\"}",
    ]

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "model-check-\(UUID().uuidString)")
        for (path, text) in Self.contents { try Self.write(text, to: path, in: directory) }
        self.directory = directory
        let files = Self.contents.keys.sorted().map { path in
            let data = Data(Self.contents[path]!.utf8)
            return ModelFile(path, size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        model = PinnedModel(repo: "owner/repo", commit: String(repeating: "a", count: 40), folder: "model", files: files)
    }

    private static func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func write(_ text: String, to path: String) throws { try Self.write(text, to: path, in: directory) }

    func problems() -> [ModelProblem] { ModelCheck.problems(in: directory, for: model) }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Pinned models") struct ModelPinningTests {
    @Test func aFolderThatMatchesHasNoProblems() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.problems().isEmpty)
    }

    @Test func aChangedByteIsAWrongHash() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var text = Fixture.contents["Encoder.mlmodelc/weights/weight.bin"]!
        text.replaceSubrange(text.startIndex...text.startIndex, with: "W")
        try fixture.write(text, to: "Encoder.mlmodelc/weights/weight.bin")
        #expect(fixture.problems() == [.wrongHash("Encoder.mlmodelc/weights/weight.bin")])
    }

    @Test func aFileOfAnotherLengthIsAWrongSize() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("short", to: "Decoder.mlmodelc/model.mil")
        #expect(fixture.problems() == [.wrongSize("Decoder.mlmodelc/model.mil", expected: 15, actual: 5)])
    }

    @Test func aMissingFileIsReported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "vocab.json"))
        #expect(fixture.problems() == [.missing("vocab.json")])
    }

    @Test func aMissingFolderMissesEveryFile() {
        let model = PinnedModel(repo: "owner/repo", commit: String(repeating: "a", count: 40), folder: "model",
                                files: [ModelFile("a.json", size: 1, sha256: "x"), ModelFile("B.mlmodelc/c", size: 1, sha256: "x")])
        let problems = ModelCheck.problems(in: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), for: model)
        #expect(problems == [.missing("a.json"), .missing("B.mlmodelc/c")])
    }

    @Test func anExtraFileInsideABundleIsUnexpected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("payload", to: "Encoder.mlmodelc/weights/extra.bin")
        try fixture.write("payload", to: "Decoder.mlmodelc/analytics/new.bin")
        #expect(fixture.problems() == [.unexpected("Decoder.mlmodelc/analytics/new.bin"),
                                       .unexpected("Encoder.mlmodelc/weights/extra.bin")])
    }

    @Test func aFileOutsideEveryBundleIsLeftAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("1234\n", to: ".fluidaudio-revision")
        try fixture.write("x", to: "README.md")
        #expect(fixture.problems().isEmpty)
    }

    @Test func aSymbolicLinkIsNeverAListedFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.directory.appending(path: "Decoder.mlmodelc/model.mil")
        let elsewhere = fixture.directory.appending(path: "vocab.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
        let problems = fixture.problems()
        #expect(problems == [.notRegular("Decoder.mlmodelc/model.mil")])
        #expect(!ModelCheck.canResume(problems))
    }

    @Test func aFolderInPlaceOfAListedFileIsNotRegular() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.directory.appending(path: "vocab.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(fixture.problems() == [.notRegular("vocab.json")])
    }

    @Test func aBundleThatIsALinkCannotBeListed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = fixture.directory.appending(path: "Decoder.mlmodelc")
        let elsewhere = fixture.directory.appending(path: "Elsewhere.mlmodelc")
        try FileManager.default.moveItem(at: bundle, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: elsewhere)
        #expect(fixture.problems() == [.unreadable("Decoder.mlmodelc")])
    }

    @Test(.enabled(if: getuid() != 0)) func aFolderThatCannotBeListedIsAProblem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("payload", to: "Decoder.mlmodelc/cache/extra.bin")
        let hidden = fixture.directory.appending(path: "Decoder.mlmodelc/cache")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }
        #expect(fixture.problems() == [.unreadable("Decoder.mlmodelc/cache")])
    }

    @Test func aSymbolicLinkInsideABundleIsUnexpected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(
            at: fixture.directory.appending(path: "Decoder.mlmodelc/link"), withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(fixture.problems() == [.unexpected("Decoder.mlmodelc/link")])
    }

    @Test func hashingMatchesTheStandardTestVector() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("abc", to: "vocab.json")
        #expect(ModelCheck.sha256(of: fixture.directory.appending(path: "vocab.json"))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func aPartialFileOfAMissingFileIsAnInterruptedDownload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "Encoder.mlmodelc/weights/weight.bin"))
        try fixture.write("half", to: "Encoder.mlmodelc/weights/weight.bin.partial")
        try fixture.write("\"tag\"", to: "Encoder.mlmodelc/weights/weight.bin.partial.etag")
        let problems = fixture.problems()
        #expect(problems == [.missing("Encoder.mlmodelc/weights/weight.bin"),
                             .interrupted("Encoder.mlmodelc/weights/weight.bin.partial"),
                             .interrupted("Encoder.mlmodelc/weights/weight.bin.partial.etag")])
        #expect(ModelCheck.canResume(problems))
    }

    @Test func aPartialFileBesideItsFinishedFileIsCorruption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("half", to: "Encoder.mlmodelc/weights/weight.bin.partial")
        let problems = fixture.problems()
        #expect(problems == [.orphanPartial("Encoder.mlmodelc/weights/weight.bin.partial")])
        #expect(!ModelCheck.canResume(problems))
    }

    @Test func aPartialFileOfAnUnlistedFileIsCorruption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("half", to: "Decoder.mlmodelc/other.bin.partial.etag")
        #expect(fixture.problems() == [.orphanPartial("Decoder.mlmodelc/other.bin.partial.etag")])
    }

    @Test func aPartialFileBesideAFileThatIsNotRegularIsCorruption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.directory.appending(path: "Decoder.mlmodelc/model.mil")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.directory.appending(path: "vocab.json"))
        try fixture.write("half", to: "Decoder.mlmodelc/model.mil.partial")
        let problems = fixture.problems()
        #expect(problems == [.notRegular("Decoder.mlmodelc/model.mil"), .orphanPartial("Decoder.mlmodelc/model.mil.partial")])
        #expect(!ModelCheck.canResume(problems))
    }

    @Test func onlyAnInterruptedDownloadIsWorthKeeping() {
        #expect(ModelProblem.missing("a").isInterruptedDownload)
        #expect(ModelProblem.interrupted("a.partial").isInterruptedDownload)
        #expect(!ModelProblem.orphanPartial("a.partial").isInterruptedDownload)
        #expect(!ModelProblem.unexpected("B.mlmodelc/w").isInterruptedDownload)
        #expect(!ModelProblem.notRegular("a").isInterruptedDownload)
        #expect(!ModelProblem.unreadable("a").isInterruptedDownload)
        #expect(!ModelProblem.wrongSize("a", expected: 1, actual: 2).isInterruptedDownload)
        #expect(!ModelProblem.wrongHash("a").isInterruptedDownload)
    }

    @Test func theCheckedInTableIsWellFormed() {
        let repos = PinnedModels.all.map(\.repo)
        #expect(Set(repos).count == repos.count)
        for model in PinnedModels.all {
            #expect(model.commit.count == 40 && model.commit.allSatisfy(\.isHexDigit) && model.commit == model.commit.lowercased())
            #expect(!model.bundles.isEmpty)
            #expect(Set(model.files.map(\.path)).count == model.files.count)
            for file in model.files {
                #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit) && file.sha256 == file.sha256.lowercased())
                #expect(file.size >= 0 && !file.path.hasPrefix("/") && !file.path.contains(".."))
            }
        }
    }
}
