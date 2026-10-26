import Foundation

public struct HistoryApp: Equatable, Hashable, Codable, Sendable {
    public var name: String
    public var bundleID: String?

    public init(name: String, bundleID: String?) { (self.name, self.bundleID) = (name, bundleID) }
}

public struct HistoryEntry: Equatable, Identifiable, Codable, Sendable {
    /// A UUID for the app's own dictations, `willow:` plus Willow's id for imported ones, so a re-import finds
    /// what it already added.
    public var id: String
    public var date: Date
    public var text: String
    public var audioSeconds: Double?
    public var words: Int
    public var app: HistoryApp?

    public init(id: String = UUID().uuidString, date: Date = Date(), text: String, audioSeconds: Double?,
                app: HistoryApp?) {
        (self.id, self.date, self.text, self.audioSeconds, self.app) = (id, date, text, audioSeconds, app)
        words = Self.wordCount(text)
    }

    /// A lone dash is not a word.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { $0.contains { $0.isLetter || $0.isNumber } }
    }
}

public struct HistoryStats: Equatable, Sendable {
    public var totalWords: Int
    /// Today and the six days before it.
    public var wordsThisWeek: Int
    public var dictations: Int
    /// Words over audio minutes, counting only entries whose audio length is known.
    public var wordsPerMinute: Int?
    /// Consecutive days with a dictation, ending today, or yesterday while today has none yet.
    public var streakDays: Int

    public init(_ entries: [HistoryEntry], now: Date, calendar: Calendar) {
        totalWords = entries.reduce(0) { $0 + $1.words }
        dictations = entries.count
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        wordsThisWeek = entries.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.words }

        let timed = entries.filter { ($0.audioSeconds ?? 0) > 0 }
        let minutes = timed.reduce(0) { $0 + ($1.audioSeconds ?? 0) } / 60
        wordsPerMinute = timed.isEmpty ? nil : Int((Double(timed.reduce(0) { $0 + $1.words }) / minutes).rounded())

        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        streakDays = streak
    }
}

public struct HistoryDay: Equatable, Identifiable, Sendable {
    public var id: Date { startOfDay }
    public var startOfDay: Date
    public var entries: [HistoryEntry]
}

extension HistoryEntry {
    /// Newest day first, newest entry first within a day.
    public static func byDay(_ entries: [HistoryEntry], calendar: Calendar) -> [HistoryDay] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { HistoryDay(startOfDay: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.startOfDay > $1.startOfDay }
    }

    /// `existing` plus the incoming entries whose ids it lacks, oldest first. Merging the same entries again
    /// adds nothing.
    public static func merging(_ incoming: [HistoryEntry], into existing: [HistoryEntry]) -> (entries: [HistoryEntry], added: Int) {
        var known = Set(existing.map(\.id))
        let added = incoming.filter { known.insert($0.id).inserted }
        return ((existing + added).sorted { $0.date < $1.date }, added.count)
    }
}

extension HistoryEntry {
    /// A list caption for when it was said: "Today at 4:12 PM", "Yesterday at 9:05 AM", the weekday within the
    /// past week, else "Oct 12 at 8:15 AM", with the year once it is not this year.
    public static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let day = switch days {
        case 0: "Today"
        case 1: "Yesterday"
        case 2...6: date.formatted(style.weekday(.wide))
        default: calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style.month(.abbreviated).day()) : date.formatted(style.month(.abbreviated).day().year())
        }
        return "\(day) at \(time)"
    }
}
