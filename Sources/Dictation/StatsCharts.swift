import Charts
import DictationCore
import SwiftUI

/// The one series color, and the ramp that is validated for dark mode on the canvas.
enum StatsColor {
    static let mark = Color(hex: 0x5A84F0)
    static let markStrong = Color(hex: 0x8DA9F6)
    static let muted = Color(hex: 0x3A3D44)
    static let typing = Color(hex: 0x4A4D55)
    static let emptyDot = Color(hex: 0x2F3136)
    static let ramp = [0x33509A, 0x3F64C6, 0x5A84F0, 0x8DA9F6, 0xC3D3FF].map { Color(hex: $0) }
    static let grid = Color.white.opacity(0.06)

    static func heat(_ words: Int, empty: Color) -> Color {
        switch words {
        case ..<1: empty
        case ..<100: ramp[0]
        case ..<300: ramp[1]
        case ..<700: ramp[2]
        case ..<1500: ramp[3]
        default: ramp[4]
        }
    }
}

struct TipText {
    var title: String
    var detail: String
}

private struct TipBubble: View {
    let text: TipText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text.title).fontWeight(.semibold)
            Text(text.detail)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x2F3136)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

private struct HoverTipLayer: View {
    @Binding var selection: Int?
    let resolve: (CGPoint) -> Int?
    let tip: (Int) -> TipText
    @State private var point = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            point = location
                            let next = resolve(location)
                            if next != selection { selection = next }
                        case .ended:
                            selection = nil
                        }
                    }
                if let index = selection {
                    let flip = point.x > geo.size.width * 0.6
                    TipBubble(text: tip(index))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: flip ? .topTrailing : .topLeading)
                        .padding(flip ? .trailing : .leading, flip ? geo.size.width - point.x + 12 : point.x + 14)
                        .padding(.top, min(point.y + 16, max(0, geo.size.height - 48)))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

extension View {
    /// Follows the pointer over any region. `resolve` names the thing under it, and `tip` says what to show.
    func hoverTip(selection: Binding<Int?>, resolve: @escaping (CGPoint) -> Int?, tip: @escaping (Int) -> TipText) -> some View {
        overlay { HoverTipLayer(selection: selection, resolve: resolve, tip: tip) }
    }

    /// The same over a chart whose x values are 0 to count - 1.
    func chartHover(selection: Binding<Int?>, count: Int, tip: @escaping (Int) -> TipText) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                Color.clear.hoverTip(selection: selection, resolve: { point in
                    guard let x = proxy.value(atX: point.x - origin.x, as: Double.self) else { return nil }
                    let index = Int(x.rounded())
                    return (0..<count).contains(index) ? index : nil
                }, tip: tip)
            }
        }
    }
}

enum StatsFormat {
    static func number(_ value: Int) -> String { value.formatted() }

    static func hour(_ hour: Int) -> String { UsageReport.hourName(hour) }

    static func monthAbbreviation(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated))
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day())
    }

    static func shortDay(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day())
    }

    static func plural(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count.formatted()) \(noun)s" }

    /// 8,580 reads 8.6k on an axis.
    static func axis(_ value: Double) -> String {
        guard value >= 1000 else { return Int(value).formatted() }
        var text = String(format: "%.2f", value / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "k"
    }

    /// The smallest 1, 2, 5 or 10 times a power of ten that holds the value.
    static func ceiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        return [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map { $0 * magnitude }.first { $0 >= value } ?? value
    }
}

/// A bar centered on a whole-number x, drawn as a span so its width does not depend on the axis type.
func span(_ position: Int, _ value: Int, half: Double) -> some ChartContent {
    let center = Double(position)
    let start = PlottableValue.value("Position", center - half)
    let end = PlottableValue.value("Position", center + half)
    let base = PlottableValue.value("Base", 0.0)
    let top = PlottableValue.value("Value", Double(value))
    return RectangleMark(xStart: start, xEnd: end, yStart: base, yEnd: top)
}

private struct AxisLabelStyle: ViewModifier {
    func body(content: Content) -> some View { content.font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize() }
}

extension View {
    fileprivate func axisLabel() -> some View { modifier(AxisLabelStyle()) }
}

struct HourChart: View {
    let hours: [Int]
    var highlighted: Set<Int>?
    var height: CGFloat = 140
    @State private var hover: Int?

