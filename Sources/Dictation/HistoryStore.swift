import DictationCore
import Foundation
import Observation
import os

@MainActor @Observable final class HistoryStore {
    /// Oldest first.
    private(set) var entries: [HistoryEntry]
    let url: URL

    @ObservationIgnored private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "history")

    init(url: URL = SupportFolder.url.appending(path: "history.jsonl")) {
        self.url = url
        entries = Self.load(url, log: log)
    }

    func add(_ entry: HistoryEntry) {
        entries.append(entry)
        do {
            let handle = try openForAppending()
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { try handle.write(contentsOf: Data("\n".utf8)) }
            }
            try handle.write(contentsOf: Self.line(entry))
        } catch {
            log.error("could not append to history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        rewrite()
    }

    func deleteAll() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    func merge(_ incoming: [HistoryEntry]) -> Int {
        let merged = HistoryEntry.merging(incoming, into: entries)
        guard merged.added > 0 else { return 0 }
        entries = merged.entries
        rewrite()
        return merged.added
    }

    private func rewrite() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(entries.flatMap(Self.line)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("could not write history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openForAppending() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return try FileHandle(forUpdating: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func line(_ entry: HistoryEntry) -> Data {
        ((try? encoder.encode(entry)) ?? Data()) + Data("\n".utf8)
    }

    private static func load(_ url: URL, log: Logger) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let entries = lines.compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
        if entries.count < lines.count { log.error("skipped \(lines.count - entries.count) unreadable history lines") }
        return entries.sorted { $0.date < $1.date }
    }
}
