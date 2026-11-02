import CryptoKit
import Foundation

/// The requests and scripts each destination sends, built without sending anything, so each can be tested and a dry
/// run can show exactly what would go out.
public enum HandOffRequests {
    // MARK: iMessage

    /// Messages' AppleScript, sending as the user. Some accounts on macOS 26 throw when asked their service type, so
    /// the script asks for the first iMessage account, and falls back to the chat with that handle.
    public static func iMessageScript(text: String, handle: String) -> String {
        let text = appleScriptString(text), handle = appleScriptString(handle)
        return """
            tell application "Messages"
                try
                    set targetService to 1st account whose service type = iMessage
                    send \(text) to participant \(handle) of targetService
                on error
                    send \(text) to chat id ("any;-;" & \(handle))
                end try
            end tell
            """
    }

    /// A quoted AppleScript string literal. Line breaks go in through `linefeed`, so the script stays one statement.
    public static func appleScriptString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return "\"" + escaped.replacingOccurrences(of: "\n", with: "\" & linefeed & \"") + "\""
    }

    // MARK: Web address

    public struct Signed: Equatable, Sendable {
        public var body: Data
        public var headers: [String: String]
    }

    /// The headers GitHub-style receivers and Hermes's webhook both check: an HMAC of the body, and a timestamped
    /// HMAC of "timestamp.body" that a receiver can hold to a time window against replay.
    public static func signed(_ payload: JSONValue, secret: String?, timestamp: Int, requestID: String) -> Signed {
        let body = payload.data()
        var headers = ["Content-Type": "application/json", "X-Request-ID": requestID, "X-Webhook-Timestamp": String(timestamp),
                       "User-Agent": "LipService"]
        if let secret, !secret.isEmpty {
            headers["X-Hub-Signature-256"] = "sha256=" + hmac(body, key: secret)
            headers["X-Webhook-Signature-V2"] = "v2=" + hmac(Data("\(timestamp).".utf8) + body, key: secret)
        }
        return Signed(body: body, headers: headers)
    }

    public static func hmac(_ data: Data, key: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(key.utf8)))).map { String(format: "%02x", $0) }.joined()
    }

    /// What a receiver checks, for the tests and the local listener.
    public static func verify(body: Data, headers: [String: String], secret: String) -> Bool {
        guard let timestamp = headers["X-Webhook-Timestamp"] else { return false }
        return headers["X-Hub-Signature-256"] == "sha256=" + hmac(body, key: secret)
            && headers["X-Webhook-Signature-V2"] == "v2=" + hmac(Data("\(timestamp).".utf8) + body, key: secret)
    }

    public static let largestBody = 1 << 20

    // MARK: Command

    /// The environment a hand-off command gets, beside the JSON on stdin. `contextFile` holds the window text, and is
    /// nil when none is sent.
    public static func commandEnvironment(_ request: HandOffRequest, contextFile: String?, timestamp: Int) -> [String: String] {
        var environment = ["LS_TEXT": request.words, "LS_APP": request.context.app?.name ?? "", "LS_TIMESTAMP": String(timestamp)]
        environment["LS_CONTEXT_FILE"] = contextFile
        return environment
    }

    // MARK: Slack, Discord, Telegram

    public struct HTTPRequest: Equatable, Sendable {
        public var url: String
        public var method = "POST"
        public var headers: [String: String]
        public var body: Data
    }

    /// Opens, or finds, the user's direct message with the bot.
    public static func slackOpen(token: String, botUserID: String) -> HTTPRequest {
        HTTPRequest(url: "https://slack.com/api/conversations.open",
                    headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json; charset=utf-8"],
                    body: (["users": .string(botUserID)] as JSONValue).data())
    }

    /// The direct message's channel id, or Slack's error.
    public static func slackChannel(_ response: Data) -> Result<String, RPCError> {
        guard let value = JSONValue.parse(response) else { return .failure(RPCError(code: 0, message: "Slack sent back something unreadable.")) }
        if value["ok"]?.bool == true, let channel = value["channel"]?["id"]?.string { return .success(channel) }
        return .failure(RPCError(code: 0, message: "Slack said \(value["error"]?.string ?? "no")."))
    }

    public static func slackPost(token: String, channel: String, text: String) -> HTTPRequest {
        HTTPRequest(url: "https://slack.com/api/chat.postMessage",
                    headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json; charset=utf-8"],
                    body: (["channel": .string(channel), "text": .string(text)] as JSONValue).data())
    }

    /// Discord caps a message at 2,000 characters, so the text is cut to fit after the mention.
    public static func discordPost(webhookURL: String, botID: String, text: String) -> HTTPRequest {
        let mention = botID.isEmpty ? "" : "<@\(botID)> "
        let content = mention + String(text.prefix(2_000 - mention.count))
        return HTTPRequest(url: webhookURL, headers: ["Content-Type": "application/json"],
                           body: (["content": .string(content), "allowed_mentions": ["users": botID.isEmpty ? [] : [.string(botID)]]] as JSONValue).data())
    }

    /// Opens the chat with the bot with the text typed in, for the user to send.
    public static func telegramLink(bot: String, text: String) -> String {
        let bot = bot.hasPrefix("@") ? String(bot.dropFirst()) : bot
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return "tg://resolve?domain=\(bot)&text=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
}

