import AppKit
import DictationCore

/// An SSH session can never activate the app, so without this every control would draw in its inactive grey. These
/// are the selectors AppKit asks before drawing a control.
private final class RenderWindow: NSWindow {
    @objc var hasKeyAppearance: Bool { true }
    @objc var hasMainAppearance: Bool { true }
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
        var checks = SetupChecks(microphone: true, accessibility: false, fnKey: .needsSetting)
        let setup = SetupStatus { checks }
        let willow = WillowImporter(folder: scratch.appending(path: "willow"), defaults: defaults, history: history,
                                    preferences: preferences)
        let state = WindowState()
        let builtIn = AudioDevices.Input(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", deviceID: 91)
        let phone = AudioDevices.Input(uid: "C63FE4BD-iPhone", name: "iPhone Microphone", deviceID: 92)
        let inputs = Inputs { ([builtIn, phone], builtIn) }
        let services = WindowServices(preferences: preferences, history: history, setup: setup, willow: willow,
                                      loginItem: LoginItem(), inputs: inputs, level: InputLevel(fixed: 0.42), copy: { _ in })
        let window = RenderWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        MainWindow.configure(window, services: services, state: state)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }

        let shots: [(name: String, prepare: () -> Void)] = [
            ("home-setup", {}),
            ("home", { checks = SetupChecks(microphone: true, accessibility: true, fnKey: .ready); willow.dismissCard() }),
            ("home-search", { state.search = "profit" }),
            ("dictation", { state.search = ""; state.page = .dictation }),
            ("microphone", { state.page = .microphone }),
            ("dictionary", { state.page = .dictionary }),
            ("history", { state.page = .history }),
        ]
        var failures = 0
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
        return failures
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        NSApplication.shared.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    }

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