    var body: some View {
        let peak = max(hours.max() ?? 1, 1)
        let total = max(hours.reduce(0, +), 1)
        Chart {
            ForEach(0..<24, id: \.self) { hour in
                span(hour, max(hours[hour], peak / 80), half: 0.37)
                    .cornerRadius(4)
                    .foregroundStyle(color(hour))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...peak)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel(anchor: .topLeading) { if let hour = value.as(Int.self) { Text(StatsFormat.hour(hour)).axisLabel() } }
            }
        }
        .chartYAxis {
            AxisMarks(values: [Double(peak) / 2, Double(peak)]) { _ in AxisGridLine().foregroundStyle(StatsColor.grid) }
        }
        .chartHover(selection: $hover, count: 24) { hour in
            TipText(title: StatsFormat.hour(hour),
                    detail: "\(StatsFormat.number(hours[hour])) words, \(Int((Double(hours[hour]) / Double(total) * 100).rounded()))% of all")
        }
        .frame(height: height)
    }

    private func color(_ hour: Int) -> Color {
        if hover == hour { return StatsColor.markStrong }
        return highlighted.map { $0.contains(hour) } ?? true ? StatsColor.mark : StatsColor.muted
    }
}

struct LengthChart: View {
    let buckets: [LengthBucket]
    @State private var hover: Int?

    var body: some View {
        let total = max(buckets.reduce(0) { $0 + $1.dictations }, 1)
        Chart {
            ForEach(buckets.indices, id: \.self) { index in
                span(index, buckets[index].dictations, half: 0.35)
                    .cornerRadius(4)
                    .foregroundStyle(hover == index ? StatsColor.markStrong : StatsColor.mark)
            }
        }
        .chartXScale(domain: -0.5...(Double(buckets.count) - 0.5))
        .chartXAxis {
            AxisMarks(values: Array(buckets.indices)) { value in
                AxisValueLabel { if let index = value.as(Int.self) { Text(buckets[index].label).axisLabel().font(.system(size: 10)) } }
            }
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.horizontal, 2) }
        .chartHover(selection: $hover, count: buckets.count) { index in
            let bucket = buckets[index]
            return TipText(title: "\(bucket.label) words",
                           detail: "\(StatsFormat.plural(bucket.dictations, "dictation")), \(Int((Double(bucket.dictations) / Double(total) * 100).rounded()))%")
        }
        .frame(height: 150)
    }
}

struct SpeedLine: View {
    let months: [UsageMonth]
    let calendar: Calendar
    @State private var hover: Int?

    var body: some View {
        let rates = months.map(\.wordsPerMinute)
        let low = Double((rates.min() ?? 0) - 12), high = Double((rates.max() ?? 0) + 18)
        Chart {
            ForEach(months.indices, id: \.self) { index in
                LineMark(x: .value("Month", index), y: .value("Words a minute", rates[index]))
                    .foregroundStyle(StatsColor.mark)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Month", index), y: .value("Words a minute", rates[index]))
                    .symbolSize(hover == index ? 110 : 64)
                    .foregroundStyle(hover == index ? StatsColor.markStrong : StatsColor.mark)
                    .annotation(position: .top, spacing: 4) {
                        if index == 0 || index == months.count - 1 || hover == index {
                            Text("\(rates[index])").font(.system(size: 11)).foregroundStyle(index == 0 ? Theme.secondary : Theme.text)
                        }
                    }
            }
        }
        .chartXScale(domain: -0.4...(Double(months.count) - 0.6))
        .chartYScale(domain: low...high)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.horizontal, 14) }
        .chartXAxis {
            AxisMarks(values: Array(months.indices)) { value in
                AxisValueLabel { if let index = value.as(Int.self) { Text(StatsFormat.monthAbbreviation(months[index].start, calendar: calendar)).axisLabel() } }
            }
        }
        .chartHover(selection: $hover, count: months.count) { index in
            TipText(title: StatsFormat.monthAbbreviation(months[index].start, calendar: calendar),
                    detail: "\(rates[index]) words a minute")
        }
        .frame(height: 118)
    }
}

struct WeeklyChart: View {
    let report: UsageReport
    @State private var hover: Int?

