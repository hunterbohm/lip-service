import AppKit
import DictationCore
import Foundation

/// T3 Code's local server, reached through its MCP endpoint with a token from a one-time pairing code. Found from the
/// runtime file a running server writes, so the port is never assumed.
struct T3Client: Sendable {
    let destination: T3Destination
    let secrets: any SecretStore
    let home: String
    let origin: String

    init(destination: T3Destination, secrets: any SecretStore) throws {
        self.destination = destination
        self.secrets = secrets
        let homes = T3.homes(configured: destination.home, environment: ProcessInfo.processInfo.environment,
                             userHome: FileManager.default.homeDirectoryForCurrentUser.path)
        for home in homes {
            guard let data = FileManager.default.contents(atPath: home + "/userdata/server-runtime.json"),
                  let runtime = T3.runtime(data), runtime.pid.map(Self.isRunning) ?? true else { continue }
            self.home = home
            origin = runtime.origin
            return
        }
        throw AgentError("T3 Code isn't running. Open it, then try again.")
    }

    /// A server run by another user answers EPERM, which still means it is there.
    private static func isRunning(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 || errno == EPERM }

    private var tokenKey: String { "t3-token " + origin }

    var token: T3.Token? {
        guard let stored = secrets.read(tokenKey), let token = try? JSONDecoder.iso.decode(T3.Token.self, from: Data(stored.utf8)),
              token.expires > Date().addingTimeInterval(60) else { return nil }
        return token
    }

    var isSignedIn: Bool { token != nil }

