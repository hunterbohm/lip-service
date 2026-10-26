import Foundation
import Testing
@testable import DictationCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15))!

private func entry(daysAgo: Int, hour: Int = 10, words: Int, seconds: Double? = nil) -> HistoryEntry {
    let day = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: now))!
    let text = Array(repeating: "word", count: words).joined(separator: " ")
    return HistoryEntry(date: day.addingTimeInterval(Double(hour) * 3600), text: text, audioSeconds: seconds, app: nil)
}

@Suite("History") struct HistoryTests {
    @Test func wordsAreRunsWithALetterOrDigit() {
        #expect(HistoryEntry.wordCount("Hello, world - it's 3pm.") == 4)
        #expect(HistoryEntry.wordCount("  ") == 0)
        #expect(HistoryEntry(text: "one two\nthree", audioSeconds: nil, app: nil).words == 3)
    }

    @Test func statsCountTotalsTheWeekAndWordsPerMinute() {
        let entries = [
            entry(daysAgo: 0, words: 10, seconds: 3),
            entry(daysAgo: 1, words: 4),
            entry(daysAgo: 2, words: 20, seconds: 9),
            entry(daysAgo: 6, hour: 0, words: 2, seconds: 0),
            entry(daysAgo: 7, hour: 23, words: 100),
        ]
        let stats = HistoryStats(entries, now: now, calendar: utc)
        #expect(stats.totalWords == 136)
        #expect(stats.wordsThisWeek == 36)
        #expect(stats.dictations == 5)
        #expect(stats.wordsPerMinute == 150)
    }

    @Test func wordsPerMinuteIsUnknownWithoutAudioLengths() {
        #expect(HistoryStats([entry(daysAgo: 0, words: 5)], now: now, calendar: utc).wordsPerMinute == nil)
        #expect(HistoryStats([], now: now, calendar: utc).wordsPerMinute == nil)
    }

    @Test func streakCountsBackFromTodayOrFromYesterdayWhileTodayIsEmpty() {
        let throughToday = [0, 0, 1, 2, 4].map { entry(daysAgo: $0, words: 1) }
        #expect(HistoryStats(throughToday, now: now, calendar: utc).streakDays == 3)
        let throughYesterday = [1, 2].map { entry(daysAgo: $0, words: 1) }
        #expect(HistoryStats(throughYesterday, now: now, calendar: utc).streakDays == 2)
        let lapsed = [2, 3].map { entry(daysAgo: $0, words: 1) }
        #expect(HistoryStats(lapsed, now: now, calendar: utc).streakDays == 0)
    }

    @Test func daysAreNewestFirstWithNewestEntriesFirst() {
        let morning = entry(daysAgo: 0, hour: 9, words: 1)
        let evening = entry(daysAgo: 0, hour: 14, words: 2)
        let yesterday = entry(daysAgo: 1, words: 3)
        let days = HistoryEntry.byDay([morning, yesterday, evening], calendar: utc)
        #expect(days.map(\.entries) == [[evening, morning], [yesterday]])
        #expect(days.first?.startOfDay == utc.startOfDay(for: now))
    }

    @Test func mergingAddsOnlyNewIdsOldestFirstAndAgainAddsNothing() {
        let older = HistoryEntry(id: "willow:1", date: now.addingTimeInterval(-7200), text: "old", audioSeconds: nil, app: nil)
        let own = HistoryEntry(id: "own", date: now, text: "mine", audioSeconds: nil, app: nil)
        let first = HistoryEntry.merging([older, older], into: [own])
        #expect(first.added == 1)
        #expect(first.entries.map(\.id) == ["willow:1", "own"])
        let again = HistoryEntry.merging([older], into: first.entries)
        #expect(again.added == 0)
        #expect(again.entries == first.entries)
    }

    @Test func entriesRoundTripThroughJSON() throws {
        let original = HistoryEntry(id: "willow:42", date: Date(timeIntervalSince1970: 1_793_000_000), text: "Ship it.",
                                    audioSeconds: 2.5, app: HistoryApp(name: "T3 Code", bundleID: "com.t3tools.t3code"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(HistoryEntry.self, from: encoder.encode(original)) == original)
    }
}

@Suite("Window captions") struct WindowCaptionTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    func when(_ said: String, now: String = "2026-10-25T21:00:00Z") -> String {
        HistoryEntry.when(date(said), now: date(now), calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func recentDictationsSayTodayYesterdayOrTheWeekday() {
        #expect(when("2026-10-25T21:12:00Z") == "Today at 4:12 PM")
        #expect(when("2026-10-24T14:05:00Z") == "Yesterday at 9:05 AM")
        #expect(when("2026-10-21T19:30:00Z") == "Wednesday at 2:30 PM")
    }

    @Test func olderDictationsSayTheDateAndTheYearOnlyWhenItDiffers() {
        #expect(when("2026-10-12T13:15:00Z") == "Oct 12 at 8:15 AM")
        #expect(when("2025-12-30T18:00:00Z") == "Dec 30, 2025 at 12:00 PM")
    }

    @Test func dayBoundariesFollowTheLocalCalendar() {
        #expect(when("2026-10-25T05:30:00Z") == "Today at 12:30 AM")
        #expect(when("2026-10-25T04:30:00Z") == "Yesterday at 11:30 PM")
    }

    @Test func dictationKeysReadAsASpokenList() {
        #expect(HotkeyChoice.phrase([.fn]) == "fn")
        #expect(HotkeyChoice.phrase([.fn, .rightControl]) == "fn or Right Control")
        #expect(HotkeyChoice.phrase([.fn, .rightControl, .rightOption]) == "fn, Right Control or Right Option")
        #expect(HotkeyChoice.phrase([]) == "")
    }

    @Test func loudnessRunsFromSilenceToFullAndClamps() {
        #expect(Loudness.fraction(rms: 0) == 0)
        #expect(Loudness.fraction(rms: 1) == 1)
        let quiet = Loudness.fraction(rms: 0.01), loud = Loudness.fraction(rms: 0.1)
        #expect(quiet > 0 && quiet < loud && loud < 1)
    }
}
