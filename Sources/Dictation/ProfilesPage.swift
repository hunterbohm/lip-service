import AppKit
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesPage: View {
    let preferences: Preferences

    var body: some View {
        let profiles = preferences.current.settings.profiles
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Profiles")
                Text("Each group of apps has its own style. The app in front when you let go of the key picks the group.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, -10)
                    .padding(.bottom, 26)
                ForEach(ProfileGroup.allCases) { group in
                    GroupSection(group: group, profiles: profiles, change: change)
                        .padding(.bottom, 32)
                }
            }
            .page()
        }
    }

    private func change(_ edit: (inout AppProfiles) -> Void) { preferences.change { edit(&$0.profiles) } }
}

private struct GroupSection: View {
    let group: ProfileGroup
    let profiles: AppProfiles
    let change: ((inout AppProfiles) -> Void) -> Void

    private static let example = "Sounds good, see you at 5."

    var body: some View {
        let rules = profiles.rules[group] ?? ProfileRules(style: .formal)
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: group.title, detail: group.listsApps ? nil : "Every app not in a group above.")
                .padding(.bottom, -12)
            HStack(spacing: 18) {
                TileGroup(kind: .choice, items: WritingStyle.allCases.map { style in
                    .init(title: style.title, help: Self.help(style), isOn: rules.style == style) {
                        change { $0.set(ProfileRules(style: style, pressReturn: rules.pressReturn), for: group) }
                    }
                }, width: 112)
                Text(rules.style.apply(Self.example, keeping: []))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.tertiary)
            }
            CheckRow(title: "Press Return after inserting", help: "Sends the message in most chat apps.",
                     isOn: Binding(get: { rules.pressReturn },
                                   set: { on in change { $0.set(ProfileRules(style: rules.style, pressReturn: on), for: group) } }))
            if group.listsApps {
                AppList(group: group, profiles: profiles, change: change)
            }
        }
    }

    private static func help(_ style: WritingStyle) -> String {
        switch style {
        case .formal: "Keeps capitals and punctuation."
        case .casual: "Leaves off the period at the end."
        case .veryCasual: "Leaves off the period at the end and writes in lowercase, except your dictionary words and I."
        }
    }
}

private struct AppList: View {
    let group: ProfileGroup
    let profiles: AppProfiles
    let change: ((inout AppProfiles) -> Void) -> Void

    var body: some View {
        let apps = profiles.apps(in: group)
        FlowRow(spacing: 8) {
            ForEach(apps, id: \.bundleID) { app in
                AppChip(app: app) { change { $0.remove(app.bundleID) } }
            }
            AddAppMenu(group: group, profiles: profiles, change: change)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

private struct AppChip: View {
    let app: ProfileApp
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcons.image(for: app.bundleID).resizable().frame(width: 18, height: 18)
            Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text.opacity(0.7))
                    .help("Remove")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.raised : Theme.tile))
        .help(app.bundleID)
        .onHover { hovering = $0 }
    }
}

private struct AddAppMenu: View {
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