/// T3 Code's local server: where it is, how to sign in to its MCP endpoint, and what its tools send back.
public enum T3 {
    /// Where to look for T3 Code's home folder, in order.
    public static func homes(configured: String?, environment: [String: String], userHome: String) -> [String] {
        if let configured, !configured.isEmpty { return [configured] }
        return [environment["T3CODE_HOME"], userHome + "/.t3", userHome + "/.t3-v2"].compactMap { $0 }
    }

    public struct Runtime: Equatable, Sendable {
        public var origin: String
        public var pid: Int?
    }

    /// `userdata/server-runtime.json`, written by a running server.
    public static func runtime(_ data: Data) -> Runtime? {
        guard let value = JSONValue.parse(data), let origin = value["origin"]?.string else { return nil }
        return Runtime(origin: origin.hasSuffix("/") ? String(origin.dropLast()) : origin, pid: value["pid"]?.number.map { Int($0) })
    }

    // MARK: Sign-in

    public static let access = "approval-required"
    public static let tokenLifetime = 30.0 * 24 * 3600

    public struct PKCE: Equatable, Sendable {
        public var verifier: String
        public var challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = T3.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public static func random() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            return PKCE(verifier: T3.base64URL(Data(bytes)))
        }
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func registration(redirect: String) -> JSONValue {
        ["client_name": "Lip Service", "redirect_uris": [.string(redirect)], "token_endpoint_auth_method": "none"]
    }

    public static func authorization(clientID: String, redirect: String, pkce: PKCE, state: String, resource: String) -> JSONValue {
        ["response_type": "code", "client_id": .string(clientID), "redirect_uri": .string(redirect), "code_challenge": .string(pkce.challenge),
         "code_challenge_method": "S256", "state": .string(state), "resource": .string(resource)]
    }

    /// Approves the sign-in with a pairing code the user made in T3 Code, without a browser. The server answers with
    /// the redirect it would have sent the browser to, which carries the code.
    public static func decision(authorization: JSONValue, pairingCode: String) -> JSONValue {
        ["authorization": authorization,
         "decision": ["_tag": "pairing-code", "access": .string(access), "code": .string(pairingCode.trimmingCharacters(in: .whitespaces))]]
    }