    var body: some View {
        let weeks = report.weeks
        let top = StatsFormat.ceiling(Double(weeks.map(\.words).max() ?? 1))
        let marker = report.switchDate.flatMap { date in weeks.lastIndex { $0.start <= date } }
        let monthTicks = weeks.indices.filter { index in
            let day = report.calendar.component(.day, from: weeks[index].start)
            let previous = index > 0 ? report.calendar.component(.month, from: weeks[index - 1].start) : -1
            return day <= 7 && report.calendar.component(.month, from: weeks[index].start) != previous
        }
        Chart {
            ForEach(weeks.indices, id: \.self) { index in
                AreaMark(x: .value("Week", index), y: .value("Words", weeks[index].words))
                    .foregroundStyle(LinearGradient(colors: [StatsColor.mark.opacity(0.40), StatsColor.mark.opacity(0.04)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Week", index), y: .value("Words", weeks[index].words))
                    .foregroundStyle(StatsColor.mark)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            if let marker {
                RuleMark(x: .value("Switched", marker))
                    .foregroundStyle(Theme.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .topLeading, alignment: marker < weeks.count / 4 ? .leading : .trailing, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("Switched to Lip Service").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
            }
            if let hover {
                RuleMark(x: .value("Week", hover)).foregroundStyle(Color.white.opacity(0.22))
                PointMark(x: .value("Week", hover), y: .value("Words", weeks[hover].words))
                    .symbolSize(80)
                    .foregroundStyle(StatsColor.markStrong)
            }
        }
        .chartXScale(domain: 0...max(weeks.count - 1, 1))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: monthTicks) { value in
                AxisValueLabel { if let index = value.as(Int.self) { Text(StatsFormat.monthAbbreviation(weeks[index].start, calendar: report.calendar)).axisLabel() } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine().foregroundStyle(StatsColor.grid)
                AxisValueLabel { if let number = value.as(Double.self) { Text(StatsFormat.axis(number)).axisLabel() } }
            }
        }
        .chartHover(selection: $hover, count: weeks.count) { index in
            let week = weeks[index]
            let speed = week.wordsPerMinute.map { ", \($0) words a minute" } ?? ""
            return TipText(title: "Week of \(StatsFormat.shortDay(week.start, calendar: report.calendar))",
                           detail: "\(StatsFormat.number(week.words)) words\(speed)")
        }
        .frame(height: 230)
    }
}

/// One dot per hour of the week, sized by words.
struct PunchCard: View {
    let grid: [[Int]]
    @State private var hover: Int?

    private let left: CGFloat = 40
    private let bottom: CGFloat = 22

    var body: some View {
        let peak = max(grid.joined().max() ?? 1, 1)
        GeometryReader { geo in
            let columnWidth = (geo.size.width - left) / 24
            let rowHeight = (geo.size.height - bottom) / 7
            let reach = min(columnWidth, rowHeight) / 2 - 1
            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { day in
                    Text(String(UsageReport.weekdayNames[day].prefix(3))).axisLabel()
                        .position(x: 12, y: rowHeight * (CGFloat(day) + 0.5))
                }
                ForEach(0..<168, id: \.self) { index in
                    let words = grid[index / 24][index % 24]
                    let radius = words > 0 ? max(1.8, (Double(words) / Double(peak)).squareRoot() * reach) : 1.2
                    Circle()
                        .fill(words > 0 ? (hover == index ? StatsColor.markStrong : StatsColor.mark) : StatsColor.emptyDot)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: left + columnWidth * (CGFloat(index % 24) + 0.5), y: rowHeight * (CGFloat(index / 24) + 0.5))
                }
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(StatsFormat.hour(hour)).axisLabel()
                        .position(x: left + columnWidth * CGFloat(hour) + 18, y: geo.size.height - 8)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .hoverTip(selection: $hover, resolve: { point in
                let column = Int((point.x - left) / columnWidth), row = Int(point.y / rowHeight)
                return (0..<24).contains(column) && (0..<7).contains(row) && point.x >= left ? row * 24 + column : nil
            }, tip: { index in
                TipText(title: "\(UsageReport.weekdayNames[index / 24])s, \(StatsFormat.hour(index % 24))",
                        detail: "\(StatsFormat.number(grid[index / 24][index % 24])) words")
            })
        }
        .frame(height: 210)
    }
}

struct Heatmap: View {
    let report: UsageReport
    let now: Date
    var empty: Color = Theme.tile
    @State private var hover: Int?

    private let cell: CGFloat = 13
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let fit = Int((geo.size.width - labelWidth + gap) / (cell + gap))
            let first = report.days.keys.min() ?? now
            let needed = (report.calendar.dateComponents([.day], from: first, to: now).day ?? 0) / 7 + 2
            let weeks = max(12, min(53, fit, needed))
            content(weeks: weeks)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 20 + 7 * cell + 6 * gap + 32)
    }

    private func content(weeks: Int) -> some View {
        let calendar = report.calendar
        let today = calendar.startOfDay(for: now)
        let sundayOffset = 6 - (calendar.component(.weekday, from: today) + 5) % 7
        let end = calendar.date(byAdding: .day, value: sundayOffset, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: end) ?? end
        func date(_ index: Int) -> Date { calendar.date(byAdding: .day, value: index, to: start) ?? start }
        var labels: [(column: Int, text: String)] = []
        var lastMonth = -1
        for column in 0..<weeks {
            let first = date(column * 7)
            let month = calendar.component(.month, from: first)
            if month != lastMonth && calendar.component(.day, from: first) <= 7 {
                labels.append((column, StatsFormat.monthAbbreviation(first, calendar: calendar)))
                lastMonth = month
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(labels, id: \.column) { label in
                    Text(label.text).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .offset(x: CGFloat(label.column) * (cell + gap))
                }
            }
            .frame(height: 14, alignment: .topLeading)
            .padding(.leading, labelWidth)
            .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(["Mon", "", "Wed", "", "Fri", "", "Sun"], id: \.self) { name in
                        Text(name).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).frame(height: cell)
                    }
                }
                .frame(width: 24, alignment: .leading)
                HStack(spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { column in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = column * 7 + row
                                let day = date(index)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(day > today ? Color.clear : StatsColor.heat(report.days[day]?.words ?? 0, empty: empty))
                                    .overlay {
                                        if hover == index { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white, lineWidth: 1.5) }
                                    }
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .hoverTip(selection: $hover, resolve: { point in
                    let column = Int(point.x / (cell + gap)), row = Int(point.y / (cell + gap))
                    guard (0..<weeks).contains(column), (0..<7).contains(row), point.x >= 0, point.y >= 0,
                          date(column * 7 + row) <= today else { return nil }
                    return column * 7 + row
                }, tip: { index in
                    let day = date(index)
                    guard let total = report.days[day] else {
                        return TipText(title: StatsFormat.day(day, calendar: calendar), detail: "No dictations")
                    }
                    return TipText(title: StatsFormat.day(day, calendar: calendar),
                                   detail: "\(StatsFormat.number(total.words)) words in \(StatsFormat.plural(total.dictations, "dictation"))")
                })
            }
            HStack(spacing: 4) {
                Text("Fewer words").padding(.trailing, 4)
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(empty).frame(width: 11, height: 11)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(StatsColor.ramp[step]).frame(width: 11, height: 11)
                }
                Text("More").padding(.leading, 4)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 10)
        }
    }
}

