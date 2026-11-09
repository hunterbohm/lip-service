import Foundation

/// The app a step of the agent's work uses, so the island can show that app's own icon beside the step.
public enum StepApp: String, Equatable, Sendable, CaseIterable {
    case t3Code, hermes, terminal, browser, gmail, mail, calendar, drive, sheets, slack, notion, stripe, linear, discord,
         messages, obsidian, github, weather, callBack

    public var name: String {
        switch self {
        case .t3Code: "T3 Code"
        case .hermes: "Hermes"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .gmail: "Gmail"
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .drive: "Google Drive"
        case .sheets: "Google Sheets"
        case .slack: "Slack"
        case .notion: "Notion"
        case .stripe: "Stripe"
        case .linear: "Linear"
        case .discord: "Discord"
        case .messages: "Messages"
        case .obsidian: "Obsidian"
        case .github: "GitHub"
        case .weather: "Weather"
        case .callBack: "Call back"
        }
    }

    /// The bundle IDs of the apps whose icon stands for it, the first one installed winning. Empty for a service with no
    /// Mac app, and for the browser, which is whichever one opens links.
    public var bundleIDs: [String] {
        switch self {
        case .t3Code: ["com.t3tools.t3code"]
        case .hermes: ["com.nousresearch.hermes"]
        case .terminal: ["com.apple.Terminal"]
        case .mail: ["com.apple.mail"]
        case .calendar: ["com.apple.iCal"]
        case .drive: ["com.google.drivefs"]
        case .sheets: ["com.google.drivefs.shortcuts.sheets"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        case .notion: ["notion.id"]
        case .linear: ["com.linear"]
        case .discord: ["com.hnc.Discord"]
        case .messages: ["com.apple.MobileSMS"]
        case .obsidian: ["md.obsidian"]
        case .github: ["com.github.GitHubClient"]
        case .weather: ["com.apple.weather"]
        case .browser, .gmail, .stripe, .callBack: []
        }
    }

    /// App names to look for in the Applications folders when no bundle ID is found, since a nightly build is named
    /// apart from the release.
    public var appNames: [String] {
        switch self {
        case .t3Code: ["T3 Code (Nightly)", "T3 Code"]
        case .hermes: ["Hermes"]
        default: []
        }
    }

    /// The SF Symbol drawn on a tile of `tint` when no app's icon is found.
    public var symbol: String {
        switch self {
        case .t3Code: "chevron.left.forwardslash.chevron.right"
        case .hermes: "sparkle"
        case .terminal: "terminal.fill"
        case .browser: "safari.fill"
        case .gmail, .mail: "envelope.fill"
        case .calendar: "calendar"
        case .drive: "externaldrive.fill"
        case .sheets: "tablecells.fill"
        case .slack: "number"
        case .notion: "doc.text.fill"
        case .stripe: "creditcard.fill"
        case .linear: "line.3.horizontal.decrease"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .messages: "message.fill"
        case .obsidian: "diamond.fill"
        case .github: "arrow.triangle.branch"
        case .weather: "cloud.sun.fill"
        case .callBack: "phone.fill"
        }
    }

    public var tint: TalkIsland.RGB {
        switch self {
        case .t3Code: (0.2, 0.2, 0.24)
        case .hermes: (0.55, 0.4, 0.95)
        case .terminal: (0.16, 0.16, 0.18)
        case .browser: (0.15, 0.5, 0.98)
        case .gmail: (0.92, 0.26, 0.21)
        case .mail: (0.2, 0.55, 0.98)
        case .calendar: (0.95, 0.3, 0.28)
        case .drive: (0.1, 0.62, 0.4)
        case .sheets: (0.1, 0.62, 0.35)
        case .slack: (0.38, 0.14, 0.4)
        case .notion: (0.25, 0.25, 0.27)
        case .stripe: (0.39, 0.36, 1)
        case .linear: (0.37, 0.42, 0.82)
        case .discord: (0.35, 0.4, 0.95)
        case .messages, .callBack: (0.2, 0.78, 0.35)
        case .obsidian: (0.49, 0.35, 0.9)
        case .github: (0.14, 0.16, 0.18)
        case .weather: (0.2, 0.6, 0.95)
        }
    }

    /// The app a result names, by its name or a word for it: "gmail", "Google Sheets", "vault".
    public static func named(_ text: String) -> StepApp? {
        let word = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !word.isEmpty else { return nil }
        let other: [String: StepApp] = ["vault": .obsidian, "email": .gmail, "imessage": .messages, "t3": .t3Code, "gcal": .calendar,
                                        "googlecalendar": .calendar, "web": .browser, "callback": .callBack]
        return other[word] ?? allCases.first { $0.rawValue.lowercased() == word || $0.name.lowercased().filter(\.isLetter) == word }
    }
}

extension ToolLine {
    private static let commandTools: Set<String> = ["terminal", "bash", "shell", "execute", "run_command"]

