import AppKit
import Carbon.HIToolbox
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
    private let muter = OutputMuter()
    private let keyTap: KeyTap
    private let engine: SpeechEngine
    private let bar: Bar
    private let menu: StatusMenu
    let agents = AgentPool()
    let timing = DictationTiming()
    private var setupObserver: (any NSObjectProtocol)?
    private var ghostwriter: Ghostwriter!
    /// What the running capture is for, and whether it goes to the agent rather than the cursor: a Ghostwrite or Hand
    /// off key, or fn held while a draft is open, which speaks a change to it.
    private var captureKind = CaptureKind.dictate
    private var toAgent = false
    private var engineStatus = EngineStatus.loading(.compiling)
    private var pending = 0
    private var words = ""
    private var previews: Task<Void, Never>?
    private var last: Insertion?
    /// An unplugged microphone reported before the bar showed, so a fn chord never flashes it.
    private var fallback: String?
    private var missingMicrophone = MissingMicrophone()
    private var notice: BarNotice?
    private var noticeSerial = 0
    /// Counts captures, so names from the screen that arrive after their capture ended are dropped.
    private var capture = 0
    /// The newest dictation Learn from your fixes watches, until the next dictation or a minute later.
    private var watchedFix: (pasted: Inserter.Pasted, serial: Int)?
    private var fixSerial = 0
    /// The word the Learned notice can undo.
    private var learned: Vocabulary.Term?
    private var fnSettingMentioned = false
    /// A vocabulary change waiting for no dictation to be in flight, since the engine rebuilds its rescorer between
    /// jobs and a release would wait on it. Learning a word saves one at the start of the next capture.
    private var vocabularyToApply: Vocabulary??

    init() {
        inserter = Inserter(preferences: preferences)
        keyTap = KeyTap(keys: preferences.current.settings.captureKeys, pasteLast: preferences.current.settings.pasteLast)
        engine = SpeechEngine(vocabulary: preferences.current.activeVocabulary)
        bar = Bar(level: { [microphone] in microphone.level })
        menu = StatusMenu(preferences: preferences, engine: engine, inserter: inserter)
        ghostwriter = Ghostwriter(preferences: preferences, history: history, inserter: inserter, engine: engine, pool: agents,
                                  anchor: { [bar] in bar.anchor() })
    }

    func start() {
        keyTap.onUpdate = { [unowned self] commands, cue in handle(commands, cue: cue) }
        keyTap.onPasteLast = { [unowned self] in pasteLast() }
        keyTap.onCardKey = { [unowned self] key in ghostwriter.cardKey(key) }
        ghostwriter.onChange = { [unowned self] in render() }
        ghostwriter.onNotice = { [unowned self] notice in show(notice) }
        bar.onEvent = { [unowned self] event in
            switch event {
            case .stop: keyTap.click(.stopClicked(.now))
            case .cancel: keyTap.click(.cancelClicked(.now))
            case .moved(let edge): preferences.change { $0.barEdge = edge }
            case .toastAction(.retryModel): engine.retry()
            case .toastAction(.openKeyboardSettings): StatusMenu.openSettings(StatusMenu.keyboardSettings)
            case .toastAction(.undoLearned): undoLearned()
            case .toastAction(.undoSetup):
                preferences.undoSetup()
                notice = nil
                render()
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
        // `Dictation setup apply` runs in another process and tells the running app what it wrote.
        setupObserver = DistributedNotificationCenter.default().addObserver(
            forName: SettingsStore.appliedNotification, object: nil, queue: .main) { [weak self] note in
            let settings = note.userInfo?["settings"] as? String, record = note.userInfo?["record"] as? String
            MainActor.assumeIsolated { self?.setupApplied(settings: settings, record: record) }
        }
        // First-run setup asks for these from its Permissions step, one at a time.
        if !preferences.needsOnboarding { Microphone.requestAccessIfNeeded() }
        keyTap.start(prompting: !preferences.needsOnboarding)
        render()
    }

    private func setupApplied(settings settingsText: String?, record recordText: String?) {
        guard let settingsText, let recordText,
              let settings = try? JSONDecoder().decode(Settings.self, from: Data(settingsText.utf8)),
              let record = try? JSONDecoder().decode(SetupRecord.self, from: Data(recordText.utf8))
        else { return }
        preferences.adopt(settings: settings, record: record)
        show(.setupApplied(by: record.by, changes: record.changes.count))
    }

    private func apply(_ old: Configuration, _ new: Configuration) {
        if old.activeVocabulary != new.activeVocabulary { vocabularyToApply = .some(new.activeVocabulary) }
        if old.settings.captureKeys != new.settings.captureKeys {
            stopPreviews()
            microphone.cancel()
            keyTap.keys = new.settings.captureKeys
        }
        for agent in old.settings.agents.agents where new.settings.agents.agent(id: agent.id)?.shellCommand != agent.shellCommand {
            agents.stop(agent.id)
        }
        keyTap.pasteLast = new.settings.pasteLast
        if !new.settings.muteWhileDictating { muter.stop() }
        render()
    }

    /// The window's shortcut recorder borrows the keyboard from dictation until it has a result.
    func recordShortcut(_ done: @escaping (ShortcutRecorder.Outcome) -> Void) { keyTap.record(done) }

    func stopRecordingShortcut() { keyTap.stopRecording() }

    /// Release path, first half, on the main turn after the tap callback. It takes the samples already
    /// converted, notes the focus, and hands off. Nothing here waits on the model or the audio engine.
    private func handle(_ commands: [CaptureCommand], cue: Cue?) {
        // Only a dictation turns into a Ghostwrite or a Hand off mid-press; nothing turns back.
        if commands.isEmpty, keyTap.machine.isCapturing, captureKind == .dictate, keyTap.kind != .dictate {
            captureKind = keyTap.kind
            toAgent = true
            ghostwriter.began(captureKind)
        }
        for command in commands {
            switch command {
            case .start:
                captureKind = keyTap.kind
                toAgent = captureKind != .dictate || ghostwriter.takesChange
                if toAgent { ghostwriter.began(captureKind) }
                fallback = nil
                words = ""
                capture += 1
                checkFix()
                preferences.reloadVocabularyIfChanged()
                do {
                    try microphone.start(from: preferences.current.settings.microphone)
                    engine.prepare()
                    readScreenNames()
                    startPreviews()
                } catch {
                    keyTap.abort()
                    endAgentCapture()
                    show(.failed(error.localizedDescription))
                }
            case .cancel:
                fallback = nil
                capture += 1
                stopPreviews()
                microphone.cancel()
                endAgentCapture()
            case .finish:
                capture += 1
                stopPreviews()
                guard let recording = microphone.stop(releasedAt: .now) else {
                    endAgentCapture()
                    break
                }
                if toAgent {
                    toAgent = false
                    ghostwriter.finished(recording)
                    break
                }
                let target = inserter.releaseTarget()
                pending += 1
                Task { await deliver(recording, to: target) }
            }
        }
        let settings = preferences.current.settings
        let sound = settings.sounds ? cue : nil
        switch cue {
        case .start:
            if notice?.outlastsNextDictation != true { notice = nil }
            showFallback()
            showFnKeySetting()
            if let sound { sounds.play(sound) }
            if settings.muteWhileDictating { muter.listen(afterCue: sound == nil ? 0 : sounds.startLength) }
        case .stop, .cancel:
            muter.stop { [sounds] in if let sound { sounds.play(sound) } }
        case nil:
            break
        }
        render()
    }

    /// A capture for the agent that ended with no recording still ends the agent's run, so it never waits on words.
    private func endAgentCapture() {
        if toAgent { ghostwriter.cancelled() }
        toAgent = false
    }

    /// Once per launch, so a user who keeps the setting is not nagged.
    private func showFnKeySetting() {
        guard notice == nil, !fnSettingMentioned, preferences.fnKeyNeedsSetting else { return }
        fnSettingMentioned = true
        show(.fnKeySetting)
    }

    private func showFallback() {
        guard let missing = fallback else { return }
        fallback = nil
        missingMicrophone.didMention(missing)
        show(.microphoneMissing(chosen: missing, using: AudioDevices.defaultInput()?.name ?? "the system default"))
    }

    /// Off the main thread, within ScreenReader's budget. Only with boosting on, since the names go to the rescorer.
    private func readScreenNames() {
        let configuration = preferences.current
        guard configuration.settings.screenNames, configuration.activeVocabulary?.terms.isEmpty == false,
              !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication,
              !PrivateApps.contains(front.bundleIdentifier)
        else { return }
        let pid = front.processIdentifier, started = Instant.now, current = capture
        let known = configuration.vocabulary.terms.map(\.text)
        Task { [weak self] in
            let names = await Task.detached(priority: .userInitiated) {
                ScreenNames.extract(ScreenReader.read(pid: pid), excluding: known)
            }.value
            guard let self, capture == current else { return }
            log.info("screen names: \(names.count) in \(Instant.now - started, format: .fixed(precision: 3)) s")
            engine.boost(screenNames: names)
        }
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
            rescore \(dictation.rescore, format: .fixed(precision: 3)), screen names \(dictation.screenTerms))
            """)
        guard !dictation.text.isEmpty else { return }
        let insertion = Insertion.make(dictation.text, app: target.app?.bundleID, configuration: preferences.current)
        last = insertion
        menu.remember(insertion.text)
        if preferences.current.settings.keepHistory { history.add(HistoryEntry(text: insertion.text, audioSeconds: recording.seconds, app: target.app)) }
        let released = recording.releasedAt
        let (outcome, pasted) = await inserter.insert(insertion, target: target, releasedAt: released,
                                                      onPaste: { [timing] at in timing.record(at - released) })
        if let pasted { watch(pasted) }
        if case .copied(let reason) = outcome {
            log.info("copied instead of pasting: \(String(describing: reason), privacy: .public)")
            show(.copied(reason))
        }
    }

    private static let fixWindow = Duration.seconds(60)

    private func watch(_ pasted: Inserter.Pasted) {
        fixSerial += 1
        let serial = fixSerial
        watchedFix = (pasted, serial)
        Task { [weak self] in
            try? await Task.sleep(for: Self.fixWindow)
            if let self, watchedFix?.serial == serial { checkFix() }
        }
    }

    /// Reads the watched field once, off the main thread, and learns the word if the user fixed one.
    private func checkFix() {
        guard let watched = watchedFix else { return }
        watchedFix = nil
        Task { [weak self] in
            guard let current = await watched.pasted.field.contents()?.value, let self else { return }
            preferences.reloadVocabularyIfChanged()
            var vocabulary = preferences.current.vocabulary
            guard preferences.current.settings.learnFixes,
                  let term = FixLearning.learn(from: watched.pasted.span, now: current, vocabulary: vocabulary, isWord: Spelling.isWord)
            else { return }
            do {
                try vocabulary.save(term, replacing: nil)
                try preferences.saveVocabulary(vocabulary)
            } catch {
                return log.error("could not learn a word: \(error.localizedDescription, privacy: .public)")
            }
            learned = term
            show(.learned(term.text))
        }
    }

    /// Takes the word out again, unless it was edited since.
    private func undoLearned() {
        guard let term = learned else { return }
        learned = nil
        preferences.reloadVocabularyIfChanged()
        var vocabulary = preferences.current.vocabulary
        vocabulary.terms.removeAll { $0 == term }
        try? preferences.saveVocabulary(vocabulary)
        notice = nil
        render()
    }

    /// Control+Command+V. The last dictation again, wherever focus is now.
    private func pasteLast() {
        guard let last else { return show(.nothingToPaste) }
        Task {
            if case .copied(let reason) = await inserter.insert(last.again, target: inserter.releaseTarget(),
                                                                 releasedAt: .now).outcome {
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

    /// Also the mute's safety net, since a capture that ended without a cue, such as a microphone failure, unmutes
    /// here, and where a waiting vocabulary change reaches the engine.
    private func render() {
        let settings = preferences.current.settings
        if !keyTap.machine.showsListening { muter.stop() }
        if case .some(let vocabulary) = vocabularyToApply, !keyTap.machine.isCapturing, pending == 0 {
            vocabularyToApply = nil
            engine.configure(vocabulary: vocabulary)
        }
        let agent = ghostwriter.bar
        keyTap.takesCardKeys = ghostwriter.isOpen
        bar.render(BarState.derive(hotkey: keyTap.machine, words: words, pending: pending, engine: engineStatus,
                                   notice: notice, showsIdle: !settings.hideBarWhenIdle, agent: agent?.agent, working: agent?.working,
                                   busy: agent?.busy ?? false),
                   edge: settings.barEdge)
        menu.show(engine: engineStatus, keyTapRunning: keyTap.isRunning, waiting: pending)
    }
}
