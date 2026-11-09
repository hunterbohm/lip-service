import Foundation

/// What a live talk gives an agent of T3 Code, so "start a thread in Lip Service to fix the login" works by voice. T3 Code's
/// MCP server offers about seventy tools, from deleting projects to driving a browser, and describing them all costs a
/// voice call tens of thousands of tokens on every turn. The agent reaches it through a small bridge of Lip Service's own
/// (`Dictation --t3-mcp`) that serves four of them: list projects, start a thread, and list and read threads. The bridge
/// holds the token, so it is never in the agent's command line, environment, prompt or logs, and anything else the agent
/// asks for is refused there, whatever the agent's own settings say.
public enum T3Talk {
    public static let serverName = "lip-service-t3"
    /// How Claude Code names a tool of this server: `mcp__lip-service-t3__t3_thread_launch`.
    public static let toolPrefix = "mcp__\(serverName)__"

    public static let listProjects = "t3_project_list"
    public static let launchThread = "t3_thread_launch"
    /// The tools that only read. They go ahead without asking, as reading does everywhere in a talk.
    public static let readingTools: Set<String> = [listProjects, "t3_thread_list", "t3_thread_read"]
    /// Every tool the agent keeps.
    public static let exposedTools: Set<String> = readingTools.union([launchThread])

    /// The server's own name for a tool of ours, or nil for any other tool.
    public static func tool(of request: PermissionRequest) -> String? {
        guard let name = request.toolName, name.hasPrefix(toolPrefix) else { return nil }
        return String(name.dropFirst(toolPrefix.count))
    }

    /// What `t3_thread_launch` takes from the agent: the project, the task and a title. Not how the thread runs, such as
    /// its runtime mode or workspace, which stay T3 Code's own defaults, as for a hand-off.
    public static let launchArguments: Set<String> = ["projectId", "environmentId", "title", "message", "clientRequestId"]
    public static let launchDescription = """
        Start one new thread in a T3 Code project. Pass the project's `projectId` from t3_project_list, a short `title`, and the \
        task in full as `message`. It starts on its own; don't wait for it.
        """

    /// The server's tool list cut to ours. The thread-starting tool is described afresh and takes only `launchArguments`;
    /// output schemas go, since the answers are read as they come.
    public static func exposed(_ tools: [JSONValue]) -> [JSONValue] {
        tools.compactMap { tool -> JSONValue? in
            guard case .object(var fields) = tool, let name = tool["name"]?.string, exposedTools.contains(name) else { return nil }
            fields["outputSchema"] = nil
            if name == launchThread, case .object(var schema)? = fields["inputSchema"] {
                if case .object(let properties)? = schema["properties"] { schema["properties"] = .object(properties.filter { launchArguments.contains($0.key) }) }
                if let required = schema["required"]?.array { schema["required"] = .array(required.filter { launchArguments.contains($0.string ?? "") }) }
                fields["inputSchema"] = .object(schema)
                fields["description"] = .string(launchDescription)
            }
            return .object(fields)
        }
    }

    /// The arguments to pass to T3 Code for a call of `tool`, or nil when the agent may not call it. A thread is started
    /// with a request id, the agent's or a new one, so a call that is repeated after a lost answer starts one thread.
    public static func arguments(for tool: String, _ given: JSONValue?, requestID: @autoclosure () -> String) -> JSONValue? {
        guard exposedTools.contains(tool) else { return nil }
        var fields: [String: JSONValue] = [:]
        if case .object(let object)? = given { fields = object }
        if tool == listProjects, fields["limit"] == nil { fields["limit"] = 100 }
        if tool == launchThread {
            fields = fields.filter { launchArguments.contains($0.key) }
            if fields["clientRequestId"]?.string?.isEmpty != false { fields["clientRequestId"] = .string(requestID()) }
        }
        return .object(fields)
    }

    /// Set on the session before the talk starts: permissions are asked as in Claude Code's "default" mode. Left to itself,
    /// Claude Code starts in "auto" mode, or in whatever `defaultMode` its settings name, and there an MCP tool call such
    /// as starting a thread goes ahead with no question to answer. A talk that can't set it starts without the tools.
    public static let sessionOptions: [ConfigChoice] = [.option(id: "mode", value: "default")]

    /// Whether this permission request is for starting a thread.
    public static func isLaunch(_ request: PermissionRequest) -> Bool { tool(of: request) == launchThread }

    /// The project, title and task of a thread the agent wants to start, as it passes them to T3 Code.
    public static func launchDetails(_ request: PermissionRequest) -> (projectID: String?, title: String, message: String) {
        let title = request.input?["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = request.input?["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (request.input?["projectId"]?.string, title, message)
    }

    /// What is said and shown when the agent asks to start a thread: where, and what for. Built from what the agent
    /// passes, never from what it says, so the question is the thread it would start.
    public static func launchPhrase(_ request: PermissionRequest, projectName: String?) -> String {
        let details = launchDetails(request)
        let task = String((details.title.isEmpty ? details.message : details.title).prefix(60))
        let place = projectName.map { " in \($0)" } ?? ""
        return task.isEmpty ? "Start a T3 Code thread\(place)" : "Start a T3 Code thread\(place) called \(task)"
    }

    /// Added to each turn of a talk whose session has the T3 tools. It leaves the asking to Lip Service, which asks for a
    /// yes of its own before a thread starts, so the agent does not ask twice.
    public static let note = """
        You can start threads in T3 Code for me. When I ask you to start work, such as "start a thread in Lip Service to fix the login bug": \
        call t3_project_list, find the project I named, and call t3_thread_launch with its id, a title of a few words, and a message that \
        gives the task in full, as if I had typed it. Lip Service asks me to say yes before the thread starts, so don't ask me first. If I \
        named no project, or two could fit, ask me which in one short sentence. Once it is started, say only that, in one short sentence, such as \
        "Started it in Lip Service." Don't do the task yourself, wait for the thread to finish, or read its link out.
        """
}
