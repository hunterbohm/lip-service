import DictationCore
import SwiftUI

enum StatsView: String, CaseIterable, Identifiable {
    case overview, insights, charts

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct StatsPage: View {
    let services: WindowServices
    @Bindable var state: WindowState

    var body: some View {
        let entries = services.history.entries
        let now = Date.now
        let report = UsageReport(entries: entries, period: state.statsPeriod, now: now, calendar: .current)
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        StatsEmpty(services: services, state: state)
                    } else {
                        StatsHeader(state: state)
                        switch state.statsView {
                        case .overview: Overview(report: report, now: now)
                        case .insights: InsightsTab(report: report, now: now)
                        case .charts: ChartsTab(report: report, now: now)
                        }
                        Text("Counted on this Mac from your history.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.top, 8)
                    }
                }
                .page()
            }
            if state.sharingStats {
                ShareSheet(entries: entries, now: now) { state.sharingStats = false }
            }
        }
    }
}

private struct StatsHeader: View {
    @Bindable var state: WindowState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                title
                Spacer(minLength: 12)
                views
                periods
                share
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    title
                    Spacer()
                    share
                }
                HStack(spacing: 16) {
                    views
                    Spacer(minLength: 12)
                    periods
                }
            }
        }
        .padding(.bottom, 26)
    }

    private var title: some View { Text("Stats").font(.system(size: 22, weight: .semibold)) }

    private var views: some View {
        Chips(items: StatsView.allCases, title: \.title, selection: $state.statsView)
    }

    private var periods: some View {
        Chips(items: UsagePeriod.allCases, title: \.title, selection: $state.statsPeriod)
    }

    private var share: some View {
        Button("Share") { state.sharingStats = true }.buttonStyle(DarkButtonStyle())
    }
}

/// Joined choices in a row, like the Tesla screen's, with the chosen one in gray.
struct Chips<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: KeyPath<Item, String>
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Chip(title: item[keyPath: title], chosen: selection == item) { selection = item }
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Chip: View {
    let title: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chosen ? Color.white : Theme.text.opacity(0.92))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(chosen ? Theme.chosen : hovering ? Theme.raised : Theme.tile)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StatsEmpty: View {
    let services: WindowServices
    @Bindable var state: WindowState

    var body: some View {
        let settings = services.preferences.current.settings
        PageTitle("Stats")
        VStack(spacing: 14) {
            Image(systemName: "chart.bar").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
            if settings.keepHistory {
                Text("Stats appear after your first dictation. Hold \(Shortcut.phrase(settings.hotkeys)) and start talking.")
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Stats are counted from your history. Turn on Keep history to see them.").foregroundStyle(Theme.secondary)
                Button("Open History") { state.page = .history }.buttonStyle(DarkButtonStyle(kind: .prominent))
            }
        }
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

private struct Block<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, detail: detail)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: size)).monospacedDigit()
            Text(label).font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
        }
    }
}

private extension UsageReport {
    var daysText: String { currentStreak == 1 ? "1 day" : "\(currentStreak) days" }
    var speedText: String { wordsPerMinute.map { $0.formatted() } ?? "–" }
    var peakHour: Int? {
        guard let peak = wordsByHour.max(), peak > 0 else { return nil }
        return wordsByHour.firstIndex(of: peak)
    }
    /// Enough dictations that a chart of them shows something.
    var isChartable: Bool { dictations >= 5 }
}

private struct NothingYet: View {
    var body: some View {
        Text("Nothing in this period yet.")
            .font(.system(size: 15))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

private struct Overview: View {
    let report: UsageReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero.padding(.bottom, 34)
            if !report.hasEntries { NothingYet() }
            if report.days.count >= 2 {
                Block(title: "Every day you talked", detail: heatDetail) { Heatmap(report: report, now: now) }
                    .padding(.bottom, 34)
            }
            if report.isChartable {
                HStack(alignment: .top, spacing: 30) {
                    if !report.apps.isEmpty {
                        Block(title: "Where you talk", detail: "Share of words, where the app is known") { AppBars(report: report) }
                    }
                    Block(title: "When you talk", detail: report.peakHour.map { "Most at \(UsageReport.hourName($0))" }) {
                        HourChart(hours: report.wordsByHour)
                    }
                }
                .padding(.bottom, 34)
            }
        }
    }