    /// Registers Lip Service as a client, approves it with the user's pairing code, and keeps the token in the Keychain.
    /// The approval answers with the redirect a browser would follow, which carries the code, so no browser is needed.
    func signIn(pairingCode: String) async throws {
        let redirect = "http://127.0.0.1:47613/t3-callback"
        let registered = try await json("POST", "/oauth/mcp/register", T3.registration(redirect: redirect))
        guard let clientID = registered["client_id"]?.string else { throw AgentError("T3 Code didn't register Lip Service.") }
        let pkce = T3.PKCE.random(), state = UUID().uuidString
        let authorization = T3.authorization(clientID: clientID, redirect: redirect, pkce: pkce, state: state, resource: origin + "/mcp")
        let approved = try await json("POST", "/oauth/mcp/decision", T3.decision(authorization: authorization, pairingCode: pairingCode))
        guard let target = approved["redirectTo"]?.string, let code = T3.code(fromRedirect: target, state: state) else {
            throw AgentError(approved["message"]?.string ?? "T3 Code didn't accept that pairing code.")
        }
        var request = URLRequest(url: URL(string: origin + "/oauth/mcp/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = T3.tokenForm(code: code, redirect: redirect, clientID: clientID, verifier: pkce.verifier, resource: origin + "/mcp")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = T3.token(data, origin: origin, now: Date()) else {
            throw AgentError("T3 Code didn't give a token: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        try secrets.save(tokenKey, String(decoding: try JSONEncoder.iso.encode(token), as: UTF8.self))
    }

    func signOut() { secrets.delete(tokenKey) }

    /// Every project, page by page.
    func projects() async throws -> [HandOffCard.Project] {
        let session = try await MCPSession.open(origin: origin, token: try requireToken())
        var all: [HandOffCard.Project] = [], cursor: String?
        repeat {
            let page = try await session.call("t3_project_list", T3.projectList(environment: nil, cursor: cursor))
            let read = T3.projects(page)
            all += read.projects
            cursor = read.next
        } while cursor != nil && all.count < 2_000
        return all
    }

    /// Starts the thread and opens it in T3 Code. Without a token, or when MCP surely did not start it, falls back to
    /// the T3 command line on this Mac, which needs no sign-in.
    func launch(project: HandOffCard.Project, message: String, title: String, requestID: String) async throws -> T3.Launched {
        let launched: T3.Launched
        var sent = false
        do {
            let session = try await MCPSession.open(origin: origin, token: try requireToken())
            sent = true
            let result = try await session.call("t3_thread_launch", T3.launch(project: project, title: title, message: message,
                                                                             requestID: requestID, destination: destination))
            guard let read = T3.launched(result) else { throw AgentError("T3 Code didn't say which thread it started.") }
            launched = read
        } catch {
            guard T3.mayRetryLaunch(after: error, launchSent: sent) else { throw error }
            launched = try await cli(project: project, message: message, title: title, after: error)
        }
        if let environment = launched.environmentID ?? project.environment, let url = URL(string: T3.threadURL(environment: environment, thread: launched.threadID)) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        return launched
    }

    private func requireToken() throws -> String {
        guard let token else { throw AgentError("Connect T3 Code on the Ghostwrite page first.") }
        return token.accessToken
    }

    private func cli(project: HandOffCard.Project, message: String, title: String, after error: any Error) async throws -> T3.Launched {
        let result: Process.Finished
        do {
            result = try await Process.runToEnd(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                              ["-lc", "exec t3 thread start --json --title \(ShellQuote.quote(title)) \(ShellQuote.quote(project.id)) -"],
                                              environment: ProcessInfo.processInfo.environment.merging(["T3CODE_HOME": home]) { $1 },
                                              input: Data(message.utf8), timeout: 30)
        } catch {
            throw AgentError("T3 Code: \(error.localizedDescription)")
        }
        guard !result.timedOut, result.status == 0, let value = JSONValue.parse(result.output), let launched = T3.launched(value) else {
            throw AgentError("T3 Code didn't start the thread: \(error.localizedDescription)")
        }
        return launched
    }

    private func json(_ method: String, _ path: String, _ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: origin + path)!, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data()
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let value = JSONValue.parse(data) else { throw AgentError("T3 Code sent back something unreadable.") }
        return value
    }
}

/// MCP over streamable HTTP: initialize, then tool calls carrying the session id the server gave. Answers come as
/// JSON or as a short event stream.
struct MCPSession: Sendable {
    let endpoint: URL
    let token: String
    let session: String?

    static func open(origin: String, token: String) async throws -> MCPSession {
        let endpoint = URL(string: origin + "/mcp")!
        let start = MCPSession(endpoint: endpoint, token: token, session: nil)
        let (_, headers) = try await start.post(RPCMessage.request(id: 1, method: "initialize", params: T3.mcpInitialize()))
        let opened = MCPSession(endpoint: endpoint, token: token, session: headers["Mcp-Session-Id"] ?? headers["mcp-session-id"])
        _ = try? await opened.post(RPCMessage.notification(method: "notifications/initialized", params: [:]))
        return opened
    }

    func call(_ tool: String, _ arguments: JSONValue) async throws -> JSONValue {
        let (value, _) = try await post(RPCMessage.request(id: 2, method: "tools/call", params: T3.toolCall(tool, arguments)))
        guard case .response(_, let result) = value.flatMap({ RPCMessage.parse($0.data()) }) else {
            throw AgentError("T3 Code didn't answer \(tool).")
        }
        return try T3.toolResult(try result.get()).get()
    }

    /// Any request of the server, answered with its result, for the bridge that passes an agent's calls on.
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let (value, _) = try await post(RPCMessage.request(id: 3, method: method, params: params))
        guard case .response(_, let result) = value.flatMap({ RPCMessage.parse($0.data()) }) else { throw AgentError("T3 Code didn't answer \(method).") }
        return try result.get()
    }

    private func post(_ message: JSONValue) async throws -> (JSONValue?, [String: String]) {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = message.data()
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw T3.Unauthorized() }
        guard (200..<300).contains(status) else { throw AgentError("T3 Code answered \(status).") }
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream") {
            let events = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .compactMap { $0.hasPrefix("data:") ? JSONValue.parse(Data($0.dropFirst(5).utf8)) : nil }
            return (events.last { $0["id"] != nil } ?? events.last, headers)
        }
        return (data.isEmpty ? nil : JSONValue.parse(data), headers)
    }
}

struct T3Sender: HandOffSender {
    let destination: T3Destination

    func send(_ request: HandOffRequest, _ context: HandOffContext) async throws -> String {
        guard let project = context.project else { throw AgentError("Pick a project first.") }
        let client = try T3Client(destination: destination, secrets: context.secrets)
        let message = request.message(includeWindowText: context.includeWindowText)
        if context.dryRun { return "Dry run: a thread in \(project.name) with \(message.count) characters, not started." }
        let launched = try await client.launch(project: project, message: message, title: T3.title(for: request.words), requestID: request.id)
        print("t3 thread: \(launched.threadID)")
        return "\(context.agent.name) keeps going in T3 Code, in \(project.name)."
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
