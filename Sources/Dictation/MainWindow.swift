import AppKit
import AVFoundation
import Carbon
import DictationCore
import ServiceManagement
import SwiftUI

@MainActor struct WindowServices {
    let preferences: Preferences
    let history: HistoryStore
    let setup: SetupStatus
    let willow: WillowImporter
    let loginItem: LoginItem
    let inputs: Inputs
    let level: InputLevel
    let shortcuts: ShortcutRecording
    let copy: (String) -> Void
}

/// Lets the window borrow the keyboard to record a shortcut.
@MainActor struct ShortcutRecording {
    let start: (@escaping (ShortcutRecorder.Outcome) -> Void) -> Void
    let stop: () -> Void

    static let unavailable = ShortcutRecording(start: { _ in }, stop: {})
}

enum Page: String, CaseIterable, Identifiable {
    case home, dictation, microphone, dictionary, history

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .dictation: "keyboard"
        case .microphone: "mic"
        case .dictionary: "character.book.closed"
        case .history: "clock"
        }
    }
}

@MainActor @Observable final class WindowState {
    var page = Page.home
    var search = ""
}

@MainActor final class MainWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let autosaveName = "Lip Service"

    private let services: WindowServices
    private let state = WindowState()
    private let openOnLaunch: Bool
    private var window: NSWindow?

    init(coordinator: Coordinator) {
        let preferences = coordinator.preferences
        services = WindowServices(preferences: preferences, history: coordinator.history,
                                  setup: SetupStatus { SetupChecks.read(preferences) },
                                  willow: WillowImporter(history: coordinator.history, preferences: preferences),
                                  loginItem: LoginItem(), inputs: Inputs(), level: InputLevel(),
                                  shortcuts: ShortcutRecording(start: { [weak coordinator] in coordinator?.recordShortcut($0) },
                                                               stop: { [weak coordinator] in coordinator?.stopRecordingShortcut() }),
                                  copy: { [inserter = coordinator.inserter] in inserter.copy($0) })
        openOnLaunch = preferences.isFirstLaunch
    }

    /// With the menu bar icon hidden, a launch that shows no window would look like nothing happened. Login launches
    /// stay quiet.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let iconHidden = !services.preferences.current.settings.showMenuBarIcon
        if openOnLaunch || (iconHidden && !Self.launchedAsLoginItem) { openWindow(nil) }
    }

    /// Valid only during applicationDidFinishLaunching, while the launch event is current.
    private static var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(nil)
        return false
    }

    @objc func openWindow(_ sender: Any?) {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        services.preferences.reloadVocabularyIfChanged()
        services.setup.refresh()
        services.inputs.refresh()
        services.loginItem.refresh()
        services.willow.refresh()
    }

    /// Releasing the window frees its views, which also ends the setup polling. Page and search live on in `state`.
    /// The level meter stops here too, so a closed window never keeps the microphone open.
    func windowWillClose(_ notification: Notification) {
        services.level.stop()
        services.shortcuts.stop()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        Self.configure(window, services: services, state: state)
        window.delegate = self
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }

    static func configure(_ window: NSWindow, services: WindowServices, state: WindowState) {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.title = "Lip Service"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Always dark, like the Tesla screen it follows. Controls and sheets match.
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WindowRoot(services: services, state: state))
        host.sizingOptions = [.minSize]
        window.contentView = host
    }

    /// Text fields need the Edit menu for their shortcuts while the app is regular.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        add("Lip Service", [item("About Lip Service", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), .separator(),
                            item("Quit Lip Service", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"),
                       item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }
}

struct SetupChecks: Equatable {
    enum FnKey { case notAHotkey, ready, needsSetting }

    var microphone: Bool
    var accessibility: Bool
    var fnKey: FnKey

    var isComplete: Bool { microphone && accessibility && fnKey != .needsSetting }

    @MainActor static func read(_ preferences: Preferences) -> SetupChecks {
        SetupChecks(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    accessibility: AXIsProcessTrusted(),
                    fnKey: !preferences.current.settings.hotkeys.contains(where: { $0.key == Shortcut.fn.key }) ? .notAHotkey
                        : preferences.fnKeyNeedsSetting ? .needsSetting : .ready)
    }
}

@MainActor @Observable final class SetupStatus {
    private(set) var checks: SetupChecks
    @ObservationIgnored private let read: @MainActor () -> SetupChecks

    init(read: @escaping @MainActor () -> SetupChecks) {
        self.read = read
        checks = read()
    }

    func refresh() {
        let next = read()
        if next != checks { checks = next }
    }
}

@MainActor @Observable final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var note: String? {
        error ?? (status == .requiresApproval ? "Turn on Lip Service in System Settings > General > Login Items." : nil)
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }

    func refresh() { status = SMAppService.mainApp.status }
}

enum SystemSettingsPane: String {
    case microphone = "com.apple.preference.security?Privacy_Microphone"
    case accessibility = "com.apple.preference.security?Privacy_Accessibility"
    case keyboard = "com.apple.Keyboard-Settings.extension"

    @MainActor func open() {
        if let url = URL(string: "x-apple.systempreferences:\(rawValue)") { NSWorkspace.shared.open(url) }
    }
}
