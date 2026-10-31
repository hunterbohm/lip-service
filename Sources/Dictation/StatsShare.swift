import AppKit
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// The picture that gets shared. It holds totals and nothing else: no dictation text and no app names.
struct ShareCard: View {
    let report: UsageReport
    let now: Date

    static let size = CGSize(width: 800, height: 450)
    static let link = "github.com/hunterbohm/lip-service"

    var body: some View {
        let saved = report.minutesSaved.map { SavedTime(minutes: $0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 11) {
                    if let icon = Bundle.main.image(forResource: "AppIcon") {
                        Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                    } else {
                        Circle().fill(Theme.blue).frame(width: 12, height: 12)
                    }
                    Text("Lip Service").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                if let range = report.rangeCaption(now: now) {
                    Text(range).font(.system(size: 18)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(report.words.formatted()).font(.system(size: 98, weight: .light)).monospacedDigit()
                    Text("words").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 24)
                CardHeatmap(report: report, now: now).padding(.bottom, 22)
            }
            HStack(alignment: .top, spacing: 46) {
                if let saved { figure("\(saved.value) \(saved.isHours ? "hours" : "min")", "saved") }
                if let rate = report.wordsPerMinute { figure(rate.formatted(), "words a minute") }
                if report.longestStreak > 0 { figure(report.longestStreak == 1 ? "1 day" : "\(report.longestStreak) days", "longest streak") }
            }
            .padding(.top, 24)
            HStack(alignment: .firstTextBaseline) {
                Text("Spoken on my Mac. None of it left it.").foregroundStyle(Theme.tertiary)
                Spacer()
                Text(Self.link).foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 18))
            .padding(.top, 30)
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 46)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 33)).monospacedDigit()
            Text(label).font(.system(size: 18)).foregroundStyle(Theme.secondary)
        }
    }
}

/// The last thirteen weeks, Monday at the top, this week on the right.
private struct CardHeatmap: View {
    let report: UsageReport
    let now: Date
    private let weeks = 13, cell: CGFloat = 12, gap: CGFloat = 3

    var body: some View {
        let calendar = report.calendar
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 6 - (calendar.component(.weekday, from: today) + 5) % 7, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: end) ?? end
        HStack(spacing: gap) {
            ForEach(0..<weeks, id: \.self) { column in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = calendar.date(byAdding: .day, value: column * 7 + row, to: start) ?? start
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(day > today ? Color.clear : StatsColor.heat(report.days[day]?.words ?? 0, empty: Theme.tile))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }
}

@MainActor enum ShareImage {
    /// 1600 by 900, a 16:9 picture from the 800 by 450 card.
    static func png(_ report: UsageReport, now: Date) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(report: report, now: now).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copy(_ png: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    static func save(_ png: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Lip Service stats.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }
}

/// Floats over the page, dimming it, so the card can be chosen and kept without leaving the window.
struct ShareSheet: View {
    let entries: [HistoryEntry]
    let now: Date
    let close: () -> Void
    @State private var period = UsagePeriod.all
    @State private var copied = false

    private let scale: CGFloat = 0.74

    var body: some View {
        let report = UsageReport(entries: entries, period: period, now: now, calendar: .current)
        ZStack(alignment: .top) {
            Color(hex: 0x080809).opacity(0.62).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                Text("Share your stats").font(.system(size: 15, weight: .semibold)).padding(.bottom, 14)
                ShareCard(report: report, now: now)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: ShareCard.size.width * scale, height: ShareCard.size.height * scale, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0x34363B)))
                HStack {
                    Chips(items: UsagePeriod.allCases, title: \.title, selection: $period)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Button("Cancel", action: close).buttonStyle(DarkButtonStyle()).keyboardShortcut(.cancelAction)
                        Button(copied ? "Copied" : "Copy Image") { copy(report) }
                            .buttonStyle(DarkButtonStyle())
                            .disabled(!report.hasEntries)
                        Button("Save Image…") { save(report) }
                            .buttonStyle(DarkButtonStyle(kind: .prominent))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!report.hasEntries)
                    }
                }
                .padding(.top, 18)
            }
            .padding(20)
            .frame(width: ShareCard.size.width * scale + 40)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
            .padding(.top, 50)
        }
    }

    private func copy(_ report: UsageReport) {
        guard let png = ShareImage.png(report, now: now) else { return }
        ShareImage.copy(png)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func save(_ report: UsageReport) {
        if let png = ShareImage.png(report, now: now) { ShareImage.save(png) }
    }
}