    /// A word in a tool's name and the app it stands for, apps by name first so `slack_send_message` is Slack.
    private static let appByTitle: [(String, StepApp)] = [
        ("t3_", .t3Code), ("t3-", .t3Code), ("gmail", .gmail), ("calendar", .calendar), ("gcal", .calendar), ("event", .calendar),
        ("drive", .drive), ("sheets", .sheets), ("slack", .slack), ("notion", .notion), ("stripe", .stripe), ("linear", .linear),
        ("discord", .discord), ("imessage", .messages), ("obsidian", .obsidian), ("vault", .obsidian), ("github", .github),
        ("weather", .weather), ("email", .mail), ("mail", .mail), ("inbox", .mail),
        ("web", .browser), ("browse", .browser), ("fetch", .browser), ("message", .messages),
        ("terminal", .terminal), ("bash", .terminal), ("shell", .terminal), ("execute", .terminal), ("python", .terminal),
    ]

    /// A command's program and the app it drives.
    private static let appByProgram: [String: StepApp] = [
        "t3-run": .t3Code, "t3": .t3Code, "gh": .github, "hermes": .hermes, "call-me-back": .callBack, "obsidian": .obsidian,
        "obsidian-cli": .obsidian, "stripe": .stripe, "stripe-invoices": .stripe,
    ]

