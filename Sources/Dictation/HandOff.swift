import AppKit
import DictationCore
import Foundation
import os
import Security

/// Where destination secrets live: the Keychain in the app, a private file for `--hand-off`.
protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    func save(_ key: String, _ value: String) throws
    func delete(_ key: String)
}

struct Keychain: SecretStore {
    private static let service = "com.hunterbohm.dictation.agents"

    func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String, _ value: String) throws {
        delete(key)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentError("The Keychain refused to save it (\(status)).") }
    }

    func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                       kSecAttrAccount as String: key] as CFDictionary)
    }
}

/// Everything a destination may need besides the request itself.
struct HandOffContext: Sendable {
    var agent: AgentConnection
    var includeWindowText: Bool
    var dryRun: Bool
    var secrets: any SecretStore
    var project: HandOffCard.Project?
    var pool: AgentPool?
    /// Text the agent streams back, for the reply-in-card destination.
    var onChunk: @Sendable (String) -> Void = { _ in }
}

/// One way a task leaves Lip Service. `send` returns the line the card ends with.
protocol HandOffSender: Sendable {
    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String
}

extension Destination {
    var sender: any HandOffSender {
        switch self {
        case .iMessage(let handle): IMessageSender(handle: handle)
        case .t3Code(let t3): T3Sender(destination: t3)
        case .telegram(let bot): TelegramSender(bot: bot)
        case .slack(_, let bot, let tokenKey): SlackSender(botUserID: bot, tokenKey: tokenKey)
        case .discord(let webhookKey, let botID): DiscordSender(webhookKey: webhookKey, botID: botID)
        case .webhook(let url, let secretKey): WebhookSender(url: url, secretKey: secretKey)
        case .command(let executable, let arguments): CommandSender(executable: executable, arguments: arguments)
        case .agentReply: AgentReplySender()
        }
    }
}

private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "handoff")

struct IMessageSender: HandOffSender {
    let handle: String

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        let handle = handle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { throw AgentError("Add \(context.agent.name)'s iMessage handle on the Ghostwrite page.") }
        let source = Data(HandOffRequests.iMessageScript(text: request.message(includeWindowText: context.includeWindowText), handle: handle).utf8)
        if context.dryRun {
            let compiled = FileManager.default.temporaryDirectory.appending(path: "lip-service-\(request.id).scpt")
            defer { try? FileManager.default.removeItem(at: compiled) }
            let result = try await Process.runToEnd("/usr/bin/osacompile", ["-o", compiled.path], input: source, timeout: 15)
            guard result.status == 0 else { throw AgentError("The Messages script didn't compile: \(Self.reason(result))") }
            log.info("iMessage dry run to \(handle, privacy: .private): compiled \(source.count) bytes, not sent")
            return "Dry run: the message to \(context.agent.name) was built and not sent."
        }
        switch await MessagesPermission.check(asking: false) {
        case .granted: break
        case .denied:
            throw AgentError("Lip Service isn't allowed to use Messages. Turn it on in System Settings, Privacy & Security, Automation.")
        case .notAsked:
            throw AgentError("Press Test for \(context.agent.name) on the Ghostwrite page, so macOS can ask to let Lip Service use Messages.")
        }
        // Run apart from the app, so Messages being slow holds up nothing else.
        let result = try await Process.runToEnd("/usr/bin/osascript", [], input: source, timeout: 60)
        guard !result.timedOut else { throw AgentError("Messages didn't answer within a minute.") }
        guard result.status == 0 else { throw AgentError("Messages didn't send it: \(Self.reason(result))") }
        return "\(context.agent.name) keeps going in iMessage, where it always answers you."
    }

    private static func reason(_ result: Process.Finished) -> String {
        let errors = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return errors.isEmpty ? "exit \(result.status)" : String(errors.suffix(200))
    }
}

/// Whether Lip Service may control Messages. macOS asks the user the first time. When that prompt came up during a
/// hand-off, it took the Return meant for the card and the keyboard stopped working, so only Test may ask.
enum MessagesPermission {
    case granted, denied, notAsked

