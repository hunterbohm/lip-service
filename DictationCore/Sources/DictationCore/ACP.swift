import Foundation

/// Any JSON value, for the parts of the Agent Client Protocol whose shape the agent decides.
public enum JSONValue: Equatable, Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    public static func parse(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }

    public func prettyData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

/// Newline-delimited JSON over a pipe: bytes go in as they arrive, whole lines come out.
public struct LineFramer: Sendable {
    private var buffer = Data()
    /// A line longer than this is dropped rather than held, so a runaway agent cannot fill memory.
    public static let longestLine = 8 << 20

    public init() {}

    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { lines.append(Data(line)) }
        }
        if buffer.count > Self.longestLine { buffer = Data() }
        return lines
    }

    public static func frame(_ message: JSONValue) -> Data { message.data() + Data([0x0A]) }
}

/// One JSON-RPC 2.0 message from the agent.
public enum RPCMessage: Equatable, Sendable {
    case request(id: JSONValue, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: JSONValue, result: Result<JSONValue, RPCError>)

    public static func parse(_ line: Data) -> RPCMessage? {
        guard let value = JSONValue.parse(line), case .object(let object) = value else { return nil }
        let id = object["id"]
        if let method = object["method"]?.string {
            let params = object["params"] ?? .null
            if let id, id != .null { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { return nil }
        if let error = object["error"] {
            return .response(id: id, result: .failure(RPCError(code: Int(error["code"]?.number ?? 0), message: error["message"]?.string ?? "error")))
        }
        return .response(id: id, result: .success(object["result"] ?? .null))
    }

    public static func request(id: Int, method: String, params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
    }

    public static func notification(method: String, params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }

    public static func result(id: JSONValue, _ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id, "result": result] }

    public static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

public struct RPCError: Error, Equatable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { (self.code, self.message) = (code, message) }
    public var errorDescription: String? { message }
    public static let methodNotFound = -32601
}

/// The Agent Client Protocol messages Lip Service sends, and what it reads from the agent's answers.
public enum ACP {
    public static let protocolVersion = 1

    /// No file system or terminal: the agent works with its own tools, and Lip Service only shows and answers.
    public static func initialize(version: String) -> JSONValue {
        ["protocolVersion": .number(Double(protocolVersion)),
         "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
         "clientInfo": ["name": "lip-service", "version": .string(version)]]
    }

    public static func newSession(cwd: String, meta: JSONValue? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "mcpServers": []]
        if let meta { params["_meta"] = meta }
        return .object(params)
    }

    public static func set(_ choice: ConfigChoice, session: String) -> (method: String, params: JSONValue) {
        switch choice {
        case .option(let id, let value):
            ("session/set_config_option", ["sessionId": .string(session), "configId": .string(id), "value": .string(value)])
        case .model(let model):
            ("session/set_model", ["sessionId": .string(session), "modelId": .string(model)])
        }
    }

    public static func prompt(_ text: String, session: String) -> JSONValue {
        ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]]
    }

    public static func cancel(session: String) -> JSONValue { ["sessionId": .string(session)] }

    public static func permissionAnswer(optionID: String?) -> JSONValue {
        guard let optionID else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
    }
}

/// A select setting the agent offers, such as its model or effort.
public struct ConfigOption: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public var value: String
        public var name: String
    }

    public var id: String
    public var name: String
    public var category: String?
    public var current: String?
    public var choices: [Choice]

    public static func parse(_ list: JSONValue?) -> [ConfigOption] {
        (list?.array ?? []).compactMap { item in
            guard let id = item["id"]?.string else { return nil }
            let choices = (item["options"]?.array ?? []).flatMap { option -> [Choice] in
                if let value = option["value"]?.string { return [Choice(value: value, name: option["name"]?.string ?? value)] }
                // Grouped options nest their choices one level down.
                return (option["options"]?.array ?? []).compactMap { inner in
                    inner["value"]?.string.map { Choice(value: $0, name: inner["name"]?.string ?? $0) }
                }
            }
            return ConfigOption(id: id, name: item["name"]?.string ?? id, category: item["category"]?.string,
                                current: item["currentValue"]?.string, choices: choices)
        }
    }
}

