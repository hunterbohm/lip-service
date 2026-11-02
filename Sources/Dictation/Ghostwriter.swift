import AppKit
import Carbon.HIToolbox
import DictationCore
import os

/// Runs Ghostwrite and Hand off: reads the window at key-down, warms the agent while the user talks, turns the
/// release into a draft or a task, and owns the card until it closes. The card states live in DictationCore; this
/// carries out their effects.
@MainActor final class Ghostwriter {
    /// After every change the bar or the card may show.
    var onChange: (() -> Void)?
    var onNotice: ((BarNotice) -> Void)?

    private let preferences: Preferences
    private let history: HistoryStore
    private let inserter: Inserter
    private let engine: SpeechEngine
    let pool: AgentPool
    private let panel = CardPanel()
    private let anchor: () -> (frame: NSRect, edge: BarEdge)
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "ghostwrite")

    /// One request from key-down to the card closing.
    @MainActor private final class Run {
        let kind: CaptureKind
        var agent: AgentConnection
        /// The app and field the user was in at key-down, where a draft goes.
        let target: FocusTarget
        let context: Task<WindowContext, Never>
        var draft: DraftCard?
        var handOff: HandOffCard?
        var session: (client: ACPClient, id: String)?
        var prompt: Task<Void, Never>?
        /// The agent's questions still waiting for an answer. An agent can ask a second before the first is answered.
        var permissions: [(request: PermissionRequest, answer: CheckedContinuation<String?, Never>)] = []

        func answer(_ request: PermissionRequest, with optionID: String?) {
            guard let index = permissions.firstIndex(where: { $0.request.isSameQuestion(as: request) }) else { return }
            permissions.remove(at: index).answer.resume(returning: optionID)
        }

        func declineAll() {
            for waiting in permissions { waiting.answer.resume(returning: nil) }
            permissions = []
        }
        var timer: Timer?
        var words = ""
        /// The release of the latest request, for the timing log.
        var releasedAt: Instant?
        var shownFirstText = false
        /// Whether the field at key-down takes typing. Return checks again before it types.
        var takesText = true
        /// The window text once its read finished, for the card to show without waiting.
        var windowText: WindowContext?
        /// Counts the draft's requests, so a request that was replaced cannot reach the card.
        var turn = 0

        init(kind: CaptureKind, agent: AgentConnection, target: FocusTarget, context: Task<WindowContext, Never>) {
            (self.kind, self.agent, self.target, self.context) = (kind, agent, target, context)
        }
    }

    private var run: Run?
    /// A capture that began while a draft was open, speaking a change to it.
    private var changing = false

    init(preferences: Preferences, history: HistoryStore, inserter: Inserter, engine: SpeechEngine, pool: AgentPool,
         anchor: @escaping () -> (frame: NSRect, edge: BarEdge)) {
        (self.preferences, self.history, self.inserter, self.engine, self.pool, self.anchor) = (preferences, history, inserter, engine, pool, anchor)
        panel.onAction = { [unowned self] action in
            switch action {
            case .key(let key): _ = handleKey(key, clicked: true)
            case .copy: copyWords()
            case .retry: _ = handleKey(.returnKey, clicked: true)
            case .pick(let project): handOffEvent(.pick(project))
            }
        }
    }

    private var settings: AgentSettings { preferences.current.settings.agents }

    /// Whether fn or the Ghostwrite key held now speaks a change to the open draft.
    var takesChange: Bool {
        guard let run, let draft = run.draft else { return false }
        return draft.takesChange(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, target: run.target.pid)
    }

    var isOpen: Bool { run != nil }

    /// Who the bar names while this capture runs, what it says once the user let go, and whether something is under way
    /// rather than waiting on the user.
    var bar: (agent: BarAgent, working: String?, busy: Bool)? {
        guard let run else { return nil }
        let agent = BarAgent(initial: run.agent.initial, name: run.agent.name)
        if let draft = run.draft {
            switch draft.phase {
            case .listening: return (agent, nil, true)
            case .transcribing, .thinking: return (agent, "\(run.agent.name) is writing…", true)
            case .streaming: return (agent, draft.typesDirectly ? "\(run.agent.name) is writing…" : "Writing", true)
            case .ready: return (agent, "Ready", false)
            case .permission: return (agent, "\(run.agent.name) is asking", false)
            case .failed: return (agent, "Didn't finish", false)
            case .typed, .copied, .discarded: return nil
            }
        }
        guard let card = run.handOff else { return (agent, run.words.isEmpty && changing ? nil : "Writing it down…", true) }
        return switch card.phase {
        case .picking: (agent, "Waiting for you", false)
        case .sent, .replied: (agent, "Nothing typed", false)
        case .failed: (agent, "Didn't finish", false)
        case .cancelled: nil
        default: (agent, "Sending to \(run.agent.name)…", true)
        }
    }

    // MARK: Capture

    /// Key-down of the Ghostwrite or Hand off key, or fn re-targeted to one. Reads the window off the main thread while
    /// the user talks and warms the agent for a draft. With a draft open, the hold speaks a change instead.
    func began(_ kind: CaptureKind) {
        // fn held over a draft and then turned into the Ghostwrite key is still the same change.
        if changing, kind != .handOff { return }
        if kind != .handOff, takesChange, let run {
            changing = true
            event(.listen, in: run)
            return
        }
        close()
        guard let agent = settings.current else {
            onNotice?(.failed("Set up an agent on the Ghostwrite page first."))
            return
        }
        let target = inserter.releaseTarget()
        let run = Run(kind: kind, agent: agent, target: target, context: Self.readWindow(target))
        if kind == .ghostwrite {
            run.draft = DraftCard(typesDirectly: !settings.reviewFirst)
            pool.prepare(agent)
        }
        self.run = run
        let field = target.element.map(Field.init)
        Task {
            let context = await run.context.value
            let takesText = await Task.detached { field?.takesText(until: .now + 0.15) ?? false }.value
            guard self.run === run else { return }
            run.windowText = context
            run.takesText = takesText
            refresh()
        }
        onChange?()
    }

    /// The key went up. The words are transcribed by the same engine as dictation, then go to the agent.
    func finished(_ recording: Recording) {
        guard let run else { return }
        let changing = self.changing
        self.changing = false
        run.releasedAt = recording.releasedAt
        run.shownFirstText = false
        if run.draft != nil { event(.released, in: run) }
        Task {
            let words: String
            do {
                words = try await engine.dictate(recording).text
            } catch {
                let reason = "Transcription failed: \(error.localizedDescription)"
                // A change that couldn't be transcribed is dropped, and the draft it was said over stays usable.
                if changing, run.draft != nil, self.run === run {
                    event(.cancelled, in: run)
                    onNotice?(.failed(reason))
                    return
                }
                return fail(reason, in: run)
            }
            guard self.run === run else { return }
            var said = words
            if !changing, let routed = SpokenRouting.route(words, agents: settings.agents) {
                run.agent = routed.agent
                said = routed.words
                if run.kind == .ghostwrite { pool.prepare(routed.agent) }
            }
            if !changing { run.words = said }
            log.info("ghostwrite heard \(said.count) characters from \(recording.seconds, format: .fixed(precision: 1)) s of audio, release to words \(Instant.now - recording.releasedAt, format: .fixed(precision: 3)) s")
            if run.draft != nil {
                event(.heard(said), in: run)
            } else {
                startHandOff(run, words: said)
            }
        }
    }

    /// The capture ended without a recording: a chord, Escape while hands-free, a press too short, or a microphone
    /// that failed to start. A change goes back to the draft; a new request ends.
    func cancelled() {
        guard let run else { return }
        changing = false
        if run.draft != nil {
            event(.cancelled, in: run)
        } else if run.handOff == nil {
            close()
        }
    }

    /// A key while the card is open and no capture runs. Taken only while the app the user started in is in front,
    /// so switching away hands the keyboard back; the card still works by click.
    func cardKey(_ key: CardKey) -> Bool { handleKey(key, clicked: false) }

    private func handleKey(_ key: CardKey, clicked: Bool) -> Bool {
        guard let run else { return false }
        if !clicked, NSWorkspace.shared.frontmostApplication?.processIdentifier != run.target.pid { return false }
        if let draft = run.draft {
            // A click on an answer is deliberate, so it does not wait out the question's read delay.
            if clicked, case .number(let number) = key, case .permission(let prompt, _) = draft.phase,
               prompt.request.options.indices.contains(number - 1) {
                event(.answered(prompt.request.options[number - 1].id), in: run)
                return true
            }
            guard draft.takes(key, at: .now) else { return false }
            event(.key(key), in: run)
            return true
        }
        guard let card = run.handOff, card.takes(key) else { return false }
        handOffEvent(.key(key))
        return true
    }

    // MARK: Draft

    private func event(_ event: DraftCard.Event, in run: Run) {
        guard self.run === run, var card = run.draft else { return }
        let effects = card.handle(event)
        run.draft = card
        for effect in effects { perform(effect, in: run) }
        refresh()
        if let released = run.releasedAt {
            if case .chunk = event, !run.shownFirstText {
                run.shownFirstText = true
                log.info("ghostwrite release to first text \(Instant.now - released, format: .fixed(precision: 3)) s")
            }
            if event == .finished {
                log.info("ghostwrite release to draft done \(Instant.now - released, format: .fixed(precision: 3)) s, \(card.text?.count ?? 0) characters")
            }
        }
        if !card.isOpen { finish(run) }
    }

    private func perform(_ effect: DraftCard.Effect, in run: Run) {
        switch effect {
        case .send(let words, let isChange):
            run.prompt?.cancel()
            run.turn += 1
            let turn = run.turn
            run.prompt = Task { await self.send(words, isChange: isChange, turn: turn, in: run) }
        case .answer(let request, let optionID):
            run.answer(request, with: optionID)
        case .type(let text):
            Task { await self.type(text, in: run) }
        case .copy(let text):
            inserter.copy(text)
            onNotice?(.copied(.focusMoved))
        case .cancel:
            run.prompt?.cancel()
            if let session = run.session { Task { await session.client.cancel(session: session.id) } }
            run.declineAll()
        }
    }

    private func send(_ words: String, isChange: Bool, turn: Int, in run: Run) async {
        let started = Instant.now
        do {
            let text: String
            if isChange, run.session != nil {
                text = GhostwriteRequest.change(words)
            } else {
                let context = await run.context.value
                let configuration = preferences.current
                let examples = configuration.settings.agents.voiceExamples
                    ? VoiceExamples.pick(from: history.entries, for: run.target.app?.bundleID, profiles: configuration.settings.profiles) : []
                text = GhostwriteRequest(words: words, context: context, voiceExamples: examples,
                                         voiceNotes: configuration.settings.agents.voiceNotes).prompt
                let session = try await pool.draftSession(run.agent)
                run.session = (session.0, session.1)
            }
            guard let session = run.session, !Task.isCancelled else { return }
            let first = Once()
            _ = try await session.client.prompt(text, session: session.id, timeout: 120, onUpdate: { [weak self] update in
                guard case .message(let chunk) = update else { return }
                Task { @MainActor in
                    guard run.turn == turn else { return }
                    if first.claim() { self?.log.info("ghostwrite first text \(Instant.now - started, format: .fixed(precision: 3)) s after send") }
                    self?.event(.chunk(chunk), in: run)
                }
            }, onPermission: { [weak self] request in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        guard let self, self.run === run, run.turn == turn else { return continuation.resume(returning: request.rejection?.id) }
                        run.permissions.append((request, continuation))
                        self.event(.asked(PermissionPrompt(request)), in: run)
                    }
                }
            })
            guard !Task.isCancelled, run.turn == turn else { return }
            // Chunks hop to the main actor one by one, so the finish goes behind them.
            await Task.yield()
            log.info("ghostwrite done \(Instant.now - started, format: .fixed(precision: 3)) s after send")
            event(.finished, in: run)
        } catch is SessionRetired where isChange {
            guard !Task.isCancelled, run.turn == turn else { return }
            run.session = nil
            await send(run.draft?.words ?? words, isChange: false, turn: turn, in: run)
        } catch {
            guard !Task.isCancelled, run.turn == turn else { return }
            fail(Self.unreachable(run.agent.name, error), in: run)
        }
    }

    private static func unreachable(_ name: String, _ error: any Error) -> String {
        let reason = error.localizedDescription
        return reason.hasPrefix(name) ? reason : "\(name) couldn't be reached: \(reason)"
    }

    private func fail(_ reason: String, in run: Run) {
        guard self.run === run else { return }
        if run.draft != nil { return event(.failed(reason), in: run) }
        // A hand-off can fail before its card opens, such as when transcription fails, and the card is where it says why.
        if run.handOff == nil {
            run.handOff = HandOffCard(words: run.words, destination: run.agent.destination.title(agent: run.agent.name),
                                      picksProject: false, now: .now)
        }
        handOffEvent(.failed(reason))
    }

    /// Return: back into the field the user started in, checked as Press Return checks it. No field there, or focus
    /// moved, and it is copied instead, with the bar saying so.
    private func type(_ text: String, in run: Run) async {
        record(text, kind: .ghostwrite(agent: run.agent.name), app: run.target.app)
        let takesText = run.target.element.map { Field($0).takesText(until: .now + 0.15) } ?? false
        guard takesText else {
            inserter.copy(text)
            onNotice?(.copied(.noTextField))
            return
        }
        let insertion = Insertion(text: text, source: .agentDraft)
        if case .copied(let reason) = await inserter.insert(insertion, target: run.target, releasedAt: .now).outcome {
            onNotice?(.copied(reason))
        }
    }

    private func copyWords() {
        guard let run else { return }
        if run.draft != nil {
            event(.copy, in: run)
        } else if case .replied(let text, _) = run.handOff?.phase {
            inserter.copy(text)
            onNotice?(.copied(.focusMoved))
            close()
        } else {
            inserter.copy(run.words)
            onNotice?(.copied(.focusMoved))
            close()
        }
    }

    // MARK: Hand off

    private func startHandOff(_ run: Run, words: String) {
        guard !words.isEmpty else { return close() }
        let destination = run.agent.destination
        run.handOff = HandOffCard(words: words, destination: destination.title(agent: run.agent.name),
                                  picksProject: destination.kind == .t3Code, now: .now)
        afterHandOffChange(run)
        refresh()
    }

    private func handOffEvent(_ event: HandOffCard.Event) {
        guard let run, var card = run.handOff else { return }
        let effects = card.handle(event)
        run.handOff = card
        for effect in effects {
            switch effect {
            case .send(let project): Task { await self.deliver(run, project: project) }
            case .cancel: log.info("hand-off cancelled, nothing sent")
            }
        }
        afterHandOffChange(run)
        refresh()
        if !card.isOpen { close() }
    }

    /// Starts what the new phase waits on: the countdown's tick, or the T3 Code projects.
    private func afterHandOffChange(_ run: Run) {
        run.timer?.invalidate()
        run.timer = nil
        guard let card = run.handOff else { return }
        switch card.phase {
        case .confirming(let until):
            let timer = Timer(timeInterval: max(0, until - .now), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handOffEvent(.tick(.now)) }
            }
            RunLoop.main.add(timer, forMode: .common)
            run.timer = timer
        case .loadingProjects:
            guard case .t3Code(let t3) = run.agent.destination else { return }
            Task {
                do {
                    let projects = try await T3Client(destination: t3, secrets: Keychain()).projects()
                    if self.run === run { handOffEvent(.projects(projects)) }
                } catch {
                    if self.run === run { handOffEvent(.failed(error.localizedDescription)) }
                }
            }
        case .sent:
            let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.run === run { self?.close() } }
            }
            RunLoop.main.add(timer, forMode: .common)
            run.timer = timer
        default:
            break
        }
    }

    private func deliver(_ run: Run, project: HandOffCard.Project?) async {
        let context = await run.context.value
        let request = HandOffRequest(words: run.words, context: context)
        let handoff = HandOffContext(agent: run.agent, includeWindowText: settings.includeWindowText,
                                     dryRun: ProcessInfo.processInfo.environment["LS_HANDOFF_DRY_RUN"] == "1", secrets: Keychain(),
                                     project: project, pool: pool, onChunk: { [weak self] text in
                                         Task { @MainActor in if self?.run === run { self?.handOffEvent(.chunk(text)) } }
                                     })
        do {
            let note = try await run.agent.destination.sender.send(request, handoff)
            record(run.words, kind: .handOff(agent: run.agent.name, destination: run.agent.destination.kind.title), app: run.target.app)
            await Task.yield()
            if self.run === run { handOffEvent(.sent(note: note)) }
        } catch {
            if self.run === run { handOffEvent(.failed(error.localizedDescription)) }
        }
    }

    // MARK: Shared

    private func record(_ text: String, kind: HistoryKind, app: HistoryApp?) {
        guard preferences.current.settings.keepHistory else { return }
        history.add(HistoryEntry(text: text, audioSeconds: nil, app: app, kind: kind))
    }

    private func finish(_ run: Run) {
        guard self.run === run else { return }
        close()
    }

    private func close() {
        if let run {
            run.prompt?.cancel()
            if let session = run.session { Task { await session.client.cancel(session: session.id) } }
            run.declineAll()
            run.timer?.invalidate()
        }
        run = nil
        changing = false
        panel.hide()
        onChange?()
    }

    /// Shows the card when its state says to, above wherever the bar is.
    func refresh() {
        guard let run, let model = model(for: run) else {
            panel.hide()
            onChange?()
            return
        }
        onChange?()
        panel.show(model, above: anchor())
    }

    private func model(for run: Run) -> CardModel? {
        let agent = BarAgent(initial: run.agent.initial, name: run.agent.name)
        let keysLive = NSWorkspace.shared.frontmostApplication?.processIdentifier == run.target.pid
        let changeKey = preferences.current.settings.ghostwriteKey?.title ?? "fn"
        let context = run.windowText
        if let draft = run.draft {
            guard draft.showsCard else { return nil }
            let target = run.target.app?.name
            let heading = switch draft.phase {
            case .permission: "\(run.agent.name) asks"
            case .failed: run.agent.name
            default: "\(run.agent.name) · draft" + (context?.windowTitle.map { " for \($0)" } ?? target.map { " for \($0)" } ?? "")
            }
            return CardModel(agent: agent, heading: heading, content: .draft(draft), changeKey: changeKey, keysLive: keysLive,
                             returnTypes: run.takesText)
        }
        guard let card = run.handOff else { return nil }
        return CardModel(agent: agent, heading: run.agent.name, content: .handOff(card), changeKey: changeKey,
                         keysLive: keysLive)
    }

    /// The window at key-down, off the main thread, within 0.15 s. Nothing is read in a private app or under secure input.
    private static func readWindow(_ target: FocusTarget) -> Task<WindowContext, Never> {
        let app = target.app, pid = target.pid
        guard target.isReadable, !IsSecureEventInputEnabled(), let pid else {
            return Task { WindowContext(app: app, withheld: true) }
        }
        return Task.detached(priority: .userInitiated) {
            let started = Instant.now
            let texts = ScreenReader.read(pid: pid, budget: ScreenReader.agentBudget, maxNodes: ScreenReader.agentNodes)
            let context = WindowContext.from(texts, app: app, selectedText: ScreenReader.selectedText(pid: pid))
            Logger(subsystem: "com.hunterbohm.dictation", category: "ghostwrite")
                .info("window read: \(texts.count) texts in \(Instant.now - started, format: .fixed(precision: 3)) s")
            return context
        }
    }
}

/// True for the first caller only, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