    @MainActor static func check(asking: Bool) async -> MessagesPermission {
        guard let messages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .denied }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            let launch = NSWorkspace.OpenConfiguration()
            launch.activates = false
            launch.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: messages, configuration: launch)
        }
        return await Task.detached { determine(asking: asking) }.value
    }

    private static let bundleID = "com.apple.MobileSMS"

    /// Blocks while the user answers, so never on the main thread.
    private static func determine(asking: Bool) -> MessagesPermission {
        var target = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return .denied }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, asking) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .denied
        }
    }
}

struct WebhookSender: HandOffSender {
    let url: String
    let secretKey: String?

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme ?? "") else {
            throw AgentError("The web address isn't a valid http or https address.")
        }
        let signed = HandOffRequests.signed(request.payload(includeWindowText: context.includeWindowText),
                                            secret: secretKey.flatMap(context.secrets.read), timestamp: Int(Date().timeIntervalSince1970),
                                            requestID: request.id)
        guard signed.body.count <= HandOffRequests.largestBody else { throw AgentError("The hand-off is over 1 MB.") }
        if context.dryRun { return "Dry run: \(signed.body.count) bytes for \(address.host ?? url), not sent." }
        var post = URLRequest(url: address, timeoutInterval: 15)
        post.httpMethod = "POST"
        post.httpBody = signed.body
        for (name, value) in signed.headers { post.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSession.shared.data(for: post)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AgentError("\(address.host ?? url) answered \(status).") }
        return "Sent to \(address.host ?? url)."
    }
}

struct CommandSender: HandOffSender {
    let executable: String
    let arguments: [String]

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        let path = (executable as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { throw AgentError("\(executable) isn't a program that can run.") }
        let body = request.payload(includeWindowText: context.includeWindowText).data()
        if context.dryRun { return "Dry run: \(URL(fileURLWithPath: path).lastPathComponent) would get \(body.count) bytes." }
        let name = URL(fileURLWithPath: path).lastPathComponent
        var contextFile: URL?
        if context.includeWindowText, !request.context.withheld {
            let file = FileManager.default.temporaryDirectory.appending(path: "lip-service-handoff-\(request.id).txt")
            FileManager.default.createFile(atPath: file.path, contents: Data(request.windowText.utf8), attributes: [.posixPermissions: 0o600])
            contextFile = file
        }
        defer { if let contextFile { try? FileManager.default.removeItem(at: contextFile) } }
        let environment = ProcessInfo.processInfo.environment.merging(
            HandOffRequests.commandEnvironment(request, contextFile: contextFile?.path, timestamp: Int(request.date.timeIntervalSince1970))) { $1 }
        let result = try await Process.runToEnd(path, arguments, environment: environment, input: body, timeout: 30)
        guard !result.timedOut else { throw AgentError("\(name) ran past 30 seconds and was stopped.") }
        guard result.status == 0 else {
            let errors = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentError("\(name) failed\(errors.isEmpty ? " with exit \(result.status)" : ": " + String(errors.suffix(200)))")
        }
        return "\(name) took it."
    }
}

struct SlackSender: HandOffSender {
    let botUserID: String
    let tokenKey: String

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard let token = context.secrets.read(tokenKey) else { throw AgentError("Add your Slack token on the Ghostwrite page.") }
        let text = request.message(includeWindowText: context.includeWindowText)
        if context.dryRun { return "Dry run: a Slack message to \(botUserID), not sent." }
        let opened = try await HTTP.send(HandOffRequests.slackOpen(token: token, botUserID: botUserID))
        let channel = try HandOffRequests.slackChannel(opened).get()
        let posted = try await HTTP.send(HandOffRequests.slackPost(token: token, channel: channel, text: text))
        if JSONValue.parse(posted)?["ok"]?.bool != true { throw AgentError("Slack didn't post it.") }
        return "\(context.agent.name) keeps going in Slack."
    }
}

struct DiscordSender: HandOffSender {
    let webhookKey: String
    let botID: String

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard let webhook = context.secrets.read(webhookKey) else { throw AgentError("Add the Discord channel webhook on the Ghostwrite page.") }
        let post = HandOffRequests.discordPost(webhookURL: webhook, botID: botID, text: request.message(includeWindowText: context.includeWindowText))
        if context.dryRun { return "Dry run: a Discord message of \(post.body.count) bytes, not sent." }
        _ = try await HTTP.send(post)
        return "\(context.agent.name) keeps going in Discord."
    }
}

