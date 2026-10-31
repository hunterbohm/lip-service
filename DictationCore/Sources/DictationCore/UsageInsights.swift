import Foundation

/// One sentence about the history and the picture that backs it. A report offers only the insights its data supports.
public struct Insight: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case time, speed, when, whereWords, length, habit }

    public enum Figure: Equatable, Sendable {
        case timeBars(typingHours: Double, talkingHours: Double)
        case speedLine
        case hourBars(highlighted: Set<Int>)
        case appBars
        case lengthBars
        case heatmap
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var label: String
    /// Plain text with the key phrase between double asterisks.
    public var headline: String
    public var figure: Figure
}

extension Insight {
    static let minimumWords = 100
    static let minimumDictations = 10
    static let nightHours: Set<Int> = [21, 22, 23, 0, 1]
    static let nightShareToMention = 0.3
    static let aiShareToMention = 0.2
    static let shortDictationWords = 20

    /// Bundle IDs of AI chat apps, coding tools and terminals. A bundle ID matches itself and anything after a dot.
    static let aiAndCodingBundles: [String] = [
        "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode", "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.t3tools.t3code",
        "com.exafunction.windsurf", "com.jetbrains", "ai.x.grok",
    ]

    static func isAIOrCoding(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return aiAndCodingBundles.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// The registry, in the order the cards appear.
    private static let builders: [@Sendable (UsageReport) -> Insight?] = [
        Insight.time, Insight.speed, Insight.when, Insight.whereWords, Insight.length, Insight.habit,
    ]

    public static func all(for report: UsageReport) -> [Insight] { builders.compactMap { $0(report) } }

    private static func percent(_ part: Int, of whole: Int) -> Int { Int((Double(part) / Double(whole) * 100).rounded()) }

    static func time(_ report: UsageReport) -> Insight? {
        guard let minutes = report.minutesSaved, minutes >= 1 else { return nil }
        let saved = SavedTime(minutes: minutes)
        return Insight(kind: .time, label: "Time",
                       headline: "Talking instead of typing saved you about **\(saved.value) \(saved.longUnit)**.",
                       figure: .timeBars(typingHours: report.typingHours, talkingHours: report.talkingHours))
    }

    static func speed(_ report: UsageReport) -> Insight? {
        guard report.months.count >= 2, let rate = report.wordsPerMinute, let first = report.months.first,
              let last = report.months.last else { return nil }
        let times = String(format: "%.1f", Double(rate) / UsageReport.typingWordsPerMinute)
        let gain = Int((Double(last.wordsPerMinute) / Double(first.wordsPerMinute) * 100 - 100).rounded())
        let tail = gain >= 1 ? ", and **\(gain)%** faster than in \(report.monthName(first.start))." : "."
        return Insight(kind: .speed, label: "Speed",
                       headline: "You talk at **\(rate) words a minute**, \(times) times typing speed\(tail)", figure: .speedLine)
    }

    static func when(_ report: UsageReport) -> Insight? {
        let hours = report.wordsByHour
        let total = hours.reduce(0, +)
        guard total >= minimumWords else { return nil }
        let night = nightHours.reduce(0) { $0 + hours[$1] }
        if Double(night) / Double(total) >= nightShareToMention {
            return Insight(kind: .when, label: "When",
                           headline: "**\(percent(night, of: total))% of your words** come between 9 PM and 2 AM.",
                           figure: .hourBars(highlighted: nightHours))
        }
        let stretch = (0..<24).map { start in (0..<3).reduce(0) { $0 + hours[(start + $1) % 24] } }
        guard let best = stretch.max(), let start = stretch.firstIndex(of: best) else { return nil }
        let window = Set((0..<3).map { (start + $0) % 24 })
        return Insight(kind: .when, label: "When",
                       headline: "**\(percent(best, of: total))% of your words** come between \(UsageReport.hourName(start)) and \(UsageReport.hourName((start + 3) % 24)).",
                       figure: .hourBars(highlighted: window))
    }

    static func whereWords(_ report: UsageReport) -> Insight? {
        let known = report.wordsWithKnownApp
        guard known >= minimumWords / 2, let top = report.apps.first else { return nil }
        let ai = report.apps.filter { isAIOrCoding(bundleID: $0.bundleID) }.reduce(0) { $0 + $1.words }
        let headline = Double(ai) / Double(known) >= aiShareToMention
            ? "**\(percent(ai, of: known))% of your words** go to AI and coding tools."
            : "**\(percent(top.words, of: known))% of your words** go to \(top.name)."
        return Insight(kind: .whereWords, label: "Where", headline: headline, figure: .appBars)
    }

    static func length(_ report: UsageReport) -> Insight? {
        guard report.dictations >= minimumDictations else { return nil }
        let short = report.lengthBuckets.prefix(3).reduce(0) { $0 + $1.dictations }
        let share = percent(short, of: report.dictations)
        let lead = share >= 50 ? "Most dictations are quick: **\(share)% are \(shortDictationWords) words or fewer**."
            : "**\(share)% of your dictations are \(shortDictationWords) words or fewer**."
        return Insight(kind: .length, label: "Length", headline: "\(lead) The longest ran \(report.longestDictation) words.",
                       figure: .lengthBars)
    }

    static func habit(_ report: UsageReport) -> Insight? {
        guard report.longestStreak >= 2 else { return nil }
        let longest = report.longestStreak, current = report.currentStreak
        let headline = current == longest ? "Your longest streak is **\(longest) days**, and it is still going."
            : current > 0 ? "Your longest streak was **\(longest) days**. You're on day \(current) of a new one."
            : "Your longest streak was **\(longest) days**."
        return Insight(kind: .habit, label: "Habit", headline: headline, figure: .heatmap)
    }
}

extension UsageReport {
    public var insights: [Insight] { Insight.all(for: self) }
}
