import Foundation

/// History and the vocabulary file hold what the user said and the names they use. Only they may read them.
enum SupportFolder {
    static let url = URL.applicationSupportDirectory.appending(path: "Dictation", directoryHint: .isDirectory)

    /// Files the app creates from here on are private from the first byte, not after a later chmod. Files and
    /// folders from earlier versions are made private by the folder, whatever their own mode.
    static func makePrivate() {
        umask(0o077)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
