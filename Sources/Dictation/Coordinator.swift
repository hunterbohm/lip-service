import AppKit
import DictationCore
import os

/// Wires the owners together. It holds only the facts no owner has: how many dictations are in flight, the live
/// words of the newest capture, the last dictated text, and the current notice. The bar state is derived from
/// those, the hotkey phase, and the engine status.
@MainActor final class Coordinator {
    private static let noticeSeconds = 6.0
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "dictation")

    let preferences = Preferences()
    let history = HistoryStore()
    private let microphone = Microphone()
    let inserter: Inserter
    private let sounds = Sounds()
    private let keyTap: KeyTap
    private let engine: SpeechEngine
    private let bar: Bar
    private let menu: StatusMenu
    private var engineStatus = EngineStatus.loading(.compiling)
    private var pending = 0
    private var words = ""
    private var previews: Task<Void, Never>?
    private var lastText: String?
    /// An unplugged microphone reported before the bar showed, so a fn chord never flashes it.
    private var fallback: String?
    private var missingMicrophone = MissingMicrophone()
    private var notice: BarNotice?
    private var noticeSerial = 0

    init() {
        inserter = Inserter(preferences: preferences)
        keyTap = KeyTap(hotkeys: preferences.current.settings.hotkeys, pasteLast: preferences.current.settings.pasteLast)
        engine = SpeechEngine(vocabulary: preferences.current.activeVocabulary)
        bar = Bar(level: { [microphone] in microphone.level })
        menu = StatusMenu(preferences: preferences, engine: engine, inserter: inserter)
    }

    func start() {
        keyTap.onUpdate = { [unowned self] commands, cue in handle(commands, cue: cue) }
        keyTap.onPasteLast = { [unowned self] in pasteLast() }
        bar.onEvent = { [unowned self] event in
            switch event {
            case .stop: keyTap.click(.stopClicked(.now))
            case .cancel: keyTap.click(.cancelClicked(.now))
            case .moved(let edge): preferences.change { $0.barEdge = edge }
            case .toastAction(.retryModel): engine.retry()
            }
        }
        preferences.onChange = { [unowned self] old, new in apply(old, new) }
        microphone.onFailure = { [unowned self] error in
            stopPreviews()
            keyTap.abort()
            show(.failed(error.localizedDescription))
        }
        microphone.onSource = { [unowned self] source in
            fallback = missingMicrophone.toMention(for: source)
            if keyTap.machine.showsListening { showFallback() }
        }
        Task { [unowned self] in
            for await status in engine.statuses {
                engineStatus = status
                render()
            }
        }
        Microphone.requestAccessIfNeeded()
        keyTap.start()
        render()
    }

    private func apply(_ old: Configuration, _ new: Configuration) {
        if old.activeVocabulary != new.activeVocabulary { engine.configure(vocabulary: new.activeVocabulary) }
        if old.settings.hotkeys != new.settings.hotkeys {
            stopPreviews()
            microphone.cancel()
            keyTap.hotkeys = new.settings.hotkeys
        }
        keyTap.pasteLast = new.settings.pasteLast
        render()
    }

    /// The window's shortcut recorder borrows the keyboard from dictation until it has a result.
    func recordShortcut(_ done: @escaping (ShortcutRecorder.Outcome) -> Void) { keyTap.record(done) }

    func stopRecordingShortcut() { keyTap.stopRecording() }

    /// Release path, first half, on the main turn after the tap callback. It takes the samples already
    /// converted, notes the focus, and hands off. Nothing here waits on the model or the audio engine.
    private func handle(_ commands: [CaptureCommand], cue: Cue?) {
        for command in commands {
            switch command {
            case .start:
                fallback = nil
                words = ""
                preferences.reloadVocabularyIfChanged()
                do {
                    try microphone.start(from: preferences.current.settings.microphone)
                    engine.prepare()
                    startPreviews()
                } catch {
                    keyTap.abort()
                    show(.failed(error.localizedDescription))
                }
            case .cancel:
                fallback = nil
                stopPreviews()
                microphone.cancel()
            case .finish:
                stopPreviews()
                guard let recording = microphone.stop(releasedAt: .now) else { break }
                let target = FocusTarget.current()
                pending += 1
                Task { await deliver(recording, to: target) }
            }
        }
        if cue == .start {
            notice = nil
            showFallback()
        }
        if let cue, preferences.current.settings.sounds { sounds.play(cue) }
        render()
    }

    private func showFallback() {
        guard let missing = fallback else { return }
        fallback = nil
        missingMicrophone.didMention(missing)
        show(.microphoneMissing(chosen: missing, using: AudioDevices.defaultInput()?.name ?? "the system default"))
    }

    /// One preview loop per capture. Only `dictate` decides the inserted text.
    private func startPreviews() {
        stopPreviews()
        previews = Task { [unowned self, engine, microphone] in
            for await text in engine.previews(of: microphone.audio) where !Task.isCancelled {
                words = text
                render()
            }
        }
    }

    private func stopPreviews() {
        previews?.cancel()
        previews = nil
    }

    /// Second half. The engine's worker transcribes off main, then this resumes on main to remember and insert.
    private func deliver(_ recording: Recording, to target: FocusTarget) async {
        let dictation: Dictation
        do {
            dictation = try await engine.dictate(recording)
        } catch {
            pending -= 1
            show(.failed("Transcription failed: \(error.localizedDescription)"))
            return
        }
        pending -= 1
        render()
        log.info("""
            \(recording.seconds, format: .fixed(precision: 1)) s audio, release to text \(Instant.now - recording.releasedAt, format: .fixed(precision: 3)) s \
            (waited \(dictation.waited, format: .fixed(precision: 3)), decode \(dictation.decode, format: .fixed(precision: 3)), \
            rescore \(dictation.rescore, format: .fixed(precision: 3)))
            """)
        guard !dictation.text.isEmpty else { return }
        lastText = dictation.text
        menu.remember(dictation.text)
        if preferences.current.settings.keepHistory { history.add(HistoryEntry(text: dictation.text, audioSeconds: recording.seconds, app: target.app)) }
        let outcome = await inserter.insert(dictation.text, target: target, releasedAt: recording.releasedAt)
        if case .copied(let reason) = outcome {
            log.info("copied instead of pasting: \(String(describing: reason), privacy: .public)")
            show(.copied(reason))
        }
    }

    /// Control+Command+V. The last dictation again, wherever focus is now.
    private func pasteLast() {
        guard let lastText else { return show(.nothingToPaste) }
        Task {
            if case .copied(let reason) = await inserter.insert(lastText, target: .current(), releasedAt: .now) {
                show(.copied(reason))
            }
        }
    }

    private func show(_ notice: BarNotice) {
        self.notice = notice
        noticeSerial += 1
        let serial = noticeSerial
        render()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard let self, noticeSerial == serial else { return }
            self.notice = nil
            render()
        }
    }

    private func render() {
        let settings = preferences.current.settings
        bar.render(BarState.derive(hotkey: keyTap.machine, words: words, pending: pending, engine: engineStatus,
                                   notice: notice, showsIdle: !settings.hideBarWhenIdle),
                   edge: settings.barEdge)
        menu.show(engine: engineStatus, keyTapRunning: keyTap.isRunning, waiting: pending)
    }
}
