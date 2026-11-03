import CoreML
import DictationCore
import Foundation
import os

/// Runs the smart formatting model from `Formatter/` in the support folder: `Formatter.mlpackage`, RoBERTa's
/// `vocab.json` and `merges.txt`, and `formatter.json`. Without the folder, dictation goes in as before. The package
/// is compiled once and the compiled copy kept beside it, so later launches only load it.
actor SmartFormatter {
    static let folder = SupportFolder.url.appending(path: "Formatter", directoryHint: .isDirectory)
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
    private var loaded: Task<Void, Never>?

    func load() async {
        if let loaded { return await loaded.value }
        let task = Task { await loadOnce() }
        loaded = task
        await task.value
    }

    private func loadOnce() async {
        let folder = Self.folder
        let package = folder.appending(path: "Formatter.mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else {
            state = .notInstalled
            return
        }
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
