import Foundation
import Testing
@testable import DictationCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// A Sunday afternoon.
private let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15))!

private func entry(daysAgo: Int = 0, hour: Int = 10, words: Int, seconds: Double? = nil, app: HistoryApp? = nil,
                   id: String = UUID().uuidString) -> HistoryEntry {
    let day = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: now))!
    let text = Array(repeating: "word", count: words).joined(separator: " ")
    return HistoryEntry(id: id, date: day.addingTimeInterval(Double(hour) * 3600), text: text, audioSeconds: seconds, app: app)
}

private func report(_ entries: [HistoryEntry], _ period: UsagePeriod = .all) -> UsageReport {
    UsageReport(entries: entries, period: period, now: now, calendar: utc)
}

private func app(_ name: String, _ bundleID: String? = nil) -> HistoryApp { HistoryApp(name: name, bundleID: bundleID) }

@Suite("Usage") struct UsageTests {
    @Test func periodsCoverTheWeekThirtyDaysTheYearAndEverything() {
        let entries = [0, 6, 7, 29, 30, 297, 298, 700].map { entry(daysAgo: $0, words: 10) }
        #expect(report(entries, .week).dictations == 2)
        #expect(report(entries, .month).dictations == 4)
        #expect(report(entries, .year).dictations == 6)
        #expect(report(entries, .all).dictations == 8)
        #expect(report(entries, .week).words == 20)
    }

    @Test func minutesSavedEstimatesUntimedDictationsAtTheMeasuredSpeed() {
        let entries = [entry(words: 60, seconds: 30), entry(daysAgo: 1, words: 120)]
        let usage = report(entries)
        #expect(usage.wordsPerMinute == 120)
        #expect(abs(usage.talkingSeconds - 90) < 0.001)
        #expect(abs((usage.minutesSaved ?? -1) - 3) < 0.001)
    }

    @Test func minutesSavedNeverGoesBelowZeroAndIsUnknownWithoutAnyTiming() {
        let slow = report([entry(words: 10, seconds: 60)])
        #expect(slow.minutesSaved == 0)
        #expect(report([entry(words: 500)]).minutesSaved == nil)
        #expect(report([entry(words: 500)]).wordsPerMinute == nil)
    }

    @Test func aPeriodWithoutTimingBorrowsTheSpeedMeasuredBefore() {
        let entries = [entry(daysAgo: 100, words: 100, seconds: 50), entry(daysAgo: 1, words: 80)]
        let usage = report(entries, .week)
        #expect(usage.wordsPerMinute == nil)
        #expect(abs(usage.talkingSeconds - 40) < 0.001)
        #expect(abs((usage.minutesSaved ?? -1) - (2 - 40.0 / 60)) < 0.001)
    }

    @Test func streaksCountTheCurrentRunAndTheLongestEver() {
        let entries = [0, 1, 2, 5, 6, 7, 8, 9].map { entry(daysAgo: $0, words: 1) } + [entry(words: 1)]
        let usage = report(entries)
        #expect(usage.currentStreak == 3)
        #expect(usage.longestStreak == 5)
        #expect(report([2, 3, 4].map { entry(daysAgo: $0, words: 1) }).currentStreak == 0)
        #expect(report([1, 2].map { entry(daysAgo: $0, words: 1) }).currentStreak == 2)
    }

    @Test func theBestDayIsTheOneWithTheMostWords() {
        let usage = report([entry(daysAgo: 3, words: 40), entry(daysAgo: 3, words: 15), entry(daysAgo: 1, words: 50)])
        #expect(usage.bestDay?.words == 55)
        #expect(usage.bestDay?.date == utc.startOfDay(for: utc.date(byAdding: .day, value: -3, to: now)!))
        #expect(usage.days.count == 2)
        #expect(report([]).bestDay == nil)
    }