/// What a new session told about itself: its id, its settings, and the models picked with `session/set_model`.
public struct SessionInfo: Equatable, Sendable {
    public var id: String
    public var options: [ConfigOption]
    public var models: [ConfigOption.Choice]
    public var currentModel: String?

    public static func parse(_ result: JSONValue) -> SessionInfo? {
        guard let id = result["sessionId"]?.string else { return nil }
        let models = (result["models"]?["availableModels"]?.array ?? []).compactMap { model in
            model["modelId"]?.string.map { ConfigOption.Choice(value: $0, name: model["name"]?.string ?? $0) }
        }
        return SessionInfo(id: id, options: ConfigOption.parse(result["configOptions"]), models: models,
                           currentModel: result["models"]?["currentModelId"]?.string)
    }
}

/// A `session/update` notification, reduced to what the card shows.
public enum SessionUpdate: Equatable, Sendable {
    case message(String)
    case thought(String)
    case tool(title: String, status: String?)
    case options([ConfigOption])
    case other(String)

    public static func parse(_ params: JSONValue) -> (session: String, update: SessionUpdate)? {
        guard let session = params["sessionId"]?.string, let update = params["update"],
              let kind = update["sessionUpdate"]?.string else { return nil }
        let parsed: SessionUpdate = switch kind {
        case "agent_message_chunk": .message(text(update["content"]))
        case "agent_thought_chunk": .thought(text(update["content"]))
        case "tool_call", "tool_call_update": .tool(title: update["title"]?.string ?? "", status: update["status"]?.string)
        case "config_option_update": .options(ConfigOption.parse(update["configOptions"]))
        default: .other(kind)
        }
        return (session, parsed)
    }

    /// A content block's text. Images and other blocks have none.
    static func text(_ content: JSONValue?) -> String {
        if let blocks = content?.array { return blocks.map { text($0) }.joined() }
        return content?["type"]?.string == "text" ? content?["text"]?.string ?? "" : ""
    }
}

/// The agent asking before it acts: what it wants to do and the answers it offers.
public struct PermissionRequest: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var id: String
        public var name: String
        /// allow_once, allow_always, reject_once or reject_always.
        public var kind: String
        public init(id: String, name: String, kind: String) { (self.id, self.name, self.kind) = (id, name, kind) }
    }

    public var rpcID: JSONValue
    public var session: String
    public var title: String
    public var options: [Option]
    /// What the tool does, as the agent says: read, edit, delete, move, search, execute, think, fetch or other.
    public var toolKind: String?

    public init(rpcID: JSONValue, session: String, title: String, options: [Option], toolKind: String? = nil) {
        (self.rpcID, self.session, self.title, self.options, self.toolKind) = (rpcID, session, title, options, toolKind)
    }

    public static func parse(id: JSONValue, params: JSONValue) -> PermissionRequest? {
        guard let session = params["sessionId"]?.string else { return nil }
        let options = (params["options"]?.array ?? []).compactMap { option -> Option? in
            guard let id = option["optionId"]?.string else { return nil }
            return Option(id: id, name: option["name"]?.string ?? id, kind: option["kind"]?.string ?? "")
        }
        let call = params["toolCall"]
        let title = call?["title"]?.string ?? SessionUpdate.text(call?["content"]?.array?.first?["content"])
        return PermissionRequest(rpcID: id, session: session, title: title.isEmpty ? "The agent wants to use a tool." : title, options: options,
                                 toolKind: call?["kind"]?.string)
    }

    /// The option a refusal picks. None when the agent offered no reject option, which is answered as cancelled.
    public var rejection: Option? { options.first { $0.kind.hasPrefix("reject") } }
}
