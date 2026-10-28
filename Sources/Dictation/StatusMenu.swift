import AppKit
import DictationCore

/// The menu bar item. The single owner of the recent-dictations list, kept in memory only, newest first.
/// Menu choices go straight to the owner of what they change.
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    static let recentLimit = 20

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let preferences: Preferences
    private let engine: SpeechEngine
    private let inserter: Inserter
    private var recents: [String] = []
    private var engineStatus = EngineStatus.loading(.compiling)
    private var keyTapRunning = false
    private var waiting = 0

    init(preferences: Preferences, engine: SpeechEngine, inserter: Inserter) {
        (self.preferences, self.engine, self.inserter) = (preferences, engine, inserter)
        super.init()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    /// Called before insertion is tried, so the text survives whatever happens next.
    func remember(_ text: String) {
        recents.insert(text, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    }

    func show(engine: EngineStatus, keyTapRunning: Bool, waiting: Int) {
        (engineStatus, self.keyTapRunning, self.waiting) = (engine, keyTapRunning, waiting)
        updateIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        preferences.reloadVocabularyIfChanged()
        let configuration = preferences.current
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Open Lip Service…", action: #selector(MainWindow.openWindow(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(disabled(statusLine))
        if case .failed = engineStatus { menu.addItem(ActionItem("Retry Loading the Model") { [engine] in engine.retry() }) }
        if !keyTapRunning {
            menu.addItem(ActionItem("Allow Accessibility to Use the Hotkey…") { Self.openSettings("com.apple.preference.security?Privacy_Accessibility") })
        }
        if Microphone.accessDenied {
            menu.addItem(ActionItem("Allow Microphone Access…") { Self.openSettings("com.apple.preference.security?Privacy_Microphone") })
        }
        if preferences.fnKeyNeedsSetting {
            menu.addItem(ActionItem("Set Keyboard > Press fn Key To > Do Nothing…") { Self.openSettings(Self.keyboardSettings) })
        }
        if let issue = configuration.issues.first {
            let more = configuration.issues.count > 1 ? " (and \(configuration.issues.count - 1) more)" : ""
            menu.addItem(ActionItem("Vocabulary line \(issue.line): \(issue.message)\(more)") { [weak self] in self?.openVocabularyFile() })
        }
        menu.addItem(.separator())

        let recentMenu = NSMenu()
        if recents.isEmpty { recentMenu.addItem(disabled("No dictations yet")) }
        for text in recents {
            let recent = ActionItem(Self.preview(text)) { [inserter] in inserter.copy(text) }
            recent.toolTip = text
            recentMenu.addItem(recent)
        }
        menu.addItem(submenu("Recent Dictations", recentMenu))

        let hotkeyMenu = NSMenu()
        for shortcut in configuration.settings.hotkeys { hotkeyMenu.addItem(disabled(shortcut.title)) }
        hotkeyMenu.addItem(.separator())
        hotkeyMenu.addItem(NSMenuItem(title: "Change Keys…", action: #selector(MainWindow.openWindow(_:)), keyEquivalent: ""))
        menu.addItem(submenu("Dictation Keys", hotkeyMenu))
        menu.addItem(submenu("Microphone", microphoneMenu(chosen: configuration.settings.microphone)))
        menu.addItem(ActionItem("Vocabulary Boosting", checked: configuration.settings.vocabularyEnabled) { [preferences] in
            preferences.change { $0.vocabularyEnabled.toggle() }
        })
        menu.addItem(ActionItem("Open Vocabulary File") { [weak self] in self?.openVocabularyFile() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lip Service", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// System Default, then each input connected now. A chosen device that is unplugged stays listed and checked.
    private func microphoneMenu(chosen: MicrophoneChoice) -> NSMenu {
        let microphones = NSMenu()
        let inputs = AudioDevices.inputs()
        let defaultTitle = AudioDevices.defaultInput().map { "System Default (\($0.name))" } ?? "System Default"
        microphones.addItem(ActionItem(defaultTitle, checked: chosen == .systemDefault) { [preferences] in
            preferences.change { $0.microphone = .systemDefault }
        })
        microphones.addItem(.separator())
        for input in inputs {
            let choice = MicrophoneChoice.device(uid: input.uid, name: input.name)
            let checked = if case .device(let uid, _) = chosen { uid == input.uid } else { false }
            microphones.addItem(ActionItem(input.name, checked: checked) { [preferences] in
                preferences.change { $0.microphone = choice }
            })
        }
        if case .device(let uid, let name) = chosen, !inputs.contains(where: { $0.uid == uid }) {
            let absent = disabled("\(name) (not connected)")
            absent.state = .on
            microphones.addItem(absent)
        }
        return microphones
    }

    private var statusLine: String {
        let status = switch engineStatus {
        case .loading(.downloading(let fraction)): "Downloading model \(Int(fraction * 100))%"
        case .loading(.compiling): "Preparing model"
        case .loading(.preparingVocabulary): "Preparing vocabulary"
        case .ready(.on): "Ready"
        case .ready(.off): preferences.current.activeVocabulary == nil ? "Ready, vocabulary boosting off" : "Ready"
        case .ready(.unavailable(let reason)): "Ready, vocabulary boosting unavailable: \(reason)"
        case .failed(let reason): "Model failed: \(reason)"
        }
        guard waiting > 0, !isReady else { return status }
        return "\(status) (\(waiting) waiting)"
    }

    private var isReady: Bool { if case .ready = engineStatus { true } else { false } }

    private func updateIcon() {
        item.isVisible = preferences.current.settings.showMenuBarIcon
        let needsAttention = !keyTapRunning || { if case .failed = engineStatus { true } else { false } }()
        let symbol = needsAttention ? "mic.badge.xmark" : "mic"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lip Service")
            ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Lip Service")
        image?.isTemplate = true
        item.button?.image = image
    }

    private func openVocabularyFile() {
        preferences.seedVocabularyFile()
        NSWorkspace.shared.open(preferences.vocabularyURL)
    }

    static let keyboardSettings = "com.apple.Keyboard-Settings.extension"

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