    @Test func theWeekdayGridStartsOnMondayAndCountsByHour() {
        let monday = entry(daysAgo: 6, hour: 22, words: 5)
        let sunday = entry(daysAgo: 0, hour: 3, words: 7)
        let usage = report([monday, sunday, entry(daysAgo: 6, hour: 22, words: 2)])
        #expect(usage.wordsByWeekdayHour.count == 7)
        #expect(usage.wordsByWeekdayHour[0][22] == 7)
        #expect(usage.wordsByWeekdayHour[6][3] == 7)
        #expect(usage.wordsByWeekdayHour[0][3] == 0)
        #expect(usage.wordsByHour[22] == 7)
    }

    @Test func appShareCountsOnlyDictationsWithAKnownApp() {
        let usage = report([entry(words: 30, app: app("Ghostty", "com.mitchellh.ghostty")), entry(words: 10, app: app("Ghostty")),
                            entry(words: 20, app: app("Notes", "com.apple.Notes")), entry(words: 500)])
        #expect(usage.apps.map(\.name) == ["Ghostty", "Notes"])
        #expect(usage.apps.first?.words == 40)
        #expect(usage.apps.first?.dictations == 2)
        #expect(usage.apps.first?.bundleID == "com.mitchellh.ghostty")
        #expect(usage.wordsWithKnownApp == 60)
        #expect(usage.words == 560)
    }

    @Test func switchDateIsTheFirstOwnDictationAfterImportedOnes() {
        let imported = [entry(daysAgo: 20, words: 3, id: "willow:1"), entry(daysAgo: 10, words: 3, id: "willow:2")]
        let own = entry(daysAgo: 4, words: 3, id: "own")
        #expect(report(imported + [own, entry(daysAgo: 1, words: 3, id: "own-2")]).switchDate == own.date)
        #expect(report([own]).switchDate == nil)
        #expect(report(imported).switchDate == nil)
    }

    @Test func lengthBucketsSplitAtTheEdges() {
        let sizes = [1, 5, 6, 10, 11, 20, 21, 40, 41, 80, 81, 160, 161, 400]
        let usage = report(sizes.map { entry(words: $0) })
        #expect(usage.lengthBuckets.map(\.label) == ["1-5", "6-10", "11-20", "21-40", "41-80", "81-160", "161+"])
        #expect(usage.lengthBuckets.map(\.dictations) == Array(repeating: 2, count: 7))
        #expect(usage.longestDictation == 400)
    }

    @Test func weeksRunFromMondayToMondayWithEmptyWeeksKept() {
        let usage = report([entry(daysAgo: 27, words: 10, seconds: 4), entry(daysAgo: 0, words: 5)])
        #expect(usage.weeks.count == 4)
        #expect(usage.weeks.map(\.words) == [10, 0, 0, 5])
        #expect(usage.weeks.first?.wordsPerMinute == 150)
        #expect(usage.weeks.last?.wordsPerMinute == nil)
        #expect(utc.component(.weekday, from: usage.weeks[0].start) == 2)
    }

    @Test func monthsNeedAMinuteOfMeasuredSpeech() {
        let entries = [entry(daysAgo: 70, words: 100, seconds: 60), entry(daysAgo: 40, words: 5, seconds: 2),
                       entry(daysAgo: 1, words: 120, seconds: 60)]
        #expect(report(entries).months.map(\.wordsPerMinute) == [100, 120])
    }

    @Test func rangeCaptionNamesTheYearOnceAndTwiceWhenItSpansTwo() {
        #expect(report([entry(daysAgo: 206, words: 1)]).rangeCaption(now: now) == "Apr 2 to Oct 25, 2026")
        #expect(report([entry(daysAgo: 400, words: 1)]).rangeCaption(now: now) == "Sep 20, 2025 to Oct 25, 2026")
        #expect(report([]).rangeCaption(now: now) == nil)
    }

    @Test func savedTimeSwitchesToHoursPastNinetyMinutes() {
        #expect(SavedTime(minutes: 89.6).shortUnit == "min")
        #expect(SavedTime(minutes: 45).value == "45")
        #expect(SavedTime(minutes: 1).longUnit == "minute")
        #expect(SavedTime(minutes: 90).value == "1.5")
        #expect(SavedTime(minutes: 90).longUnit == "hours")
        #expect(SavedTime(minutes: 1200).value == "20")
    }
}