    /// The app a tool call uses, read from the same title and kind as its line, so the island can show that app's icon.
    /// Only which app it is leaves the arguments, never a word of them. Nil when no app stands for the step.
    public static func app(title: String, kind: String?) -> StepApp? {
        let (tool, preview) = split(title)
        let name = tool.lowercased()
        if commandTools.contains(name) { return commandApp(preview) ?? .terminal }
        switch name {
        // What the agent does inside itself, such as loading a skill, keeps a plain symbol: a column of its own logo
        // would say nothing.
        case "skill_view", "skill", "skills_list", "skill_manage", "memory", "session_search", "todo":
            return nil
        case "read_file", "read", "write_file", "write", "patch", "edit", "search_files", "grep":
            return preview.lowercased().contains("/vault/") ? .obsidian : nil
        case "web_search", "web_extract", "fetch":
            return .browser
        case "execute_code":
            return .terminal
        case "tool_call":
            return nil
        default:
            if name.hasPrefix("browser") { return .browser }
            if kind == "execute", !preview.isEmpty { return commandApp(preview) ?? .terminal }
        }
        let words = title.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "(" }).prefix(2).joined(separator: " ")
        if let match = appByTitle.first(where: { words.contains($0.0) }) { return match.1 }
        return kind == "execute" ? .terminal : nil
    }

    /// The app a command drives, from its program or the app it checks: `t3-run` is T3 Code, `gog gmail search` Gmail.
    static func commandApp(_ text: String) -> StepApp? {
        let tokens = commandTokens(text)
        guard let first = tokens.first else { return nil }
        let program = String(first.split(separator: "/").last ?? "")
        guard isWord(program) else { return nil }
        return appByProgram[program.lowercased()] ?? service(tokens)?.app
    }

    /// Whether a tool call sets up a call back, so the island can say the agent will ring when the job is done.
    public static func promisesCallBack(title: String, kind: String?) -> Bool {
        let (tool, preview) = split(title)
        guard commandTools.contains(tool.lowercased()) || kind == "execute" else { return false }
        let tokens = commandTokens(preview)
        return tokens.first?.split(separator: "/").last.map(String.init) == "call-me-back" && tokens.dropFirst().first == "run"
    }

    private static let past: [String: String] = [
        "Checking": "Checked", "Running": "Ran", "Loading": "Loaded", "Reading": "Read", "Writing": "Wrote",
        "Searching": "Searched", "Starting": "Started", "Looking": "Looked", "Opening": "Opened", "Editing": "Edited",
        "Making": "Made", "Sending": "Sent", "Using": "Used", "Asking": "Asked", "Updating": "Updated", "Managing": "Managed",
        "Working": "Worked", "Thinking": "Thought", "Deleting": "Deleted", "Moving": "Moved", "Changing": "Changed",
        "Calling": "Called", "Scheduling": "Scheduled", "Setting": "Set", "Creating": "Created", "Adding": "Added",
        "Saving": "Saved", "Fetching": "Fetched",
    ]

    /// A step's line once the step is over: "Checking Gmail" becomes "Checked Gmail". A line that starts with a word this
    /// doesn't know stays as it is.
    public static func done(_ line: String) -> String {
        let verb = String(line.prefix { !$0.isWhitespace })
        guard let done = past[verb] else { return line }
        return done + line.dropFirst(verb.count)
    }

    /// The longest label beside the closed island, in characters.
    public static let shortLongest = 14

    private static let shortLines: [String: String] = [
        "Starting a thread in T3 Code": "New thread", "Checking what it remembers": "Memory", "Thinking it over": "Thinking",
        "Working on it": "Working", "Running some code": "Code", "Running a command": "Command", "Calling you back": "Calling back",
        "Sending that": "Sending", "Looking through its skills": "Skills", "Using the browser": "Browser",
        "Looking at a web page": "Web page", "Searching": "Searching", "Thinking": "Thinking",
    ]

    /// A step in a word or two, for the closed island: "Checking Gmail" is "Gmail", "Running t3-run status" is "t3-run
    /// status". The verb and the small words go, and a name is kept as the agent wrote it.
    public static func short(_ line: String) -> String {
        if let short = shortLines[line] { return short }
        if line.hasPrefix("Searching the web") { return "Web search" }
        if line.hasPrefix("Searching files") { return "File search" }
        let words = line.split(separator: " ").map(String.init)
        guard let verb = words.first, past[verb] != nil else { return clip(line, to: shortLongest) }
        let small: Set<String> = ["a", "an", "the", "your", "its", "some", "through", "at", "up", "on", "it", "that", "for", "over", "you", "in"]
        // The first word that says something, and the next one when it follows at once: "T3 Code", not "note vault".
        var kept: [String] = []
        var named = true
        for word in words.dropFirst() {
            if small.contains(word.lowercased()) {
                if kept.isEmpty { named = false; continue } else { break }
            }
            kept.append(word)
            if kept.count == 2 { break }
        }
        if kept.count == 2, kept[1] == "skill" || kept.joined(separator: " ").count > shortLongest { kept.removeLast() }
        guard !kept.isEmpty else { return verb }
        var label = kept.joined(separator: " ")
        // A program, a skill, a file or a site, which comes right after the verb, keeps its own spelling: "t3-run status".
        let names: Set<String> = ["Running", "Loading", "Reading", "Writing", "Editing", "Opening"]
        if !(named && names.contains(verb)) { label = label.prefix(1).uppercased() + label.dropFirst() }
        return clip(label, to: shortLongest)
    }

    static func clip(_ text: String, to most: Int) -> String {
        text.count > most ? text.prefix(most - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A result the agent puts on screen as data, which the island draws itself: flights for a route, or rows for tasks,
/// meetings, emails and other things. The agent sends it as JSON inside `<show>`.
public struct RichCard: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case flights(Flights)
        case rows([ResultRow])
    }

    public var body: Body
    /// Button labels. Pressing one sends its label to the agent as your next words.
    public var actions: [String]
    /// What the card is about. A newer card with the same key takes the older one's place, so results can come in live.
    public var key: String

    public init(body: Body, actions: [String] = [], key: String) { (self.body, self.actions, self.key) = (body, actions, key) }

    public static let optionsMost = 4
    public static let rowsMost = 4
    public static let actionsMost = 2
    public static let actionLongest = 28

    /// The card for what the agent wrote inside `<show>`, or nil when that isn't JSON of a kind the island draws, in
    /// which case it stays a card as before. Every field is optional but a flight's times and a row's title; long text is
    /// cut, and a link is kept only when it is a web or Obsidian address.
    public static func parse(_ body: String) -> RichCard? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.first == "{" || text.first == "[", let json = JSONValue.parse(Data(text.utf8)) else { return nil }
        if let items = json.array { return rows(items, actions: []) }
        switch string(json["type"], most: 20)?.lowercased() {
        case "flights", "flight":
            guard let from = string(json["from"], most: 18), let to = string(json["to"], most: 18) else { return nil }
            let options = (json["options"]?.array ?? json["flights"]?.array ?? []).compactMap(FlightOption.init).prefix(optionsMost)
            let flights = Flights(from: from, to: to, date: string(json["date"], most: 28), note: string(json["note"], most: 40),
                                  options: Array(options))
            return RichCard(body: .flights(flights), actions: actions(json), key: "flights:\(from)-\(to)".lowercased())
        case "list":
            return rows(json["items"]?.array ?? [], actions: actions(json))
        default:
            return rows([json], actions: actions(json))
        }
    }

    private static func rows(_ items: [JSONValue], actions: [String]) -> RichCard? {
        let rows = items.compactMap(ResultRow.init)
        // Every item must be one the island draws; anything else is the agent showing JSON itself.
        guard !rows.isEmpty, rows.count == items.count else { return nil }
        let kept = Array(rows.prefix(rowsMost))
        return RichCard(body: .rows(kept), actions: actions, key: "rows:" + kept.map(\.title).joined(separator: "|").lowercased())
    }

    private static func actions(_ json: JSONValue) -> [String] {
        var kept: [String] = []
        for action in json["actions"]?.array ?? [] {
            guard let label = string(action, most: actionLongest) ?? string(action["label"], most: actionLongest), !kept.contains(label) else { continue }
            kept.append(label)
        }
        return Array(kept.prefix(actionsMost))
    }

    /// A field's text on one line, cut to `most` characters. A number reads as written: 214, not 214.0.
    static func string(_ value: JSONValue?, most: Int) -> String? {
        let raw: String
        switch value {
        case .string(let text): raw = text
        case .number(let number): raw = number.rounded() == number && abs(number) < 1e12 ? String(Int(number)) : String(number)
        default: return nil
        }
        let text = Speech.collapse(raw)
        return text.isEmpty ? nil : ToolLine.clip(text, to: most)
    }

    /// A link the island may open on a click: a web page, or a note in Obsidian.
    static func link(_ value: JSONValue?) -> URL? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), text.count <= 2000, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "obsidian"].contains(scheme) else { return nil }
        return url
    }
}

