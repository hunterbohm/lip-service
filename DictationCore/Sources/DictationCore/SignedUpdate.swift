import Foundation

/// The rules an in-app update must meet before the app replaces itself. Only a signed, notarized release from the same
/// Apple team as the running app installs. The commands here are built as data so tests can check them.
public enum SignedUpdate {
    /// What the downloaded app's signature must satisfy: issued through Apple's Developer ID program, for this bundle id,
    /// by this team. macOS keys the Microphone and Accessibility grants to the same bundle id and signer, so an update
    /// that meets it keeps them. `field.1.2.840.113635.100.6.2.6` marks a Developer ID certificate authority and
    /// `...6.1.13` a Developer ID Application leaf, so an Apple Development or distribution certificate of the same team
    /// does not pass.
    public static func requirement(teamID: String, bundleID: String) -> String? {
        guard isTeamID(teamID), isBundleID(bundleID) else { return nil }
        return "anchor apple generic and identifier \"\(bundleID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Apple's team ids are ten capital letters and digits.
    public static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func isBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Why a downloaded release was not installed. The message shows in the app.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAnApp(String)
        case identity(String)
        case version(String)
        case signature(String)
        case gatekeeper(String)

        public var description: String {
            switch self {
            case .notAnApp(let why): "The download is not a usable app: \(why)"
            case .identity(let id): "The download is \(id), not Lip Service."
            case .version(let shown): "The download says it is \(shown), not the version that was offered."
            case .signature(let output): "The download is not signed by the same developer as this app: \(output)"
            case .gatekeeper(let output): "macOS would not open the download, so it is not notarized: \(output)"
            }
        }
    }

    /// Checks the downloaded app's Info.plist: it is this app, at the offered version, and newer than the running one.
    public static func vet(info: [String: Any]?, bundleID: String, offered: Version, running: Version) throws {
        guard let info else { throw Refusal.notAnApp("no Info.plist") }
        let id = info["CFBundleIdentifier"] as? String ?? "unknown"
        guard id == bundleID else { throw Refusal.identity(id) }
        let shown = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let version = Version(shown), version == offered, version > running else { throw Refusal.version(shown) }
    }

    /// One command to run. Each goes through bash so its stderr reaches the message; the tools print their reasons there.
    public struct Command: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var timeout: Double

        public static func merged(_ tool: String, _ arguments: [String], timeout: Double) -> Command {
            Command(executable: "/bin/bash", arguments: ["-c", "\"$@\" 2>&1", "lip-service-update", tool] + arguments, timeout: timeout)
        }
    }

    public static func unzip(_ archive: URL, into folder: URL) -> Command {
        .merged("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], timeout: 300)
    }

    public static func verifySignature(_ app: URL, requirement: String) -> Command {
        .merged("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path], timeout: 120)
    }

    /// What Gatekeeper decides for a launch. Passes only for a Developer ID app that Apple notarized.
    public static func assess(_ app: URL) -> Command {
        .merged("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 120)
    }

    /// Run by bash as `bash -c script lip-service-update <pid> <new app> <installed app> <log>`, as a launchd job so it
    /// outlives the app it waits for. It waits for the app to quit, moves the installed app aside and the new one into
    /// its place, puts the old one back if that fails, and opens the result. Nothing runs before the app has exited, so
    /// the swap never rewrites a bundle that is running.
    public static let installScript = """
        pid="$1" new="$2" destination="$3" job="$4"
        set -u
        finish() { /bin/launchctl bootout "gui/$(id -u)/$job" >/dev/null 2>&1 || true; }
        trap finish EXIT
        for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then printf 'Lip Service did not quit; left it as it is.\\n'; exit 1; fi
        aside="$(dirname "$new")/previous.app"
        if /bin/mv "$destination" "$aside"; then
            if /bin/mv "$new" "$destination"; then
                printf 'Installed.\\n'
            else
                /bin/mv "$aside" "$destination"
                printf 'Could not move the new app into place; the old one is back.\\n'
            fi
        else
            printf 'Could not move the old app aside.\\n'
        fi
        /usr/bin/open "$destination"
        [ -d "$destination" ] && /bin/rm -rf "$(dirname "$new")"
        """

    /// The one-shot launch agent that runs `installScript`.
    public static func job(label: String, pid: Int32, new: URL, destination: URL, log: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/bash", "-c", installScript, "lip-service-update", String(pid), new.path, destination.path, label],
            "RunAtLoad": true,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            "Umask": 63
        ]
    }

    /// Whether an app at this path can be replaced where it stands: its folder is writable, and macOS has not translocated
    /// it, which it does to an app opened from Downloads without being moved.
    public static func canReplace(at app: URL, parentWritable: Bool) -> Bool {
        parentWritable && !app.path.contains("/AppTranslocation/")
    }
}
