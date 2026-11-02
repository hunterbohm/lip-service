import Foundation

/// Decides which files a model download may write. A listing comes from a server, so its paths are not trusted:
/// only the files the app asked for are fetched, and each lands inside the model folder or not at all.
enum DownloadGuard {
    struct UnsafePath: LocalizedError, Equatable {
        let path: String

        var errorDescription: String? {
            "Refusing to download \"\(path)\": it is not a plain path inside the model folder."
        }
    }

    /// Where `relativePath` goes under `root`. Throws for a path that is absolute, has an empty, `.` or `..`
    /// component, or ends up outside `root` once standardized.
    static func destination(of relativePath: String, under root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw UnsafePath(path: relativePath) }
        let destination = root.appendingPathComponent(relativePath)
        let base = root.standardizedFileURL.path
        guard destination.standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw UnsafePath(path: relativePath)
        }
        return destination
    }

    /// The files to download. With `allowed`, any file it does not name is dropped. Every file kept must have a
    /// safe destination, or the whole listing is refused before anything is written.
    static func vet<File>(
        _ files: [File], allowed: Set<String>?, under root: URL, localPath: (File) -> String
    ) throws -> [File] {
        try files.filter { file in
            let path = localPath(file)
            if let allowed, !allowed.contains(path) { return false }
            _ = try destination(of: path, under: root)
            return true
        }
    }
}
