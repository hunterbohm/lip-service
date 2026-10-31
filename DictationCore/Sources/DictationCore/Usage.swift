import Foundation

public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all

    public var id: Self { self }
    public var title: String { rawValue.capitalized }
}

public struct DayTotal: Equatable, Sendable {
    public var words: Int
    public var dictations: Int
}

public struct BestDay: Equatable, Sendable {
    public var date: Date
    public var words: Int
}

public struct UsageApp: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var bundleID: String?
    public var words: Int
    public var dictations: Int
}

public struct UsageWeek: Equatable, Identifiable, Sendable {
    public var id: Date { start }
    /// The Monday that starts the week.
    public var start: Date
    public var words: Int
    public var wordsPerMinute: Int?
}

public struct UsageMonth: Equatable, Identifiable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var wordsPerMinute: Int
}

public struct LengthBucket: Equatable, Identifiable, Sendable {
    public var id: String { label }
    public var label: String
    public var dictations: Int
}

/// Counts from the history, shaped for the Stats page. It reads only counts, times and app names. The text of a
/// dictation never enters it.
public struct UsageReport: Equatable, Sendable {
    /// The speed Wispr Flow and VoiceInk also assume when they work out time saved.
    public static let typingWordsPerMinute = 40.0
    /// A month's speed needs this much measured speech to count, so a single short dictation draws no point.
    static let monthMinimumSeconds = 60.0
    static let lengthBounds: [(label: String, upTo: Int)] = [
        ("1-5", 5), ("6-10", 10), ("11-20", 20), ("21-40", 40), ("41-80", 80), ("81-160", 160), ("161+", .max),
    ]

    public let period: UsagePeriod
    public let calendar: Calendar

    public let words: Int
    public let dictations: Int
    public let talkingSeconds: Double
    public let wordsPerMinute: Int?
    /// Nil while no dictation anywhere has a measured length, because nothing then says how long talking took.
    public let minutesSaved: Double?
    public let activeDays: Int
    public let longestDictation: Int
    public let firstDate: Date?

    public let currentStreak: Int
    public let longestStreak: Int
    public let bestDay: BestDay?
    public let days: [Date: DayTotal]
    public let weeks: [UsageWeek]
    public let months: [UsageMonth]
    /// The first dictation made in Lip Service itself, when imported Willow dictations came before it.
    public let switchDate: Date?

    public let wordsByHour: [Int]
    /// Seven weekdays, Monday first, by 24 hours.
    public let wordsByWeekdayHour: [[Int]]
    /// Most words first. Only dictations that know their app.
    public let apps: [UsageApp]
    public let wordsWithKnownApp: Int
    public let lengthBuckets: [LengthBucket]

