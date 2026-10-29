import DictationCore
import FluidAudio
import Foundation

/// The only way from the model cache to Core ML. A model's folder is read only after every file in it matches
/// the table in `PinnedModels`, which names the Hugging Face commit the files came from.
struct ModelStore: Sendable {
    /// FluidAudio's models folder, which holds one folder per repository.
    let directory: URL

    static let defaultDirectory = AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()

    func folder(for model: PinnedModel) -> URL { directory.appending(path: model.folder, directoryHint: .isDirectory) }

    func speechModels(progress: @escaping ProgressHandler) async throws -> AsrModels {
        let folder = try await verifiedFolder(PinnedModels.parakeetTDT, repo: .parakeetV2, progress: progress)
        return try await loadingOffline { try await AsrModels.load(from: folder, version: .v2, progressHandler: progress) }
    }

    /// The tokenizer is read here, right after the check, and kept, so rebuilding the vocabulary later reads no file.
    func boostingModels() async throws -> BoostingModels {
        let folder = try await verifiedFolder(PinnedModels.parakeetCTC, repo: .parakeetCtc110m, progress: nil)
        let tokenizer = try await CtcTokenizer.load(from: folder)
        let ctc = try await loadingOffline { try await CtcModels.load(from: folder, variant: .ctc110m) }
        return BoostingModels(ctc: ctc, tokenizer: tokenizer)
    }

    /// Fetches the pinned commit when the cache is missing, partial, or not the pinned files, and throws unless
    /// the folder then matches the table. A cache that fails is from a version that downloaded from the main
    /// branch, or damaged, so it is deleted and fetched once more. An interrupted download is kept, so the retry
    /// resumes it. Offline, nothing is deleted or fetched.
    private func verifiedFolder(_ model: PinnedModel, repo: Repo, progress: ProgressHandler?) async throws -> URL {
        guard repo.remotePath == model.repo, repo.folderName == model.folder else {
            throw DictationError("FluidAudio keeps \(repo.remotePath) in \(repo.folderName), not the table's \(model.repo) in \(model.folder).")
        }
        // The vocabulary file and every model file come from the pinned commit, never from main.
        ModelRegistry.revisionOverrides = Dictionary(uniqueKeysWithValues: PinnedModels.all.map { ($0.repo, $0.commit) })
        let folder = folder(for: model)
        var problems = ModelCheck.problems(in: folder, for: model)
        if !problems.isEmpty {
            guard !ModelHub.offlineMode else { throw ModelCheckFailure(model: model, problems: problems) }
            if !ModelCheck.canResume(problems) { try FileManager.default.removeItem(at: folder) }
            try await ModelHub.download(repo, to: directory, progressHandler: progress)
            problems = ModelCheck.problems(in: folder, for: model)
            guard problems.isEmpty else { throw ModelCheckFailure(model: model, problems: problems) }
        }
        try markRevision(of: folder, as: model.commit)
        return folder
    }

    /// FluidAudio reads a cache without this file as one from main, and a pinned commit never matches that.
    /// Writing it after the check also adopts a cache that 1.0.0 or 1.0.1 downloaded, when the files are the
    /// pinned ones.
    private func markRevision(of folder: URL, as commit: String) throws {
        let marker = folder.appending(path: ".fluidaudio-revision")
        let contents = Data((commit + "\n").utf8)
        if (try? Data(contentsOf: marker)) != contents { try contents.write(to: marker, options: .atomic) }
    }

    /// Core ML's own recovery from a failed load deletes the folder and downloads it again, then loads files that
    /// nothing checked. The files here already passed, so downloading again cannot help.
    private func loadingOffline<T>(_ load: () async throws -> T) async rethrows -> T {
        let before = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = before }
        return try await load()
    }
}

struct BoostingModels: Sendable {
    let ctc: CtcModels
    let tokenizer: CtcTokenizer
}

struct ModelCheckFailure: LocalizedError {
    let model: PinnedModel
    let problems: [ModelProblem]

    var errorDescription: String? {
        let first = problems.first.map(String.init(describing:)) ?? "files are missing"
        let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
        return "The \(model.folder) model does not match the published one: \(first)\(more)."
    }
}
