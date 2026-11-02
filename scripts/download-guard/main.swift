import Foundation

var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "pass" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func refused(_ path: String, under root: URL) -> Bool {
    do { _ = try DownloadGuard.destination(of: path, under: root); return false } catch is DownloadGuard.UnsafePath { return true } catch { return false }
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("download-guard-\(UUID().uuidString)")
let root = scratch.appendingPathComponent("Models/parakeet", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

let escape = "Encoder.mlmodelc/../../../../../LaunchAgents/x.plist"
check("traversal path is refused", refused(escape, under: root))
check("absolute path is refused", refused("/Users/someone/Library/LaunchAgents/x.plist", under: root))
check("leading .. is refused", refused("../sibling/file.bin", under: root))
check("single dot component is refused", refused("Encoder.mlmodelc/./weights/weight.bin", under: root))
check("empty component is refused", refused("Encoder.mlmodelc//weights/weight.bin", under: root))
check("trailing slash is refused", refused("Encoder.mlmodelc/", under: root))
check("empty path is refused", refused("", under: root))
check("NUL byte is refused", refused("a\0/../../x", under: root))

let plain = try DownloadGuard.destination(of: "Encoder.mlmodelc/weights/weight.bin", under: root)
check("plain nested path is allowed", plain == root.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin"))
check("allowed path stays inside the folder", plain.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))

let listing = ["Encoder.mlmodelc/weights/weight.bin", "config.json", "README.md", "Encoder.mlmodelc/unlisted.bin", escape]
let kept = try DownloadGuard.vet(listing.filter { $0 != escape }, allowed: ["Encoder.mlmodelc/weights/weight.bin", "config.json"], under: root) { $0 }
check("allowlist keeps only the listed files", kept == ["Encoder.mlmodelc/weights/weight.bin", "config.json"])

let ignored = try DownloadGuard.vet(listing, allowed: ["Encoder.mlmodelc/weights/weight.bin", "config.json"], under: root) { $0 }
check("allowlist ignores an unlisted traversal path instead of failing", ignored == kept)

var refusedWholeListing = false
do { _ = try DownloadGuard.vet(listing, allowed: nil, under: root) { $0 } } catch is DownloadGuard.UnsafePath { refusedWholeListing = true }
check("without an allowlist one traversal path refuses the listing", refusedWholeListing)

var refusedAllowedTraversal = false
do { _ = try DownloadGuard.vet([escape], allowed: [escape], under: root) { $0 } } catch is DownloadGuard.UnsafePath { refusedAllowedTraversal = true }
check("a traversal path on the allowlist is still refused", refusedAllowedTraversal)

let outside = scratch.appendingPathComponent("outside.txt")
if let target = try? DownloadGuard.destination(of: "../../outside.txt", under: root) { try Data("x".utf8).write(to: target) }
check("a refused path leaves no file behind", !FileManager.default.fileExists(atPath: outside.path))

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