struct TelegramSender: HandOffSender {
    let bot: String

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard !bot.isEmpty else { throw AgentError("Add the Telegram bot's username on the Ghostwrite page.") }
        let link = HandOffRequests.telegramLink(bot: bot, text: request.message(includeWindowText: context.includeWindowText))
        if context.dryRun { return "Dry run: would open \(link.prefix(60))…" }
        guard let url = URL(string: link) else { throw AgentError("The Telegram link didn't build.") }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        return "Telegram is open with your message. Press Return there to send it."
    }
}

/// The agent does the task itself over ACP, with its full model, and its reply shows in the card.
struct AgentReplySender: HandOffSender {
    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard let pool = context.pool else { throw AgentError("No agent to ask.") }
        if context.dryRun { return "Dry run: \(context.agent.name) would get the task." }
        let (client, session) = try await pool.taskSession(context.agent)
        let onChunk = context.onChunk
        _ = try await client.prompt(request.message(includeWindowText: context.includeWindowText), session: session, timeout: 600,
                                    onUpdate: { update in if case .message(let text) = update { onChunk(text) } },
                                    onPermission: { request in request.rejection?.id })
        return "\(context.agent.name) answered."
    }
}

enum HTTP {
    static func send(_ request: HandOffRequests.HTTPRequest) async throws -> Data {
        guard let url = URL(string: request.url) else { throw AgentError("Bad address \(request.url).") }
        var post = URLRequest(url: url, timeoutInterval: 15)
        post.httpMethod = request.method
        post.httpBody = request.body
        for (name, value) in request.headers { post.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: post)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AgentError("\(url.host ?? "The server") answered \(status).") }
        return data
    }
}

/// `--hand-off`: one destination from a JSON file, with sample window text, as the app sends it.
enum HandOffTest {
    struct Options {
        var destination: URL
        var dryRun = false
        var includeWindowText = false
        var words: [String] = []
    }

    /// Secrets for the test from LS_SECRETS, a JSON object file, for a run that can't reach the Keychain.
    struct FileSecrets: SecretStore {
        let values: [String: String]
        func read(_ key: String) -> String? { values[key] }
        func save(_ key: String, _ value: String) throws {}
        func delete(_ key: String) {}
    }

    @MainActor static func run(_ options: Options) async -> Int32 {
        do {
            let destination = try JSONDecoder().decode(Destination.self, from: Data(contentsOf: options.destination))
            let file = ProcessInfo.processInfo.environment["LS_SECRETS"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            let secrets: any SecretStore = file.map { FileSecrets(values: $0) } ?? Keychain()
            var agent = AgentPreset.with(id: "hermes")!.connection()
            agent.destination = destination
            let request = HandOffRequest(words: options.words.joined(separator: " "),
                                         context: WindowContext(app: HistoryApp(name: "TextEdit", bundleID: "com.apple.TextEdit"),
                                                                windowTitle: "notes.txt", aroundCursor: "Lip Service hand-off test", cursor: 25))
            var context = HandOffContext(agent: agent, includeWindowText: options.includeWindowText, dryRun: options.dryRun, secrets: secrets)
            if case .t3Code(let t3) = destination {
                let client = try T3Client(destination: t3, secrets: context.secrets)
                let projects = try await client.projects()
                let wanted = ProcessInfo.processInfo.environment["LS_T3_PROJECT"]
                guard let project = projects.first(where: { $0.name == wanted || $0.id == wanted }) ?? (wanted == nil ? projects.first : nil) else {
                    print("projects: \(projects.map(\.name))")
                    throw AgentError("No project named \(wanted ?? "")")
                }
                print("project: \(project.name) of \(projects.count)")
                context.project = project
            }
            let note = try await destination.sender.send(request, context)
            print("sent: \(note)")
            return 0
        } catch {
            print("failed: \(error.localizedDescription)")
            return 1
        }
    }
}
