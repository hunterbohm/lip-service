import CryptoKit
import Foundation

public struct ModelFile: Equatable, Sendable {
    /// Relative to the model's folder.
    public var path: String
    public var size: Int
    /// Lowercase hex.
    public var sha256: String

    public init(_ path: String, size: Int, sha256: String) {
        (self.path, self.size, self.sha256) = (path, size, sha256)
    }
}

/// A model repository at one commit, with every file the app reads from it. `PinnedModels` holds the table,
/// which scripts/pin-models.py writes.
public struct PinnedModel: Equatable, Sendable {
    /// The Hugging Face repository, owner and name.
    public var repo: String
    /// The full 40-character commit.
    public var commit: String
    /// The model's folder in FluidAudio's cache.
    public var folder: String
    public var files: [ModelFile]

    public init(repo: String, commit: String, folder: String, files: [ModelFile]) {
        (self.repo, self.commit, self.folder, self.files) = (repo, commit, folder, files)
    }

    /// The Core ML bundles. Everything inside one is listed, so a file in it that the table lacks is a problem.
    public var bundles: [String] {
        Set(files.compactMap { $0.path.split(separator: "/").first.map(String.init) }.filter { $0.hasSuffix(".mlmodelc") })
            .sorted()
    }
}

public enum ModelProblem: Equatable, Sendable, CustomStringConvertible {
    /// Absent, or not a regular file.
    case missing(String)
    case wrongSize(String, expected: Int, actual: Int)
    case wrongHash(String)
    /// In a listed bundle but not in the table.
    case unexpected(String)
    /// Inspecting the path, or listing the folder, failed, so the check cannot say what is there.
    case unreadable(String)

    public var description: String {
        switch self {
        case .missing(let path): "\(path) is missing"
        case .wrongSize(let path, let expected, let actual): "\(path) is \(actual) bytes, not \(expected)"
        case .wrongHash(let path): "\(path) has the wrong contents"
        case .unexpected(let path): "\(path) should not be there"
        case .unreadable(let path): "\(path) could not be read"
        }
    }

    /// What a download that stopped halfway leaves: files not yet fetched and FluidAudio's `.partial` files. A
    /// retry resumes from them, so they are worth keeping. Anything else means files that are wrong, not late.
    public var isInterruptedDownload: Bool {
        switch self {
        case .missing: true
        case .unexpected(let path): path.hasSuffix(".partial") || path.hasSuffix(".partial.etag")
        case .wrongSize, .wrongHash, .unreadable: false
        }
    }
}

public enum ModelCheck {
    /// Every way `directory` differs from `model`, in table order, then the extra files by path. Empty means Core ML
    /// may read it. Reads each listed file once, so it costs about the time to read the model.
    public static func problems(in directory: URL, for model: PinnedModel) -> [ModelProblem] {
        var problems: [ModelProblem] = []
        for file in model.files {
            let url = directory.appending(path: file.path, directoryHint: .notDirectory)
            switch entry(at: url) {
            case .absent:
                problems.append(.missing(file.path))
            case .unreadable:
                problems.append(.unreadable(file.path))
            case .present(let kind, _) where kind != S_IFREG:
                problems.append(.missing(file.path))
            case .present(_, let size):
                if size != file.size {
                    problems.append(.wrongSize(file.path, expected: file.size, actual: size))
                } else if sha256(of: url) != file.sha256 {
                    problems.append(.wrongHash(file.path))
                }
            }
        }
        let listed = Set(model.files.map(\.path))
        var extra: [(path: String, problem: ModelProblem)] = []
        for bundle in model.bundles {
            let root = directory.appending(path: bundle, directoryHint: .isDirectory)
            // A bundle that is not there is already reported file by file. A link in its place would lead the
            // listed files, and the listing below, somewhere else.
            switch entry(at: root) {
            case .absent: continue
            case .unreadable: extra.append((bundle, .unreadable(bundle))); continue
            case .present(let kind, _) where kind != S_IFDIR: extra.append((bundle, .unreadable(bundle))); continue
            case .present: break
            }
            // Without a handler the enumerator skips what it cannot open, which would hide files from this check.
            var failed: [String] = []
            guard let items = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                errorHandler: { url, _ in
                    failed.append(bundle + "/" + relativePath(of: url, under: root))
                    return true
                })
            else {
                extra.append((bundle, .unreadable(bundle)))
                continue
            }
            for case let item as URL in items {
                let path = bundle + "/" + relativePath(of: item, under: root)
                guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    extra.append((path, .unreadable(path)))
                    continue
                }
                if values.isDirectory == true, values.isSymbolicLink != true { continue }
                if !listed.contains(path) { extra.append((path, .unexpected(path))) }
            }
            extra += failed.map { ($0, .unreadable($0)) }
        }
        return problems + extra.sorted { $0.path < $1.path }.map(\.problem)
    }

    private enum Entry {
        case absent
        case unreadable
        /// `kind` is the file-type bits of the mode. A link is `S_IFLNK`, since the lookup does not follow it.
        case present(kind: mode_t, size: Int)
    }

    private static func entry(at url: URL) -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .absent : .unreadable }
        return .present(kind: info.st_mode & S_IFMT, size: Int(info.st_size))
    }

    private static func relativePath(of item: URL, under root: URL) -> String {
        item.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    /// Nil when the file cannot be read, which never equals a listed hash.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try autoreleasepool { try handle.read(upToCount: 1 << 22) } } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
