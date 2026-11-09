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
    private let usageCount: UsageReporter
    let updates: UpdateNotice
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
    private let formatter = SmartFormatter()
    private let learnedAlert = LearnedAlert()
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
    /// Follows the newest dictation for Learn from your fixes, until it is sent, the next dictation, or a minute later.
    private var fixWatch: Task<Void, Never>?
    /// The word the Learned notice can undo.
    private var learned: Vocabulary.Term?
    private var fnSettingMentioned = false
    /// A vocabulary change waiting for no dictation to be in flight, since the engine rebuilds its rescorer between
    /// jobs and a release would wait on it. Learning a word saves one at the start of the next capture.
    private var vocabularyToApply: Vocabulary??
    /// The live talk running now, if any. The bar reads its level through this.
    private let live = LiveTalkSlot()
    private let talkCards = TalkCardPanel()
    /// The island at the top of the screen that shows a talk.
    private let island = TalkIslandPanel()
    /// A call back ringing on the island, until it is answered, declined or missed.
    private var ringing: RingingCall?
    /// The call back whose talk is under way, until the result is said or the talk ends.
    private var callInTalk: String?
    private var callObserver: (any NSObjectProtocol)?

    init() {
        inserter = Inserter(preferences: preferences)
        usageCount = UsageCount.reporter(preferences: preferences)
        updates = UpdateNotice(UpdateCheck.checker(preferences: preferences))
        keyTap = KeyTap(keys: preferences.current.settings.captureKeys, pasteLast: preferences.current.settings.pasteLast)
        engine = SpeechEngine(vocabulary: preferences.current.activeVocabulary)
        bar = Bar(voice: { [microphone, live] in live.talk?.voiceTap ?? microphone.voice })
        menu = StatusMenu(preferences: preferences, engine: engine, inserter: inserter, updates: updates)
        agents.talkExtras = { agent in await TalkT3.extras(for: agent, secrets: Keychain()) }
        ghostwriter = Ghostwriter(preferences: preferences, history: history, inserter: inserter, engine: engine, pool: agents,
                                  usageCount: usageCount,
                                  anchor: { [bar] in bar.anchor() })
    }

    func start() {
        Task { [formatter, preferences] in
            await formatter.load(download: SettingsStore.isReal && preferences.current.settings.smartFormatting)
        }
        if SettingsStore.isReal {
            learnedAlert.onUndo = { [unowned self] term in undoLearned(term) }
            learnedAlert.start()
        }
        keyTap.onUpdate = { [unowned self] commands, cue in handle(commands, cue: cue) }
        keyTap.onPasteLast = { [unowned self] in pasteLast() }
        keyTap.onCardKey = { [unowned self] key in ghostwriter.cardKey(key) }
        keyTap.onDoubleTap = { [unowned self] in toggleTalk() }
        talkCards.onPermission = { [unowned self] allowed in live.talk?.answerPermission(allowed) }
        island.model.level = { [bar] in bar.meter.reading(at: Date.timeIntervalSinceReferenceDate).level(delay: 0) }
        island.model.onEnd = { [unowned self] in live.talk?.end(.byYou) }
        island.model.onAnswer = { [unowned self] in answerCall() }
        island.model.onDecline = { [unowned self] in endRinging(.declined) }
        island.onMoved = { [unowned self] rect in
            bar.talkAnchor = rect
            talkCards.move(under: (rect, .top))
        }
        updateTalkKey()
        ghostwriter.onChange = { [unowned self] in render() }
        ghostwriter.onNotice = { [unowned self] notice in show(notice) }
        bar.onEvent = { [unowned self] event in
            switch event {
            case .stop: keyTap.click(.stopClicked(.now))
            case .cancel: keyTap.click(.cancelClicked(.now))
            case .moved(let edge): preferences.change { $0.barEdge = edge }
            case .toastAction(.retryModel): engine.retry()
            case .toastAction(.openKeyboardSettings): StatusMenu.openSettings(StatusMenu.keyboardSettings)
            case .toastAction(.undoLearned): if let learned { undoLearned(learned) }
            case .toastAction(.undoSetup):
                preferences.undoSetup()
                notice = nil
                render()
            }
        }
        preferences.onChange = { [unowned self] old, new in apply(old, new) }
        microphone.onFailure = { [unowned self] error in
            if let talk = live.talk { return talk.end(.failed(error.localizedDescription)) }
            stopPreviews()
            keyTap.abort()
            endAgentCapture()
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
        // `Dictation call` runs in another process, often over SSH from the agent's Mac, and asks for a call back.
        callObserver = DistributedNotificationCenter.default().addObserver(
            forName: CallChannel.request, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated { if let id { self?.incomingCall(id) } }
        }
        // The checker asks GitHub at most once a day, so an app left open for weeks still hears of a new release.
        Task { [updates] in
            while !Task.isCancelled {
                await updates.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        // First-run setup asks for these from its Permissions step, one at a time.
        if !preferences.needsOnboarding { Microphone.requestAccessIfNeeded() }
        microphone.prepare(preferences.current.settings.microphone)
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
            if live.talk == nil { microphone.cancel() }
            keyTap.keys = new.settings.captureKeys
        }
        updateTalkKey()
        for agent in old.settings.agents.agents where new.settings.agents.agent(id: agent.id)?.shellCommand != agent.shellCommand {
            agents.stop(agent.id)
        }
        if old.settings.microphone != new.settings.microphone || old.settings.automaticOrder != new.settings.automaticOrder {
            microphone.prepare(new.settings.microphone)
        }
        keyTap.pasteLast = new.settings.pasteLast
        if !new.settings.muteWhileDictating { muter.stop() }
        render()
    }

    /// Double-tapping Left Control starts a talk only with the setting on and no dictation key on Left Control.
    private func updateTalkKey() {
        let settings = preferences.current.settings
        keyTap.talkKey = settings.liveTalk.enabled && LiveTalkKey.conflict(with: settings.captureKeys) == nil
    }

    /// Double-tapping Left Control: answers a call back that is ringing, starts a talk, or ends the one running.
    private func toggleTalk() {
        if ringing != nil { return answerCall() }
        if let talk = live.talk { return talk.end(.byYou) }
        let settings = preferences.current.settings
        guard settings.liveTalk.enabled, !keyTap.machine.isCapturing else { return }
        guard let agent = settings.liveTalk.agent(in: settings.agents) else {
            return show(.talkFailed("Set up an agent in Settings > Ghostwrite to talk with it."))
        }
        startTalk(with: agent)
    }

    private func startTalk(with agent: AgentConnection, opening: TalkOpening? = nil) {
        let settings = preferences.current.settings
        let talk = Talk(agent: agent, pool: agents, engine: engine, voice: Voices.provider(for: settings.liveTalk.voice),
                        input: MicTalkInput(microphone, choice: settings.microphone), speaker: SpeakerOut(), opening: opening)
        let barAgent = BarAgent(initial: agent.initial, name: agent.name)
        talk.onBar = { [unowned self] _ in render() }
        talk.onNotice = { [unowned self] notice in show(notice) }
        talk.onCard = { [unowned self] event in talkCards.handle(event, agent: barAgent, under: (island.islandRect, .top)) }
        talk.onOpening = { [unowned self] said in
            guard let id = callInTalk else { return }
            callInTalk = nil
            CallChannel.post(CallbackUpdate(id: id, status: said ? .delivered : .failed,
                                            detail: said ? nil : "\(agent.name) couldn't say the result"))
        }
        talk.onEnd = { [unowned self, weak talk] reason in
            guard let talk, live.talk === talk else { return }
            live.talk = nil
            if let id = callInTalk {
                callInTalk = nil
                let detail = if case .failed(let why) = reason { why } else { "the talk ended before the result was said" }
                CallChannel.post(CallbackUpdate(id: id, status: .hungUp, detail: detail))
            }
            keyTap.suspended = false
            talkCards.dropPermissions()
            microphone.prepare(preferences.current.settings.microphone)
            if preferences.current.settings.sounds { sounds.play(.stop) }
            switch reason {
            case .failed(let why): show(.talkFailed(why))
            case .quiet, .goodbye, .byYou:
                if case .talkStarted = notice { notice = nil }
                if case .talkEndingSoon = notice { notice = nil }
                render()
            }
        }
        stopPreviews()
        fixWatch?.cancel()
        live.talk = talk
        keyTap.suspended = true
        if settings.sounds { sounds.play(.start) }
        show(.talkStarted(agent: agent.name))
        talk.start()
    }

    // MARK: Call back

    /// `Dictation call` asked for a call back. It rings unless you are busy, and says why when it won't.
    private func incomingCall(_ id: String) {
        guard let request = CallChannel.take(id) else {
            return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "Lip Service couldn't read the call"))
        }
        let settings = preferences.current.settings
        let agent: AgentConnection
        if let wanted = request.agent?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty {
            guard let named = settings.agents.agents.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "no agent named \(request.agent ?? "")"))
            }
            agent = named
        } else {
            guard let live = settings.liveTalk.agent(in: settings.agents) else {
                return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "no agent is set up for Live talk"))
            }
            agent = live
        }
        if let busy = CallSignals.busy(talking: live.talk != nil || ringing != nil,
                                       dictating: keyTap.machine.isCapturing || pending > 0 || toAgent) {
            log.info("call back from \(request.from, privacy: .public) not rung: \(busy.detail, privacy: .public)")
            return CallChannel.post(CallbackUpdate(id: id, status: .busy, detail: busy.detail))
        }
        log.info("call back from \(request.from, privacy: .public)")
        let call = RingingCall(request: request, agent: agent)
        ringing = call
        if request.ringSeconds <= 0 { return answerCall() }
        CallChannel.post(CallbackUpdate(id: id, status: .ringing))
        call.ring = Task { [unowned self, sounds] in
            let ends = Instant.now + request.ringSeconds
            while !Task.isCancelled, Instant.now < ends {
                sounds.play(.start)
                try? await Task.sleep(for: .milliseconds(350))
                sounds.play(.start)
                try? await Task.sleep(for: .seconds(2.5))
            }
            guard !Task.isCancelled else { return }
            endRinging(.missed)
        }
        render()
    }

    /// Double-tapping Left Control or Answer on the island: the talk starts and says the result first.
    private func answerCall() {
        guard let call = ringing else { return }
        call.ring?.cancel()
        ringing = nil
        let request = call.request
        CallChannel.post(CallbackUpdate(id: request.id, status: .answered))
        callInTalk = request.id
        startTalk(with: call.agent, opening: TalkOpening(
            greeting: CallbackPrompt.greeting(from: request.from, about: request.about),
            prompt: CallbackPrompt.opening(from: request.from, about: request.about, result: request.result)))
    }

    /// Decline on the island, or the ring ran out.
    private func endRinging(_ status: CallbackStatus) {
        guard let call = ringing else { return }
        call.ring?.cancel()
        ringing = nil
        log.info("call back \(status.rawValue, privacy: .public)")
        CallChannel.post(CallbackUpdate(id: call.request.id, status: status))
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
                fixWatch?.cancel()
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
        usageCount.used(.dictation)
        let configuration = preferences.current
        var formatted: String?
        if configuration.settings.smartFormatting, SettingsStore.isReal {
            Task { [formatter] in await formatter.load(download: true) }
        }
        if configuration.settings.smartFormatting,
           let result = await formatter.format(dictation, app: configuration.settings.profiles.group(for: target.app?.bundleID)) {
            formatted = result.text
            log.info("smart formatting \(result.seconds, format: .fixed(precision: 3)) s")
        }
        let insertion = Insertion.make(dictation.text, formatted: formatted, app: target.app?.bundleID, configuration: configuration)
        last = insertion
        menu.remember(insertion.text)
        if preferences.current.settings.keepHistory { history.add(HistoryEntry(text: insertion.text, audioSeconds: recording.seconds, app: target.app)) }
        let released = recording.releasedAt
        let outcome = await inserter.insert(insertion, target: target, releasedAt: released,
                                            onPaste: { [timing] at in timing.record(at - released) }, onLanded: watch)
        if case .copied(let reason) = outcome {
            log.info("copied instead of pasting: \(String(describing: reason), privacy: .public)")
            show(.copied(reason))
        }
    }

    private static let fixWindow = 60.0
    private static let fixPoll = Duration.milliseconds(250)
    /// Reads in a row that fail before the field counts as gone, such as a window that closed on send.
    private static let fixMisses = 3

    private func watch(_ pasted: Inserter.Pasted) {
        fixWatch?.cancel()
        fixWatch = Task { [weak self] in
            let start = Instant.now
            var watch = FixWatch(span: pasted.span, at: 0)
            var misses = 0, ended = "timed out"
            while Instant.now - start < Self.fixWindow {
                try? await Task.sleep(for: Self.fixPoll)
                if Task.isCancelled { ended = "next dictation"; break }
                guard let value = await pasted.field.contents()?.value else {
                    misses += 1
                    if misses == Self.fixMisses { ended = "field gone"; break }
                    continue
                }
                misses = 0
                if !watch.read(value, at: Instant.now - start) { ended = "field emptied"; break }
            }
            self?.learn(from: watch, ended: ended)
        }
    }

    private func learn(from watch: FixWatch, ended: String) {
        preferences.reloadVocabularyIfChanged()
        var vocabulary = preferences.current.vocabulary
        guard preferences.current.settings.learnFixes else { return }
        guard let term = FixLearning.learn(from: watch.span, now: watch.settled, vocabulary: vocabulary, isWord: Spelling.isWord) else {
            let found = watch.settled == watch.span.value ? "no settled edit"
                : FixLearning.fix(of: watch.span, now: watch.settled) == nil ? "not a one-word fix" : "word not learnable"
            return log.info("fix watch ended, \(ended, privacy: .public): \(found, privacy: .public)")
        }
        do {
            try vocabulary.save(term, replacing: nil)
            try preferences.saveVocabulary(vocabulary)
        } catch {
            return log.error("could not learn a word: \(error.localizedDescription, privacy: .public)")
        }
        log.info("fix watch ended, \(ended, privacy: .public): learned a word")
        learned = term
        show(.learned(term.text))
        if SettingsStore.isReal { learnedAlert.show(term) }
    }

    /// Takes the word out again, unless it was edited since.
    private func undoLearned(_ term: Vocabulary.Term) {
        if learned == term { learned = nil }
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
                                                                 releasedAt: .now) {
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
                                   busy: agent?.busy ?? false, talk: live.talk?.bar),
                   edge: settings.barEdge)
        island.show(live.talk?.bar ?? ringing?.bar)
        menu.show(engine: engineStatus, keyTapRunning: keyTap.isRunning, waiting: pending)
    }
}

/// A call back that is ringing, and the agent its talk goes to.
@MainActor final class RingingCall {
    let request: CallbackRequest
    let agent: AgentConnection
    var ring: Task<Void, Never>?

    init(request: CallbackRequest, agent: AgentConnection) { (self.request, self.agent) = (request, agent) }

    var bar: TalkBar {
        TalkBar(agent: BarAgent(initial: agent.initial, name: request.from), phase: .ringing, line: CallbackPrompt.cleanAbout(request.about))
    }
}

/// Holds the running talk for the bar's level, which is set up before the coordinator is.
@MainActor final class LiveTalkSlot {
    var talk: Talk?
}