    public init(entries: [HistoryEntry], period: UsagePeriod, now: Date, calendar: Calendar) {
        self.period = period
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        let start = Self.start(of: period, today: today, calendar: calendar)
        let inPeriod = entries.filter { $0.date >= start }

        func rate(_ entries: [HistoryEntry]) -> (wordsPerMinute: Double, seconds: Double, words: Int)? {
            let timed = entries.filter { ($0.audioSeconds ?? 0) > 0 }
            let seconds = timed.reduce(0) { $0 + ($1.audioSeconds ?? 0) }
            guard seconds > 0 else { return nil }
            let words = timed.reduce(0) { $0 + $1.words }
            return (Double(words) / (seconds / 60), seconds, words)
        }

        words = inPeriod.reduce(0) { $0 + $1.words }
        dictations = inPeriod.count
        let measured = rate(inPeriod)
        let fallback = measured?.wordsPerMinute ?? rate(entries)?.wordsPerMinute
        wordsPerMinute = measured.map { Int($0.wordsPerMinute.rounded()) }
        let untimedWords = inPeriod.filter { ($0.audioSeconds ?? 0) <= 0 }.reduce(0) { $0 + $1.words }
        talkingSeconds = (measured?.seconds ?? 0) + (fallback.map { Double(untimedWords) / $0 * 60 } ?? 0)
        minutesSaved = fallback == nil ? nil : max(0, Double(words) / Self.typingWordsPerMinute - talkingSeconds / 60)
        longestDictation = inPeriod.map(\.words).max() ?? 0
        firstDate = inPeriod.map(\.date).min()

        var perDay: [Date: DayTotal] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            perDay[day, default: DayTotal(words: 0, dictations: 0)].words += entry.words
            perDay[day, default: DayTotal(words: 0, dictations: 0)].dictations += 1
        }
        days = perDay
        activeDays = perDay.keys.count { $0 >= start }
        let dayList = perDay.keys.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for day in dayList {
            run = previous.flatMap({ calendar.date(byAdding: .day, value: 1, to: $0) }) == day ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        longestStreak = longest
        var cursor = perDay[today] != nil ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var current = 0
        while perDay[cursor] != nil {
            current += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = before
        }
        currentStreak = current
        bestDay = dayList.map { BestDay(date: $0, words: perDay[$0]?.words ?? 0) }
            .reduce(nil as BestDay?) { best, day in day.words > (best?.words ?? 0) ? day : best }

        weeks = Self.weeks(entries, today: today, calendar: calendar)
        months = Dictionary(grouping: entries) { entry in
            calendar.dateInterval(of: .month, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
        }
        .compactMap { month, entries in
            rate(entries).flatMap { $0.seconds >= Self.monthMinimumSeconds ? UsageMonth(start: month, wordsPerMinute: Int($0.wordsPerMinute.rounded())) : nil }
        }
        .sorted { $0.start < $1.start }

        let ordered = entries.sorted { $0.date < $1.date }
        let firstOwn = ordered.firstIndex { !$0.id.hasPrefix(Self.willowPrefix) }
        switchDate = firstOwn.flatMap { $0 > 0 ? ordered[$0].date : nil }

        var byHour = Array(repeating: 0, count: 24)
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for entry in inPeriod {
            let hour = calendar.component(.hour, from: entry.date)
            let weekday = (calendar.component(.weekday, from: entry.date) + 5) % 7
            byHour[hour] += entry.words
            grid[weekday][hour] += entry.words
        }
        wordsByHour = byHour
        wordsByWeekdayHour = grid

        var perApp: [String: UsageApp] = [:]
        for entry in inPeriod {
            guard let app = entry.app else { continue }
            var total = perApp[app.name] ?? UsageApp(name: app.name, bundleID: app.bundleID, words: 0, dictations: 0)
            total.words += entry.words
            total.dictations += 1
            total.bundleID = total.bundleID ?? app.bundleID
            perApp[app.name] = total
        }
        apps = perApp.values.sorted { ($0.words, $1.name) > ($1.words, $0.name) }
        wordsWithKnownApp = apps.reduce(0) { $0 + $1.words }

        lengthBuckets = Self.lengthBounds.enumerated().map { index, bucket in
            let lower = index == 0 ? 1 : Self.lengthBounds[index - 1].upTo + 1
            return LengthBucket(label: bucket.label, dictations: inPeriod.count { $0.words >= lower && $0.words <= bucket.upTo })
        }
    }

    static let willowPrefix = "willow:"

    private static func start(of period: UsagePeriod, today: Date, calendar: Calendar) -> Date {
        switch period {
        case .week: calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .year: calendar.dateInterval(of: .year, for: today)?.start ?? today
        case .all: .distantPast
        }
    }

    /// Every Monday-first week from the first dictation to this one, empty weeks included so a line chart keeps its scale.
    private static func weeks(_ entries: [HistoryEntry], today: Date, calendar: Calendar) -> [UsageWeek] {
        func monday(_ date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day) ?? day
        }
        guard let first = entries.map(\.date).min() else { return [] }
        let grouped = Dictionary(grouping: entries) { monday($0.date) }
        var result: [UsageWeek] = []
        var week = monday(first)
        let last = monday(today)
        while week <= last {
            let inWeek = grouped[week] ?? []
            let timed = inWeek.filter { ($0.audioSeconds ?? 0) > 0 }
            let seconds = timed.reduce(0) { $0 + ($1.audioSeconds ?? 0) }
            result.append(UsageWeek(start: week, words: inWeek.reduce(0) { $0 + $1.words },
                                    wordsPerMinute: seconds > 0 ? Int((Double(timed.reduce(0) { $0 + $1.words }) / (seconds / 60)).rounded()) : nil))
            guard let next = calendar.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return result
    }
}

extension UsageReport {
    public var typingHours: Double { Double(words) / Self.typingWordsPerMinute / 60 }
    public var talkingHours: Double { talkingSeconds / 3600 }
    public var hasEntries: Bool { dictations > 0 }

    /// "Apr 2 to Oct 30, 2026", from the first dictation in the period to today.
    public func rangeCaption(now: Date) -> String? {
        guard let firstDate else { return nil }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let day = calendar.startOfDay(for: firstDate), end = calendar.startOfDay(for: now)
        if day >= end { return end.formatted(style.month(.abbreviated).day().year()) }
        let sameYear = calendar.isDate(day, equalTo: end, toGranularity: .year)
        let from = sameYear ? day.formatted(style.month(.abbreviated).day()) : day.formatted(style.month(.abbreviated).day().year())
        return "\(from) to \(end.formatted(style.month(.abbreviated).day().year()))"
    }

    public func monthName(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.wide))
    }

    /// "12 AM", "9 AM", "12 PM", "9 PM".
    public static func hourName(_ hour: Int) -> String {
        switch hour {
        case 0: "12 AM"
        case 1..<12: "\(hour) AM"
        case 12: "12 PM"
        default: "\(hour - 12) PM"
        }
    }

    public static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
}

/// Time saved, ready to print: minutes below an hour and a half, hours after.
public struct SavedTime: Equatable, Sendable {
    public var value: String
    public var isHours: Bool

    public init(minutes: Double) {
        isHours = minutes >= 90
        value = isHours ? String(format: minutes >= 600 ? "%.0f" : "%.1f", minutes / 60) : String(format: "%.0f", minutes)
    }

    /// "h" or "min".
    public var shortUnit: String { isHours ? "h" : "min" }
    /// "hours" or "minutes", singular when the value is 1.
    public var longUnit: String { isHours ? "hours" : value == "1" ? "minute" : "minutes" }
}