public struct Flights: Equatable, Sendable {
    public var from: String
    public var to: String
    public var date: String?
    public var note: String?
    public var options: [FlightOption]

    public init(from: String, to: String, date: String? = nil, note: String? = nil, options: [FlightOption] = []) {
        (self.from, self.to, self.date, self.note, self.options) = (from, to, date, note, options)
    }

    /// "Fri, Nov 14 · 1 adult · nonstop".
    public var subtitle: String { [date, note].compactMap { $0 }.joined(separator: " · ") }
}

public struct FlightOption: Equatable, Sendable {
    public var airline: String
    public var depart: String
    public var arrive: String
    public var duration: String?
    public var stops: String?
    public var price: String?
    public var best: Bool
    public var url: URL?

    public init(airline: String, depart: String, arrive: String, duration: String? = nil, stops: String? = nil, price: String? = nil,
                best: Bool = false, url: URL? = nil) {
        (self.airline, self.depart, self.arrive, self.duration) = (airline, depart, arrive, duration)
        (self.stops, self.price, self.best, self.url) = (stops, price, best, url)
    }

    init?(_ json: JSONValue) {
        guard let depart = RichCard.string(json["depart"] ?? json["departs"], most: 12),
              let arrive = RichCard.string(json["arrive"] ?? json["arrives"], most: 12) else { return nil }
        var price = RichCard.string(json["price"], most: 12)
        if json["price"]?.number != nil, let amount = price { price = "$" + amount }
        self.init(airline: RichCard.string(json["airline"], most: 24) ?? "", depart: depart, arrive: arrive,
                  duration: RichCard.string(json["duration"], most: 12), stops: RichCard.string(json["stops"], most: 14), price: price,
                  best: json["best"]?.bool ?? false, url: RichCard.link(json["url"]))
    }

