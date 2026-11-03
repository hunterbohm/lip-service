import CoreML
import DictationCore
import Foundation
import os

/// Runs the smart formatting model: `Formatter.mlpackage`, RoBERTa's `vocab.json` and `merges.txt`, and
/// `formatter.json`. The published model goes in `Formatter/` in the support folder, downloaded from the GitHub release
/// that `PinnedFormatter` names and checked file by file against its table before Core ML reads it. A model you
/// trained yourself goes in `Formatter-local/` and is used as it is. Without either, dictation goes in as before. The
/// package is compiled once and the compiled copy kept beside it, so later launches only load it.
actor SmartFormatter {
    static let pinnedFolder = SupportFolder.url.appending(path: "Formatter", directoryHint: .isDirectory)
    static let localFolder = SupportFolder.url.appending(path: "Formatter-local", directoryHint: .isDirectory)
    private static let log = Logger(subsystem: "com.hunterbohm.dictation", category: "formatting")

    enum State: Equatable {
        case notInstalled
        case loading
        case ready(model: String)
        case failed(String)
    }

    private(set) var state = State.loading
    private var model: MLModel?
    private var formatter: LayoutFormatter?
    private var loading: Task<Void, Never>?
    private var lastDownloadFailure: Instant?

    /// Loads the model, downloading the published one first when `download` is on and it is missing or damaged.
    /// A later call with `download` on retries after a failure or a load that was not allowed to download.
    func load(download: Bool) async {
        if let loading { await loading.value }
        switch state {
        case .ready: return
        case .loading where loading != nil: return
        case .notInstalled where !download, .failed where !download: return
        default: break
        }
        if let failed = lastDownloadFailure, Instant.now - failed < 3600 { return }
        let task = Task { await loadOnce(download: download) }
        loading = task
        await task.value
        loading = nil
    }

    private func loadOnce(download: Bool) async {
        state = .loading
        let fm = FileManager.default
        var folder = Self.localFolder
        if !fm.fileExists(atPath: folder.appending(path: "Formatter.mlpackage").path) {
            folder = Self.pinnedFolder
            if !ModelCheck.problems(in: folder, for: PinnedFormatter.model).isEmpty {
                guard download else {
                    state = .notInstalled
                    return
                }
                do {
                    try await Self.downloadPinned()
                } catch {
                    lastDownloadFailure = .now
                    state = .failed(error.localizedDescription)
                    Self.log.error("smart formatting download failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
        let package = folder.appending(path: "Formatter.mlpackage")
        do {
            let config = try JSONDecoder().decode(FormatterConfig.self, from: Data(contentsOf: folder.appending(path: "formatter.json")))
            let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: folder.appending(path: "vocab.json")))
            let merges = try String(contentsOf: folder.appending(path: "merges.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let compiled = try await Self.compiled(package, in: folder)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            let formatter = LayoutFormatter(encoder: LayoutEncoder(bpe: ByteLevelBPE(vocab: vocab, merges: merges), config: config))
            self.model = model
            self.formatter = formatter
            _ = try? formatter.format("Warm up the model.", app: nil, gaps: nil, predict: predict)
            state = .ready(model: config.model)
            Self.log.info("smart formatting ready: \(config.model, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            Self.log.error("smart formatting failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One archive from the GitHub release, with no cookies, no cache and no credentials. It must have the pinned size and
    /// hash, and after unpacking every file must match the table, before it replaces the folder.
    private static func downloadPinned() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Lip-Service"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        log.info("smart formatting: downloading \(PinnedFormatter.archive.absoluteString, privacy: .public)")
        let (archive, response) = try await session.download(from: PinnedFormatter.archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DictationError("The formatting model download answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        try install(archive)
    }

    /// Checks a copy of the published archive and unpacks it into place, the same way a download is.
    static func install(_ archive: URL) throws {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? -1
        guard size == PinnedFormatter.archiveSize, ModelCheck.sha256(of: archive) == PinnedFormatter.archiveSHA256 else {
            throw DictationError("The formatting model download is not the published file.")
        }
        let staging = SupportFolder.url.appending(path: "Formatter.partial", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DictationError("The formatting model archive would not unpack.") }
        let problems = ModelCheck.problems(in: staging, for: PinnedFormatter.model)
        guard problems.isEmpty else {
            try? fm.removeItem(at: staging)
            throw DictationError("The formatting model differs from the published one: \(problems[0]).")
        }
        try? fm.removeItem(at: pinnedFolder)
        try fm.moveItem(at: staging, to: pinnedFolder)
    }

    /// Recompiles when the package is newer than the compiled copy.
    private static func compiled(_ package: URL, in folder: URL) async throws -> URL {
        let target = folder.appending(path: "Formatter.mlmodelc")
        let fm = FileManager.default
        let packageDate = (try? fm.attributesOfItem(atPath: package.appending(path: "Manifest.json").path)[.modificationDate] as? Date) ?? .distantFuture
        if let built = try? fm.attributesOfItem(atPath: target.path)[.modificationDate] as? Date, built >= packageDate {
            return target
        }
        let temporary = try await MLModel.compileModel(at: package)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: temporary, to: target)
        return target
    }

    /// The text with paragraphs, lists and quotes, and how long that took. Nil when the model isn't ready or failed;
    /// the caller then inserts the text as it was.
    func format(_ dictation: Dictation, app: ProfileGroup?) -> (text: String, seconds: Double)? {
        guard let formatter, model != nil, !dictation.text.isEmpty else { return nil }
        let started = Instant.now
        let gaps = WordPauses.before(text: dictation.text, raw: dictation.raw, tokens: dictation.tokens)
        do {
            let text = try formatter.format(dictation.text, app: app, gaps: gaps, predict: predict)
            return (text, Instant.now - started)
        } catch {
            Self.log.error("smart formatting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func predict(_ ids: [Int32], _ mask: [Int32]) throws -> [Float] {
        guard let model else { throw DictationError("The formatting model is not loaded.") }
        let shape = [1, NSNumber(value: ids.count)]
        let idArray = try MLMultiArray(shape: shape, dataType: .int32)
        let maskArray = try MLMultiArray(shape: shape, dataType: .int32)
        for i in ids.indices {
            idArray[i] = NSNumber(value: ids[i])
            maskArray[i] = NSNumber(value: mask[i])
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": idArray, "mask": maskArray]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw DictationError("The formatting model gave no logits.")
        }
        let rows = logits.shape[1].intValue, width = logits.shape[2].intValue
        let rowStride = logits.strides[1].intValue, columnStride = logits.strides[2].intValue
        var out = [Float](repeating: 0, count: rows * width)
        switch logits.dataType {
        case .float16:
            logits.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for r in 0..<rows { for c in 0..<width { out[r * width + c] = Float(p[r * rowStride + c * columnStride]) } }
            }
        case .float32:
            logits.withUnsafeBufferPointer(ofType: Float.self) { p in
                for r in 0..<rows { for c in 0..<width { out[r * width + c] = p[r * rowStride + c * columnStride] } }
            }
        default:
            for r in 0..<rows { for c in 0..<width { out[r * width + c] = logits[[0, NSNumber(value: r), NSNumber(value: c)]].floatValue } }
        }
        return out
    }
}