struct AppBars: View {
    let report: UsageReport
    var limit = 6
    var track: Color = Theme.tile
    @State private var hover: Int?

    var body: some View {
        let apps = Array(report.apps.prefix(limit))
        let peak = Double(apps.first?.words ?? 1)
        let total = max(report.wordsWithKnownApp, 1)
        VStack(spacing: 0) {
            ForEach(apps.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    Text(apps[index].name).lineLimit(1).frame(width: 128, alignment: .leading)
                    Track(fraction: Double(apps[index].words) / peak, fill: hover == index ? StatsColor.markStrong : StatsColor.mark, track: track)
                    Text("\(Int((Double(apps[index].words) / Double(total) * 100).rounded()))%")
                        .foregroundStyle(Theme.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 13.5))
                .frame(height: 30)
            }
        }
        .hoverTip(selection: $hover, resolve: { point in
            let row = Int(point.y / 30)
            return point.y >= 0 && row < apps.count ? row : nil
        }, tip: { index in
            TipText(title: apps[index].name,
                    detail: "\(StatsFormat.number(apps[index].words)) words in \(StatsFormat.plural(apps[index].dictations, "dictation"))")
        })
    }
}

struct Track: View {
    let fraction: Double
    let fill: Color
    let track: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                fill.frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// Typing against talking, in hours, for the time-saved card.
struct TimeBars: View {
    let typingHours: Double
    let talkingHours: Double
    let words: Int

    var body: some View {
        VStack(spacing: 0) {
            row("Typing", hours: typingHours, color: StatsColor.typing)
                .help("\(StatsFormat.number(words)) words at \(Int(UsageReport.typingWordsPerMinute)) words a minute")
            row("Talking", hours: talkingHours, color: StatsColor.mark)
                .help("Recorded speech time")
        }
    }

    private func row(_ name: String, hours: Double, color: Color) -> some View {
        let time = SavedTime(minutes: hours * 60)
        return HStack(spacing: 10) {
            Text(name).frame(width: 70, alignment: .leading)
            Track(fraction: typingHours > 0 ? hours / typingHours : 0, fill: color, track: Theme.raised, height: 10)
            Text("\(time.value) \(time.shortUnit)").foregroundStyle(Theme.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 13))
        .frame(height: 28)
    }
}
