import AppKit
import DictationCore

/// An SSH session can never activate the app, so without this every control would draw in its inactive grey. These
/// are the selectors AppKit asks before drawing a control.
private final class RenderWindow: NSWindow {
    @objc var hasKeyAppearance: Bool { true }
    @objc var hasMainAppearance: Bool { true }
    /// Lets the tall Stats shots keep their height instead of shrinking to the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor enum WindowRender {
    static func run(to directory: URL) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        return render(to: directory) == 0 ? 0 : 1
    }

    private static func render(to directory: URL) -> Int {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "lip-service-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.createDirectory(at: scratch.appending(path: "willow"), withIntermediateDirectories: true)
        // A path as the suite name keeps these defaults in the scratch folder, out of ~/Library/Preferences.
        guard let defaults = UserDefaults(suiteName: scratch.appending(path: "defaults").path) else { return 1 }

        let vocabularyURL = scratch.appending(path: "vocabulary.txt")
        try? sampleVocabulary.write(to: vocabularyURL, atomically: true, encoding: .utf8)
        let preferences = Preferences(defaults: defaults, vocabularyURL: vocabularyURL)
        preferences.change {
            $0.barEdge = .right
            $0.microphone = .device(uid: "AppleUSBAudioEngine:Shure Inc:Shure MV7+:2B0E000:1", name: "Shure MV7+")
        }
        let history = HistoryStore(url: scratch.appending(path: "history.jsonl"))
        _ = history.merge(sampleHistory(now: .now))
        let statsSample = statsSampleHistory(now: .now)
        var checks = SetupChecks(microphone: true, accessibility: false, fnKey: .needsSetting)
        let setup = SetupStatus { checks }
        let willow = WillowImporter(folder: scratch.appending(path: "willow"), defaults: defaults, history: history,
                                    preferences: preferences)
        let state = WindowState()
        let builtIn = AudioDevices.Input(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", deviceID: 91, kind: .builtIn)
        let airPods = AudioDevices.Input(uid: "F8-1E-49-9B-27-6C:input", name: "AirPods Pro", deviceID: 92, kind: .bluetooth)
        let inputs = Inputs { ([builtIn, airPods], builtIn, false) }
        let agentServices = AgentServices(pool: AgentPool(), preferences: preferences, history: history)
        agentServices.isStatic = true
        let timing = DictationTiming()
        AppInstalled.override = { sampleInstalled.contains($0) }
        defer { AppInstalled.override = nil }
        let services = WindowServices(preferences: preferences, history: history, setup: setup, willow: willow,
                                      loginItem: LoginItem(), inputs: inputs, level: InputLevel(fixed: 0.42),
                                      shortcuts: .unavailable, copy: { _ in }, agents: agentServices, timing: timing, updates: .sample, openSetup: { _ in })
        let window = RenderWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        MainWindow.configure(window, services: services, state: state)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }

        let shots: [(name: String, prepare: () -> Void)] = [
            ("home-setup", {}),
            ("home", { checks = SetupChecks(microphone: true, accessibility: true, fnKey: .ready); willow.dismissCard() }),
            ("home-search", { state.search = "profit" }),
            ("dictation", { state.search = ""; state.page = .dictation; window.setContentSize(NSSize(width: 1000, height: 860)) }),
            ("ghostwrite-empty", { state.page = .ghostwrite; window.setContentSize(NSSize(width: 1000, height: 640)) }),
            ("ghostwrite", {
                preferences.change { settings in
                    var hermes = AgentPreset.with(id: "hermes")!.connection()
                    hermes.remoteHost = "mini"
                    hermes.destination = .iMessage(handle: "+1 415 555 0182")
                    let claude = AgentPreset.with(id: "claude")!.connection()
                    settings.agents.agents = [hermes, claude]
                    settings.agents.defaultAgent = "hermes"
                    settings.agents.voiceNotes = "Short and direct. Lowercase in chats, full sentences in email. Signs emails \u{201C}Hunter\u{201D}. No exclamation marks."
                }
                agentServices.show(installed: ["claude", "codex"])
                agentServices.show(status: .ready(seconds: 1.4, model: "claude-haiku-5-5"), for: "hermes")
                agentServices.show(status: .ready(seconds: 2.1, model: "haiku"), for: "claude")
                window.setContentSize(NSSize(width: 1000, height: 680))
            }),
            ("ghostwrite-unreachable", {
                agentServices.show(status: .failed("ssh: connect to host mini port 22: Operation timed out"), for: "hermes")
            }),
            ("ghostwrite-change", {
                agentServices.show(status: .ready(seconds: 1.4, model: "claude-haiku-5-5"), for: "hermes")
                state.sheet = .agents
                window.setContentSize(NSSize(width: 1000, height: 820))
            }),
            ("ghostwrite-change-another", { state.sheetAdding = true; window.setContentSize(NSSize(width: 1000, height: 960)) }),
            ("ghostwrite-change-advanced", { state.sheetAdding = false; state.sheetAdvanced = true; window.setContentSize(NSSize(width: 1000, height: 1180)) }),
            ("ghostwrite-voice", { state.sheetAdvanced = false; state.sheet = .voice; window.setContentSize(NSSize(width: 1000, height: 680)) }),
            ("ghostwrite-talk-hermes", {
                agentServices.show(status: .ready(seconds: 1.4, model: "claude-haiku-5-5"), for: "hermes")
                state.sheet = nil
                window.setContentSize(NSSize(width: 1000, height: 1100))
            }),
            ("ghostwrite-talk-claude", {
                preferences.change { $0.liveTalk.agentID = "claude" }
                agentServices.show(t3: .notConnected, for: "claude")
            }),
            ("ghostwrite-talk-claude-connected", { agentServices.show(t3: .connected(expires: Date(timeIntervalSinceNow: 29 * 86_400)), for: "claude") }),
            ("ghostwrite-talk-add-another", {
                preferences.change { $0.liveTalk.agentID = nil; $0.agents.agents = [$0.agents.agents[0]] }
            }),
            ("profiles-messages", {
                state.sheet = nil
                preferences.change { $0.profiles.set(ProfileRules(style: .veryCasual, pressReturn: true), for: .messages) }
                state.page = .profiles
                window.setContentSize(NSSize(width: 1000, height: 640))
            }),
            ("profiles-ai-and-code", { state.profileGroup = .aiAndCode }),
            ("profiles-everything-else", { state.profileGroup = .everythingElse }),
            ("profiles-edit-apps", { state.profileGroup = .aiAndCode; state.sheet = .apps }),
            ("microphone", { state.sheet = nil; window.setContentSize(NSSize(width: 1000, height: 640)); state.page = .microphone }),
            ("dictionary", {
                preferences.change { $0.snippets = sampleSnippets }
                state.page = .dictionary
                window.setContentSize(NSSize(width: 1000, height: 1000))
            }),
            ("dictionary-empty", {
                try? Vocabulary.bundledDefault.write(to: vocabularyURL, atomically: true, encoding: .utf8)
                preferences.reloadVocabularyIfChanged()
            }),
            ("history", { window.setContentSize(NSSize(width: 1000, height: 640)); state.page = .history }),
            ("stats", {
                history.deleteAll()
                _ = history.merge(statsSample)
                state.page = .stats
                window.setContentSize(NSSize(width: 1000, height: 940))
            }),
            ("stats-insights", { state.statsView = .insights; window.setContentSize(NSSize(width: 1000, height: 1330)) }),
            ("stats-charts", { state.statsView = .charts; window.setContentSize(NSSize(width: 1000, height: 1160)) }),
            ("stats-week", { state.statsPeriod = .week; state.statsView = .insights; window.setContentSize(NSSize(width: 1000, height: 1330)) }),
            ("stats-share", { state.statsPeriod = .all; state.statsView = .overview; state.sharingStats = true; window.setContentSize(NSSize(width: 1000, height: 640)) }),
            ("stats-empty", {
                state.sharingStats = false
                preferences.change { $0.keepHistory = false }
                history.deleteAll()
            }),
        ]
        var failures = 0
        if let card = ShareImage.png(UsageReport(entries: statsSample, period: .all, now: .now, calendar: .current), now: .now) {
            let url = directory.appending(path: "stats-share-card.png")
            do {
                try card.write(to: url)
                print(url.path)
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("\(url.path): \(error.localizedDescription)\n".utf8))
            }
        } else {
            failures += 1
        }
        for shot in shots {
            shot.prepare()
            setup.refresh()
            settle()
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                failures += 1
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = directory.appending(path: "\(shot.name).png")
            do {
                guard let png = rep.representation(using: .png, properties: [:]) else { throw DictationError("PNG encoding failed") }
                try png.write(to: url)
                print(url.path)
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("\(url.path): \(error.localizedDescription)\n".utf8))
            }
        }
        failures += renderFirstRun(to: directory, scratch: scratch)
        return failures
    }

    /// Every step of the first run in its own 640 by 520 window, on settings of a fresh install.
    private static func renderFirstRun(to directory: URL, scratch: URL) -> Int {
        guard let defaults = UserDefaults(suiteName: scratch.appending(path: "first-run-defaults").path) else { return 1 }
        let preferences = Preferences(defaults: defaults, vocabularyURL: scratch.appending(path: "first-run-vocabulary.txt"))
        let history = HistoryStore(url: scratch.appending(path: "first-run-history.jsonl"))
        var checks = SetupChecks(microphone: true, accessibility: false, fnKey: .needsSetting)
        let agentServices = AgentServices(pool: AgentPool(), preferences: preferences, history: history)
        agentServices.isStatic = true
        agentServices.show(installed: ["claude", "codex"])
        let timing = DictationTiming()
        let services = WindowServices(preferences: preferences, history: history, setup: SetupStatus { checks },
                                      willow: WillowImporter(folder: scratch.appending(path: "willow"), defaults: defaults, history: history, preferences: preferences),
                                      loginItem: LoginItem(), inputs: Inputs { ([], nil, false) }, level: InputLevel(fixed: 0), shortcuts: .unavailable,
                                      copy: { _ in }, agents: agentServices, timing: timing, updates: .sample, openSetup: { _ in })
        let model = OnboardingModel()
        let window = RenderWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        OnboardingWindow.configure(window, services: services, model: model)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }

        func hermes(handle: String) {
            preferences.change { settings in
                var agent = AgentPreset.with(id: "hermes")!.connection()
                agent.remoteHost = "mini"
                agent.destination = .iMessage(handle: handle)
                settings.agents.agents = [agent]
                settings.agents.defaultAgent = "hermes"
            }
        }
        func claude() {
            preferences.change { settings in
                settings.agents.agents = [AgentPreset.with(id: "claude")!.connection()]
                settings.agents.defaultAgent = "claude"
            }
        }
        let shots: [(name: String, prepare: () -> Void)] = [
            ("first-run-1-welcome", {}),
            ("first-run-1b-agent-prompt", { model.agentPath = true; model.agentPathStarted = .now }),
            ("first-run-1c-agent-applied", {
                let before = preferences.current.settings
                var applied = before
                var agent = AgentPreset.with(id: "hermes")!.connection()
                agent.remoteHost = "mini"
                agent.destination = .iMessage(handle: "+1 415 555 0182")
                applied.agents.agents = [agent]
                applied.agents.defaultAgent = "hermes"
                applied.agents.voiceNotes = "Short and direct. Lowercase in chats, full sentences in email."
                applied.profiles.set(ProfileRules(style: .veryCasual, pressReturn: true), for: .messages)
                applied.profiles.set(ProfileRules(style: .casual), for: .workChat)
                let changes = SetupSpec.changes(from: before.setupFields, to: applied.setupFields)
                preferences.adopt(settings: applied, record: SetupRecord(by: "Claude Code", changes: changes, previous: before.setupFields, date: .now + 1))
            }),
            ("first-run-2-permissions", {
                preferences.undoSetup()
                model.agentPath = false
                model.step = .permissions
            }),
            ("first-run-2b-permissions-done", { checks = SetupChecks(microphone: true, accessibility: true, fnKey: .ready) }),
            ("first-run-3-try-it", { model.step = .tryIt }),
            ("first-run-3b-try-it-done", {
                timing.record(0.2)
                model.tryText = "Testing one two three. This is already faster than typing."
                model.tried = true
            }),
            ("first-run-4-how-you-write", {
                preferences.change {
                    $0.profiles.set(ProfileRules(style: .veryCasual, pressReturn: true), for: .messages)
                    $0.profiles.set(ProfileRules(style: .casual), for: .workChat)
                    $0.profiles.set(ProfileRules(style: .formal), for: .email)
                }
                model.step = .style
            }),
            ("first-run-5-ghostwrite", { model.choice = "claude"; model.step = .ghostwrite }),
            ("first-run-5b-ghostwrite-another-mac", { model.choice = "hermes"; model.hermesHost = "mini" }),
            ("first-run-6-check-checking-hermes", {
                hermes(handle: "")
                agentServices.show(status: .testing, for: "hermes")
                model.step = .check
            }),
            ("first-run-6b-check-ready-hermes", {
                hermes(handle: "+1 415 555 0182")
                agentServices.show(status: .ready(seconds: 1.4, model: "claude-haiku-5-5"), for: "hermes")
            }),
            ("first-run-6c-check-failed", {
                agentServices.show(status: .failed("ssh: connect to host mini port 22: Operation timed out"), for: "hermes")
            }),
            ("first-run-6d-check-ready-claude", {
                claude()
                agentServices.show(status: .ready(seconds: 2.1, model: "haiku"), for: "claude")
                agentServices.show(t3: .notConnected, for: "claude")
            }),
            ("first-run-7-done", { model.step = .done }),
            ("first-run-7b-done-skipped", { preferences.change { $0.agents.agents = []; $0.agents.defaultAgent = nil }; model.skippedGhostwrite = true }),
        ]
        var failures = 0
        for shot in shots {
            shot.prepare()
            services.setup.refresh()
            settle()
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                failures += 1
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = directory.appending(path: "\(shot.name).png")
            do {
                guard let png = rep.representation(using: .png, properties: [:]) else { throw DictationError("PNG encoding failed") }
                try png.write(to: url)
                print(url.path)
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("\(url.path): \(error.localizedDescription)\n".utf8))
            }
        }
        return failures
    }

    /// The apps the render pretends are installed, so Profiles shows the same chips on any Mac.
    static let sampleInstalled: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.hnc.Discord",
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.apple.mail", "com.superhuman.electron",
        "com.t3tools.t3code*", "com.openai.chat", "com.anthropic.claudefordesktop", "com.openai.codex", "com.microsoft.VSCode",
        "com.mitchellh.ghostty", "com.apple.Terminal",
    ]

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        NSApplication.shared.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    }

    static let sampleSnippets = [
        Snippet(cue: "my address", text: "Hunter Bohm\n1100 Congress Avenue\nAustin, TX 78701"),
        Snippet(cue: "my email", text: "hunter@example.com"),
        Snippet(cue: "sign off", text: "Thanks,\nHunter"),
    ]

    static let sampleVocabulary = """
        ProfitPilot: profit pilot, prophet pilot
        Beehiiv: beehive, bee hive
        T3 Code: t three code
        Ghostty: ghosty
        Hermes
        Tailscale: tail scale
        Hunter Bohm: hunter bomb
        Obsidian

        """

    /// About seven months of made-up history for the Stats shots: imported dictations with no app first, then
    /// the app's own, busier at night, with a spread of apps and lengths. A fixed seed keeps the shots repeatable.
    static func statsSampleHistory(now: Date) -> [HistoryEntry] {
        var seed: UInt64 = 20_261_030
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func pick<T>(_ weighted: [(T, Double)]) -> T {
            var roll = next() * weighted.reduce(0) { $0 + $1.1 }
            for (value, weight) in weighted {
                roll -= weight
                if roll <= 0 { return value }
            }
            return weighted[weighted.count - 1].0
        }
        let apps: [(HistoryApp?, Double)] = [
            (HistoryApp(name: "T3 Code", bundleID: "com.t3tools.t3code"), 28),
            (HistoryApp(name: "ChatGPT", bundleID: "com.openai.chat"), 20),
            (HistoryApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"), 14),
            (HistoryApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop"), 9),
            (HistoryApp(name: "Obsidian", bundleID: "md.obsidian"), 7),
            (HistoryApp(name: "Messages", bundleID: "com.apple.MobileSMS"), 7),
            (HistoryApp(name: "Helium", bundleID: "net.imput.helium"), 4),
            (nil, 11),
        ]
        let hours: [(Int, Double)] = Array([9, 10, 6, 5, 2, 2, 1, 0.5, 1, 0.5, 1, 1, 1.5, 3, 1.5, 2, 1, 1.5, 2.5, 2, 3.5, 4.5, 6.5, 8].enumerated()).map { ($0.offset, $0.element) }
        let lengths: [(ClosedRange<Int>, Double)] = [(1...5, 14), (6...10, 11), (11...20, 16), (21...40, 20), (41...80, 15), (81...160, 7), (161...300, 1.5)]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let span = 210, switchedDaysAgo = 40
        var entries: [HistoryEntry] = []
        for daysAgo in stride(from: span, through: 0, by: -1) {
            guard daysAgo < 14 || next() < 0.66, let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let busy = next() < 0.06 ? 3.0 : 1.0
            let count = Int((1 + pow(next(), 2.2) * 12) * busy)
            let imported = daysAgo > switchedDaysAgo
            let progress = Double(span - daysAgo) / Double(span)
            for _ in 0..<count {
                let date = day.addingTimeInterval(Double(pick(hours)) * 3600 + next() * 3599)
                guard date <= now else { continue }
                let words = pick(lengths).clamped(next())
                let speed = 138 + 30 * progress + (next() - 0.5) * 14
                entries.append(HistoryEntry(id: imported ? "willow:\(entries.count)" : "sample-\(entries.count)", date: date,
                                            text: Array(repeating: "word", count: words).joined(separator: " "),
                                            audioSeconds: next() < 0.85 ? Double(words) / speed * 60 : nil,
                                            app: imported ? nil : pick(apps)))
            }
        }
        return entries
    }

    static func sampleHistory(now: Date) -> [HistoryEntry] {
        let apps = [
            "T3 Code": "com.t3tools.t3code", "ChatGPT": "com.openai.chat", "Ghostty": "com.mitchellh.ghostty",
            "Grok": "ai.x.grok", "Helium": "net.imput.helium", "Obsidian": "md.obsidian", "Messages": "com.apple.MobileSMS",
        ]
        let samples: [(app: String, text: String)] = [
            ("T3 Code", "Open the ProfitPilot repo and add a weekly margin report to the dashboard. Keep the chart in the same style as the revenue one and write a test for the empty week."),
            ("Messages", "Running about ten minutes late, save me a seat."),
            ("ChatGPT", "What is the difference between a login item and a launch agent on macOS, and which one should a menu bar app use?"),
            ("Ghostty", "Show me the last twenty lines of the Hermes log and tell me why the morning brief stopped."),
            ("T3 Code", "The history list scrolls slowly once it has a few thousand rows. Profile it, find what renders off screen, and fix that first."),
            ("Obsidian", "Idea for the newsletter: a short piece on dictating agent prompts instead of typing them, with the numbers from this month."),
            ("Grok", "Summarize what people are saying about on-device speech models this week."),
            ("Helium", "Beehiiv pricing for a newsletter with about four thousand subscribers."),
            ("T3 Code", "Rename the settings key, migrate the stored value, and delete the old code path in the same change."),
            ("Messages", "Sounds good, I'll send the contract over tonight."),
            ("ChatGPT", "Draft a friendly reply that says the launch moves to Friday and thanks them for their patience."),
            ("Ghostty", "Run the tests again and only show me the failures."),
            ("T3 Code", "Ask Codex to review the pull request first. If it passes, have Claude write the migration and run the tests."),
            ("Obsidian", "Weekly review: which clients are behind on payments, and is the Hermes brief still worth reading."),
            ("ChatGPT", "Give me three subject lines for the ProfitPilot launch email that do not sound like marketing."),
            ("Messages", "Can we move dinner to seven?"),
            ("T3 Code", "Add an empty state to the import screen and make sure it works in dark mode."),
            ("Grok", "Which profit margin is normal for a small agency that resells software?"),
            ("Ghostty", "Find every file that still imports the old settings module."),
            ("Helium", "Tailscale exit node setup on a Mac mini."),
        ]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var entries: [HistoryEntry] = []
        let perDay = [5, 4, 3, 4, 2, 0, 3, 4, 2, 3]
        var sample = 0
        for (daysAgo, count) in perDay.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            for index in 0..<count {
                let (app, text) = samples[sample % samples.count]
                sample += 1
                let minutes = 9 * 60 + index * 97 + daysAgo * 13
                var date = day.addingTimeInterval(Double(minutes) * 60)
                if daysAgo == 0 { date = min(date, now.addingTimeInterval(Double(-index - 1) * 600)) }
                let words = Double(HistoryEntry.wordCount(text))
                entries.append(HistoryEntry(id: "sample-\(sample)", date: date, text: text, audioSeconds: (words / 2.4).rounded(),
                                            app: HistoryApp(name: app, bundleID: apps[app])))
            }
        }
        return entries
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ fraction: Double) -> Int { lowerBound + Int(Double(upperBound - lowerBound) * fraction * fraction.squareRoot()) }
}

private final class SampleUpdateStore: UpdateCheckStore {
    var values = [UpdateChecker.versionKey: "1.0.9", UpdateChecker.pageKey: "https://github.com/hunterbohm/lip-service/releases/tag/v1.0.9"]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

extension UpdateNotice {
    /// A release newer than the app that is running, for the window render.
    @MainActor static var sample: UpdateNotice {
        UpdateNotice(UpdateChecker(store: SampleUpdateStore(), isEnabled: { true }, running: Version("1.0.7"), fetch: { nil }))
    }
}