    /// The code from the redirect, after checking its state.
    public static func code(fromRedirect redirect: String, state: String) -> String? {
        guard let items = URLComponents(string: redirect)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    public static func tokenForm(code: String, redirect: String, clientID: String, verifier: String, resource: String) -> Data {
        let fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("client_id", clientID),
                      ("code_verifier", verifier), ("resource", resource)]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    public struct Token: Equatable, Codable, Sendable {
        public var accessToken: String
        public var expires: Date
        public var origin: String
    }

    public static func token(_ data: Data, origin: String, now: Date) -> Token? {
        guard let value = JSONValue.parse(data), let token = value["access_token"]?.string else { return nil }
        return Token(accessToken: token, expires: now.addingTimeInterval(value["expires_in"]?.number ?? tokenLifetime), origin: origin)
    }

    // MARK: MCP

    public static func mcpInitialize() -> JSONValue {
        ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "lip-service", "version": "1"]]
    }

    public static func toolCall(_ name: String, _ arguments: JSONValue) -> JSONValue { ["name": .string(name), "arguments": arguments] }

    /// A tool's answer: its structured content, or the JSON in its first text block. A tool error is a failure.
    public static func toolResult(_ result: JSONValue) -> Result<JSONValue, RPCError> {
        let text = result["content"]?.array?.first?["text"]?.string
        if result["isError"]?.bool == true { return .failure(RPCError(code: 0, message: text ?? "T3 Code refused.")) }
        if let structured = result["structuredContent"], structured != .null { return .success(structured) }
        if let text, let parsed = JSONValue.parse(Data(text.utf8)) { return .success(parsed) }
        return .success(result)
    }

    public static func projectList(environment: String?, cursor: String?) -> JSONValue {
        var arguments: [String: JSONValue] = ["limit": 100]
        if let environment { arguments["environmentId"] = .string(environment) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        return .object(arguments)
    }

    /// One page of projects, without archived ones and the scratch entry, and the cursor of the next page.
    public static func projects(_ page: JSONValue) -> (projects: [HandOffCard.Project], next: String?) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = page["projects"]?.array ?? page["items"]?.array ?? page.array ?? []
        let projects = items.compactMap { item -> HandOffCard.Project? in
            guard let id = item["projectId"]?.string ?? item["id"]?.string, item["archived"]?.bool != true,
                  item["archivedAt"]?.string == nil, item["scratch"]?.bool != true else { return nil }
            let name = item["title"]?.string ?? item["name"]?.string ?? id
            let updated = (item["lastActivityAt"]?.string ?? item["updatedAt"]?.string).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return HandOffCard.Project(id: id, name: name, environment: item["environmentId"]?.string,
                                       environmentName: item["environmentLabel"]?.string ?? item["environmentName"]?.string, updatedAt: updated)
        }
        let next = page["nextCursor"]?.string
        return (projects, next)
    }

    public static func launch(project: HandOffCard.Project, title: String, message: String, requestID: String,
                              destination: T3Destination) -> JSONValue {
        var arguments: [String: JSONValue] = ["projectId": .string(project.id), "title": .string(String(title.prefix(80))),
                                              "message": .string(String(message.prefix(120_000))), "clientRequestId": .string(requestID)]
        if let environment = project.environment { arguments["environmentId"] = .string(environment) }
        if let provider = destination.provider, let model = destination.model {
            arguments["modelSelection"] = ["instanceId": .string(provider), "model": .string(model)]
        }
        return .object(arguments)
    }

    /// T3 Code refused the token, before doing anything with the request.
    public struct Unauthorized: LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? { "T3 Code's sign-in ran out. Connect it again on the Ghostwrite page." }
    }

    /// Whether a launch that failed over MCP may be tried again through the command line: only when the thread surely
    /// was not started, because the launch was never sent, never reached the server, or was refused for its token.
    /// Anything else, a timeout or an unreadable answer included, may have started it, so the error is shown instead.
    public static func mayRetryLaunch(after error: any Error, launchSent: Bool) -> Bool {
        guard launchSent else { return true }
        if error is Unauthorized { return true }
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(error.code)
    }

    public struct Launched: Equatable, Sendable {
        public var threadID: String
        public var environmentID: String?
        public var link: String?
    }

    public static func launched(_ value: JSONValue) -> Launched? {
        guard let thread = value["threadId"]?.string ?? value["thread"]?["id"]?.string else { return nil }
        return Launched(threadID: thread, environmentID: value["environmentId"]?.string, link: value["link"]?.string)
    }

    /// Opens the thread in the app. The thread id carries a colon, so it is percent-encoded.
    public static func threadURL(environment: String, thread: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "t3code://threads/\(environment)/\(thread.addingPercentEncoding(withAllowedCharacters: allowed) ?? thread)"
    }

    /// A short title for the thread, from the first words of the request.
    public static func title(for words: String) -> String {
        let firstLine = words.split(whereSeparator: \.isNewline).first.map(String.init) ?? words
        let clipped = firstLine.split(separator: " ").prefix(8).joined(separator: " ")
        return clipped.isEmpty ? "Lip Service hand-off" : clipped
    }
}
