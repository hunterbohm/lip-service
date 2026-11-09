import DictationCore
import Foundation

/// `Dictation --t3-mcp [T3_HOME]`: an MCP server on stdin and stdout that a live talk's agent starts, which passes four
/// of T3 Code's tools on to its MCP endpoint (see `T3Talk`). It reads the token from the Keychain itself, so the token
/// is never in the agent's command line or environment, where any program of the same user could read it, nor in
/// anything the agent can print. It writes nothing but MCP messages to stdout and never logs a token.
enum T3Bridge {
    /// The Keychain, or the JSON file LS_SECRETS names for a run that can't reach it, as for `--hand-off`.
    static func secrets() -> any SecretStore {
        let file = ProcessInfo.processInfo.environment["LS_SECRETS"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        return file.map { HandOffTest.FileSecrets(values: $0) } ?? Keychain()
    }

    static func run(home: String?) async -> Int32 {
        guard let client = try? T3Client(destination: T3Destination(home: home), secrets: secrets()) else {
            return fail("T3 Code isn't running.")
        }
        guard let token = client.token else { return fail("T3 Code isn't connected. Connect it on the Ghostwrite page.") }
        let upstream = Upstream(origin: client.origin, token: token.accessToken)
        let launches = LaunchIDs()
        while let line = readLine(strippingNewline: true) {
            guard case .request(let id, let method, let params)? = RPCMessage.parse(Data(line.utf8)) else { continue }
            let reply: JSONValue
            do { reply = RPCMessage.result(id: id, try await answer(method, params, upstream, launches)) } catch let error as RPCError {
                reply = RPCMessage.error(id: id, code: error.code, message: error.message)
            } catch {
                reply = RPCMessage.error(id: id, code: -32603, message: error.localizedDescription)
            }
            FileHandle.standardOutput.write(LineFramer.frame(reply))
        }
        return 0
    }

    private static func answer(_ method: String, _ params: JSONValue, _ upstream: Upstream, _ launches: LaunchIDs) async throws -> JSONValue {
        switch method {
        case "initialize":
            return ["protocolVersion": params["protocolVersion"] ?? "2025-06-18", "capabilities": ["tools": [:]],
                    "serverInfo": ["name": .string(T3Talk.serverName), "version": "1"]]
        case "ping":
            return [:]
        case "tools/list":
            var all: [JSONValue] = [], cursor: String?
            repeat {
                let page = try await upstream.request("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:])
                all += page["tools"]?.array ?? []
                cursor = page["nextCursor"]?.string
            } while cursor != nil && all.count < 1_000
            return ["tools": .array(T3Talk.exposed(all))]
        case "tools/call":
            guard let name = params["name"]?.string,
                  let arguments = T3Talk.arguments(for: name, params["arguments"], requestID: launches.id(for: params["arguments"])) else {
                return refusal("That tool isn't available in a live talk.")
            }
            do { return try await upstream.request("tools/call", ["name": .string(name), "arguments": arguments]) } catch {
                return refusal(error.localizedDescription)
            }
        default:
            throw RPCError(code: RPCError.methodNotFound, message: "\(method) isn't offered here.")
        }
    }

    /// One request id per distinct set of arguments for the life of this bridge, which is one talk. A launch the agent
    /// retries after both replies were lost then reuses its id, and T3 Code starts the thread once.
    private final class LaunchIDs {
        private var ids: [JSONValue: String] = [:]

        func id(for arguments: JSONValue?) -> String {
            let key = arguments ?? .null
            if let id = ids[key] { return id }
            let id = UUID().uuidString
            ids[key] = id
            return id
        }
    }

    /// A tool's answer that says it failed, so the agent reads why and can tell you.
    private static func refusal(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    /// T3 Code's MCP session, opened with the first request and opened again once if the server lost it, such as after a
    /// restart. A thread is started with a request id, so asking again after a lost answer starts one thread.
    private actor Upstream {
        private let origin: String, token: String
        private var session: MCPSession?

        init(origin: String, token: String) { (self.origin, self.token) = (origin, token) }

        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            do {
                return try await open().request(method, params)
            } catch is T3.Unauthorized {
                throw T3.Unauthorized()
            } catch let error as RPCError {
                throw error
            } catch {
                session = nil
                return try await open().request(method, params)
            }
        }

        private func open() async throws -> MCPSession {
            if let session { return session }
            let opened = try await MCPSession.open(origin: origin, token: token)
            session = opened
            return opened
        }
    }
}