    private var hero: some View {
        let saved = report.minutesSaved.map { SavedTime(minutes: $0) }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 40) { big(saved); stats }
            VStack(alignment: .leading, spacing: 26) { big(saved); stats }
        }
    }

    private func big(_ saved: SavedTime?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(saved?.value ?? "–").font(.system(size: 76, weight: .light)).monospacedDigit()
                if let saved { Text(saved.shortUnit).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondary) }
            }
            Text("Time saved against typing at \(Int(UsageReport.typingWordsPerMinute)) words a minute")
                .font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: 230, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stats: some View {
        HStack(alignment: .bottom, spacing: 28) {
            Stat(value: report.words.formatted(), label: "Words")
            Stat(value: report.speedText, label: "Words a minute")
            Stat(value: report.dictations.formatted(), label: "Dictations")
            Stat(value: report.daysText, label: "Streak")
        }
        .padding(.bottom, 2)
    }

    private var heatDetail: String {
        var parts: [String] = []
        if report.longestStreak > 0 { parts.append("Longest streak \(report.longestStreak) days.") }
        if let best = report.bestDay {
            parts.append("Biggest day \(StatsFormat.day(best.date, calendar: report.calendar)), \(best.words.formatted()) words.")
        }
        return parts.joined(separator: " ")
    }
}

private struct InsightsTab: View {
    let report: UsageReport
    let now: Date

    var body: some View {
        let insights = report.insights
        if insights.isEmpty {
            Text("Insights appear as you dictate more.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
        } else {
            VStack(spacing: 14) {
                ForEach(Self.rows(insights), id: \.first?.kind) { row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(row) { insight in InsightCard(insight: insight, report: report, now: now) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Two narrow cards to a row. A wide card, or a lone narrow one, takes a row to itself.
    private static func rows(_ insights: [Insight]) -> [[Insight]] {
        var rows: [[Insight]] = []
        var pending: Insight?
        for insight in insights {
            if insight.kind == .when || insight.kind == .habit {
                if let waiting = pending { rows.append([waiting]) }
                pending = nil
                rows.append([insight])
            } else if let waiting = pending {
                rows.append([waiting, insight])
                pending = nil
            } else {
                pending = insight
            }
        }
        if let pending { rows.append([pending]) }
        return rows
    }
}

private struct InsightCard: View {
    let insight: Insight
    let report: UsageReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(insight.label).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.bottom, 10)
            Text(Self.headline(insight.headline))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            Spacer(minLength: 0)
            figure
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
    }

    @ViewBuilder private var figure: some View {
        switch insight.figure {
        case .timeBars(let typing, let talking): TimeBars(typingHours: typing, talkingHours: talking, words: report.words)
        case .speedLine: SpeedLine(months: Array(report.months.suffix(12)), calendar: report.calendar)
        case .hourBars(let highlighted): HourChart(hours: report.wordsByHour, highlighted: highlighted)
        case .appBars: AppBars(report: report, limit: 5, track: Theme.raised)
        case .lengthBars: LengthChart(buckets: report.lengthBuckets)
        case .heatmap: Heatmap(report: report, now: now, empty: Theme.raised)
        }
    }

    /// The key phrase sits between double asterisks.
    private static func headline(_ markup: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in markup.components(separatedBy: "**").enumerated() {
            var piece = AttributedString(part)
            piece.font = .system(size: 22, weight: index % 2 == 1 ? .medium : .regular)
            result += piece
        }
        return result
    }
}

private struct ChartsTab: View {
    let report: UsageReport
    let now: Date

    var body: some View {
        let saved = report.minutesSaved.map { SavedTime(minutes: $0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 40) {
                Stat(value: report.words.formatted(), label: "Words", size: 34)
                Stat(value: saved.map { "\($0.value) \($0.shortUnit)" } ?? "–", label: "Time saved", size: 34)
                Stat(value: report.speedText, label: "Words a minute", size: 34)
                Stat(value: report.activeDays.formatted(), label: "Days you talked", size: 34)
            }
            .padding(.bottom, 30)
            if !report.hasEntries { NothingYet() }
            if report.weeks.count >= 3 {
                Block(title: "Words a week", detail: "Hover a week for its speed") { WeeklyChart(report: report) }.padding(.bottom, 34)
            }
            if report.isChartable {
                Block(title: "When you talk", detail: "Each dot is one hour of the week. Bigger means more words.") {
                    PunchCard(grid: report.wordsByWeekdayHour)
                }
                .padding(.bottom, 34)
                HStack(alignment: .top, spacing: 30) {
                    if !report.apps.isEmpty {
                        Block(title: "Where you talk", detail: "Share of words, where the app is known") { AppBars(report: report) }
                    }
                    Block(title: "How long you talk", detail: "Dictations by number of words") { LengthChart(buckets: report.lengthBuckets) }
                }
                .padding(.bottom, 34)
            }
        }
    }
}