    /// "United · 3h 55m · Nonstop".
    public var detail: String { [airline.isEmpty ? nil : airline, duration, stops].compactMap { $0 }.joined(separator: " · ") }
}

/// One thing the agent found or made, as a row: a task, a meeting, an email, or anything with a title.
public struct ResultRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case task(done: Bool)
        /// The month and day for the date tile, "NOV" and "12", both empty when the date isn't known.
        case event(month: String, day: String)
        case email
        case item
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var url: URL?
    /// The app it lives in, for its icon.
    public var app: StepApp?

    public init(kind: Kind, title: String, detail: String = "", url: URL? = nil, app: StepApp? = nil) {
        (self.kind, self.title, self.detail, self.url, self.app) = (kind, title, detail, url, app)
    }

    init?(_ json: JSONValue) {
        func text(_ key: String, _ most: Int = 60) -> String? { RichCard.string(json[key], most: most) }
        func joined(_ parts: [String?]) -> String { ToolLine.clip(parts.compactMap { $0 }.joined(separator: " · "), to: 80) }
        let url = RichCard.link(json["url"])
        let named = text("app").flatMap(StepApp.named)
        switch text("type", 20)?.lowercased() {
        case "task", "todo":
            guard let title = text("title") else { return nil }
            let place = text("where", 24)
            self.init(kind: .task(done: json["done"]?.bool ?? false), title: [text("id", 14), title].compactMap { $0 }.joined(separator: " · "),
                      detail: joined([text("status", 24), text("due", 24).map { "due \($0)" }, place]), url: url,
                      app: named ?? place.flatMap(StepApp.named))
        case "event", "meeting":
            guard let title = text("title") else { return nil }
            let date = text("date", 24).flatMap(Self.day)
            let when = [date?.weekday ?? (date == nil ? text("date", 24) : nil), text("time", 28)].compactMap { $0 }.joined(separator: " ")
            self.init(kind: .event(month: date?.month ?? "", day: date?.day ?? ""), title: title,
                      detail: joined([when.isEmpty ? nil : when, text("where", 28)]), url: url, app: named ?? .calendar)
        case "email", "mail":
            guard let subject = text("subject") ?? text("title") else { return nil }
            let from = text("from", 28)
            self.init(kind: .email, title: from.map { "\($0): “\(subject)”" } ?? subject, detail: joined([text("time", 24), text("snippet", 60)]),
                      url: url, app: named ?? .gmail)
        case "item", "result", "link":
            guard let title = text("title") else { return nil }
            self.init(kind: .item, title: title, detail: joined([text("detail", 80)]), url: url, app: named)
        default:
            return nil
        }
    }

    /// The month, day and weekday of a date written as 2026-11-12, or as "Nov 12".
    static func day(_ text: String) -> (month: String, day: String, weekday: String?)? {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        if let match = text.firstMatch(of: /^(\d{4})-(\d{1,2})-(\d{1,2})/), let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
           (1...12).contains(month), (1...31).contains(day) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            let weekday = date.map { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][calendar.component(.weekday, from: $0) - 1] }
            return (months[month - 1], String(day), weekday)
        }
        if let match = text.firstMatch(of: /([A-Za-z]{3})[a-z]*\.? (\d{1,2})\b/), let month = months.first(where: { $0 == match.1.uppercased() }),
           let day = Int(match.2), (1...31).contains(day) {
            return (month, String(day), nil)
        }
        return nil
    }
}

/// Something the island keeps under its header for a while after the agent put it there: a line of what it did, its
/// word that it will call back, or a result it draws.
public struct IslandNotice: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case callBack(agent: String)
        case rich(RichCard)
    }

    public var content: Content
    public var added: Instant
    /// The button pressed on it. A result's buttons work once, so a second click can't send the words twice.
    public var chosen: String?

    public init(content: Content, added: Instant, chosen: String? = nil) { (self.content, self.added, self.chosen) = (content, added, chosen) }

    /// The same notice again takes the first one's place.
    public var key: String {
        switch content {
        case .text(let text): "text:" + text
        case .callBack: "callback"
        case .rich(let card): card.key
        }
    }

    public var id: String { key }

    public var isRich: Bool { if case .rich = content { true } else { false } }
}
