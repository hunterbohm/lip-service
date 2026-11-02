import AppKit
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// How your words look in each kind of app: a tab per group, three styles to pick from, and the apps in the group.
struct ProfilesPage: View {
    let preferences: Preferences
    @Bindable var state: WindowState

    private static let example = "Sounds good, see you at 5."

    var body: some View {
        let profiles = preferences.current.settings.profiles
        let group = state.profileGroup
        let rules = profiles.rules[group] ?? ProfileRules(style: .formal)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Profiles", lead: "How your words look in each kind of app.")
                Segmented(options: ProfileGroup.allCases.map { ($0.title, $0) }, selection: $state.profileGroup, font: 13, horizontal: 16, vertical: 9)
                HStack(spacing: 10) {
                    ForEach(WritingStyle.allCases, id: \.self) { style in
                        StyleCard(style: style, sample: style.apply(Self.example, keeping: []), isOn: rules.style == style) {
                            change { $0.set(ProfileRules(style: style, pressReturn: rules.pressReturn), for: group) }
                        }
                    }
                }
                .padding(.vertical, 14)
                RowList {
                    if group.listsApps {
                        ListRow(divider: false) {
                            Text("Press Return after the text goes in").font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            SquareCheck(isOn: Binding(get: { rules.pressReturn },
                                                      set: { on in change { $0.set(ProfileRules(style: rules.style, pressReturn: on), for: group) } }))
                        }
                    }
                    ListRow(divider: group.listsApps) {
                        if group.listsApps {
                            let apps = ProfileApps.shown(in: group, of: profiles)
                            if apps.isEmpty {
                                Text("No apps yet").font(.system(size: 13)).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                FlowRow(spacing: 6) { ForEach(apps, id: \.bundleID) { AppChip(app: $0, remove: nil) } }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button("Edit") { state.sheet = .apps }.buttonStyle(DarkButtonStyle())
                        } else {
                            Text("Every app not in another group").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .page()
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    private func change(_ edit: (inout AppProfiles) -> Void) { preferences.change { edit(&$0.profiles) } }
}

/// The apps to show for a group: the ones installed on this Mac and the ones the user added. A built-in app that is not
/// here stays in the group, unseen, so it still works if it is installed later.
@MainActor enum ProfileApps {
    static func shown(in group: ProfileGroup, of profiles: AppProfiles) -> [ProfileApp] {
        let builtIn = Set(AppProfiles.defaults.apps.map { $0.bundleID.lowercased() })
        return profiles.apps(in: group).filter { !builtIn.contains($0.bundleID.lowercased()) || AppInstalled.check($0.bundleID) }
    }
}

private struct StyleCard: View {
    let style: WritingStyle
    let sample: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Text(style.title).font(.system(size: 13.5, weight: .semibold))
                Text(sample)
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.blue))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isOn ? Theme.blue : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The app's own icon, or its first letter on a plain tile when it has none here.
private struct AppIcon: View {
    let app: ProfileApp

    var body: some View {
        if let image = AppIcons.installedImage(for: app.bundleID) {
            image.resizable().frame(width: 16, height: 16)
        } else {
            Text(String(app.name.prefix(1))).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(Theme.chosen.opacity(0.5)))
        }
    }
}

/// An app in a group. With `remove`, a small x takes it out.
struct AppChip: View {
    let app: ProfileApp
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            AppIcon(app: app)
            Text(app.name).font(.system(size: 12.5)).lineLimit(1)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text.opacity(0.6))
                    .help("Remove")
            }
        }
        .foregroundStyle(Color(hex: 0xD8D8DA))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
        .help(app.bundleID)
    }
}

/// Add or take out the apps of one group.
struct AppsSheet: View {
    let preferences: Preferences
    let group: ProfileGroup
    let close: () -> Void

    var body: some View {
        let profiles = preferences.current.settings.profiles
        let apps = ProfileApps.shown(in: group, of: profiles)
        SheetOverlay(width: 480, close: close) {
            VStack(alignment: .leading, spacing: 14) {
                SheetTitle(title: "Apps in \(group.title)", done: close)
                Text("The app in front when you let go of the key picks the group.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                if apps.isEmpty {
                    Text("No apps yet").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(apps, id: \.bundleID) { app in
                            AppChip(app: app) { preferences.change { $0.profiles.remove(app.bundleID) } }
                        }
                    }
                }
                AddAppMenu(group: group, profiles: profiles) { edit in preferences.change { edit(&$0.profiles) } }
            }
        }
    }
}

struct AddAppMenu: View {
    let group: ProfileGroup
    let profiles: AppProfiles
    let change: ((inout AppProfiles) -> Void) -> Void

    var body: some View {
        Menu {
            let running = Self.runningApps().filter { profiles.group(for: $0.bundleID) != group }
            if !running.isEmpty {
                Section("Open apps") {
                    ForEach(running) { app in
                        let current = profiles.group(for: app.bundleID)
                        Button(current.listsApps ? "\(app.name) (in \(current.title))" : app.name) { add(app) }
                    }
                }
            }
            Button("Choose an App…") { if let app = Self.chooseApp() { add(app) } }
        } label: {
            Label("Add App", systemImage: "plus").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DarkButtonStyle())
        .fixedSize()
    }

    private struct Candidate: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    private func add(_ app: Candidate) {
        change { $0.add(ProfileApp(bundleID: app.bundleID, name: app.name, group: group)) }
    }

    private static func runningApps() -> [Candidate] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { Candidate(bundleID: $0, name: app.localizedName ?? $0) } }
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func chooseApp() -> Candidate? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            return nil
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return Candidate(bundleID: id, name: name)
    }
}

/// App icons by bundle ID, looked up once each. A wildcard ID uses the app its prefix names, if one is installed.
@MainActor enum AppIcons {
    private static var cache: [String: Image] = [:]

    /// Nil when no app with this ID is installed.
    static func installedImage(for bundleID: String) -> Image? {
        let id = bundleID.hasSuffix("*") ? String(bundleID.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "."))) : bundleID
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil ? image(for: bundleID) : nil
    }

    static func image(for bundleID: String) -> Image {
        if let cached = cache[bundleID] { return cached }
        let id = bundleID.hasSuffix("*") ? String(bundleID.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "."))) : bundleID
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).flatMap { url in
            var rect = NSRect(x: 0, y: 0, width: 36, height: 36)
            return NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
                .map { Image(decorative: $0, scale: 2) }
        } ?? Image(systemName: "app.dashed")
        cache[bundleID] = image
        return image
    }
}

/// Lays its children out left to right and wraps them onto new rows.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