@Suite("Usage insights") struct UsageInsightTests {
    private func kinds(_ entries: [HistoryEntry]) -> [Insight.Kind] { report(entries).insights.map(\.kind) }

    @Test func aNightOwlSeesTheShareBetweenNineAndTwo() {
        let entries = [entry(hour: 23, words: 60, seconds: 20), entry(hour: 1, words: 40, seconds: 15), entry(hour: 9, words: 50, seconds: 20)]
        let when = report(entries).insights.first { $0.kind == .when }
        #expect(when?.headline == "**67% of your words** come between 9 PM and 2 AM.")
        #expect(when?.figure == .hourBars(highlighted: [21, 22, 23, 0, 1]))
    }

    @Test func otherwiseTheBusiestThreeHoursAreNamed() {
        let entries = [entry(hour: 9, words: 40), entry(hour: 10, words: 30), entry(hour: 11, words: 20), entry(hour: 15, words: 10)]
        let when = report(entries).insights.first { $0.kind == .when }
        #expect(when?.headline == "**90% of your words** come between 9 AM and 12 PM.")
    }

    @Test func aiShareUsesTheBundleTableAndFallsBackToTheTopApp() {
        let ai = [entry(words: 70, app: app("Ghostty", "com.mitchellh.ghostty")), entry(words: 30, app: app("T3 Code (Nightly)", "com.t3tools.t3code.nightly"))]
        let mixed = ai + [entry(words: 100, app: app("Notes", "com.apple.Notes"))]
        #expect(report(mixed).insights.first { $0.kind == .whereWords }?.headline == "**50% of your words** go to AI and coding tools.")
        let none = [entry(words: 80, app: app("Notes", "com.apple.Notes")), entry(words: 20, app: app("Mail", "com.apple.mail"))]
        #expect(report(none).insights.first { $0.kind == .whereWords }?.headline == "**80% of your words** go to Notes.")
    }

    @Test func speedNeedsTwoMonthsAndNamesTheFirst() {
        let one = [entry(daysAgo: 1, words: 120, seconds: 60), entry(daysAgo: 2, words: 120, seconds: 60)]
        #expect(!kinds(one).contains(.speed))
        let two = [entry(daysAgo: 70, words: 100, seconds: 60), entry(daysAgo: 1, words: 140, seconds: 60)]
        let speed = report(two).insights.first { $0.kind == .speed }
        #expect(speed?.headline == "You talk at **120 words a minute**, 3.0 times typing speed, and **40%** faster than in August.")
    }

    @Test func shortDictationsNeedTenDictationsAndReportTheLongest() {
        let few = (0..<9).map { _ in entry(words: 5) }
        #expect(!kinds(few).contains(.length))
        let many = (0..<9).map { _ in entry(words: 5) } + [entry(words: 90), entry(words: 30), entry(words: 25), entry(words: 15)]
        let length = report(many).insights.first { $0.kind == .length }
        #expect(length?.headline == "Most dictations are quick: **77% are 20 words or fewer**. The longest ran 90 words.")
    }

    @Test func timeIsLeftOutWithoutAnyMeasuredSpeechAndEverythingIsLeftOutWithoutHistory() {
        #expect(!kinds([entry(words: 500)]).contains(.time))
        #expect(kinds([entry(words: 120, seconds: 30)]).contains(.time))
        #expect(report([]).insights.isEmpty)
    }

    @Test func habitReadsTheStreakAgainstTheLongest() {
        let running = [0, 1, 2, 3].map { entry(daysAgo: $0, words: 1) }
        #expect(report(running).insights.first { $0.kind == .habit }?.headline == "Your longest streak is **4 days**, and it is still going.")
        let past = [10, 11, 12, 13, 0].map { entry(daysAgo: $0, words: 1) }
        #expect(report(past).insights.first { $0.kind == .habit }?.headline == "Your longest streak was **4 days**. You're on day 1 of a new one.")
        #expect(!kinds([entry(words: 1)]).contains(.habit))
    }
}
