import DictationCore
import Foundation
import os
import Synchronization

/// Where a talk hears you from: the microphone, or, for the end-to-end test, WAV clips played in real time.
@MainActor protocol TalkInput: AnyObject {
    func start() throws
    /// The 16 kHz samples that arrived since the last read.
    func read() -> [Float]
    /// What the bar's waves and the island read your voice from. Nil when nothing is measured, as for clips.
    var voice: VoiceTap? { get }
    func stop()
}

/// The shared microphone, which dictation can't use while a talk runs.
@MainActor final class MicTalkInput: TalkInput {
    private let microphone: Microphone
    private let choice: MicrophoneChoice

    init(_ microphone: Microphone, choice: MicrophoneChoice) { (self.microphone, self.choice) = (microphone, choice) }

    func start() throws { try microphone.start(from: choice) }
    func read() -> [Float] { microphone.drain() }
    var voice: VoiceTap? { microphone.voice }
    func stop() { microphone.cancel() }
}

/// Clips played one at a time, in real time, with silence between: each clip starts when `next()` is called.
@MainActor final class ClipInput: TalkInput {
    private var clips: [[Float]]
    private var playing: [Float] = []
    private var position = 0
    private var last: Instant?
    var voice: VoiceTap? { nil }

    init(clips: [[Float]]) { self.clips = clips }

    var remaining: Int { clips.count }

    func start() throws { last = .now }

    /// Starts the next clip. False when none is left.
    func next() -> Bool {
        guard !clips.isEmpty else { return false }
        playing = clips.removeFirst()
        position = 0
        return true
    }

    func read() -> [Float] {
        let now = Instant.now
        defer { last = now }
        guard let last else { return [] }
        let count = Int((now - last) * Recording.sampleRate)
        var out = [Float](repeating: 0, count: count)
        let take = min(count, playing.count - position)
        if take > 0 {
            out.replaceSubrange(0..<take, with: playing[position..<position + take])
            position += take
        }
        return out
    }

    func stop() { last = nil }
}

/// Your words in the turn under way, for the live preview.
final class TurnAudio: LiveAudio {
    private let samples = Mutex<[Float]>([])
    var count: Int { samples.withLock { $0.count } }
    func samples(_ range: Range<Int>) -> [Float] { samples.withLock { Array($0[range.clamped(to: 0..<$0.count)]) } }
    func reset(_ start: [Float]) { samples.withLock { $0 = start } }
    func append(_ block: [Float]) { samples.withLock { $0 += block } }
}

/// What the cards next to the bar show for a talk.
enum TalkCardEvent {
    case show(ShowCard)
    /// The agent asks to use a tool. Allow or Deny on the card answers it, and so does a spoken no, or a spoken yes when
    /// `byVoice`.
    case permission(agent: String, phrase: String, detail: String, byVoice: Bool)
    case permissionAnswered
    /// A result the island draws itself: flights, tasks, meetings, emails.
    case result(RichCard)
    /// The agent set up a call back for a job that takes a while, so you can hang up.
    case callBackPromised(agent: String)
    /// The agent is done with what it showed: every card and note it put up goes.
    case clear
}

/// One finished turn, for the log and the end-to-end test.
struct TalkTurnReport {
    var words: String
    var reply: String
    var tools: [String]
    var cards: Int
    var clock: TurnClock
    var failed: String?
}

/// How a call back starts its talk: the voice on this Mac says `greeting` at once, and once it has played and the
/// session is open, `prompt` goes to the agent as the first turn, so the agent's first words are the result.
struct TalkOpening {
    var greeting: String
    var prompt: String
}

/// How a talk ended.
enum TalkEnd: Equatable {
    case byYou
    case goodbye
    /// The agent said it will call back and started the job: nothing is left to wait for on the line.
    case callBack
    case quiet
    case failed(String)
}

/// One live talk: listens, sends each turn to the agent in one session, says the reply as it arrives, and shows what
/// the agent puts in `<show>`. Runs on main; each 30 ms tick reads what the microphone heard since the last.
@MainActor final class Talk {
    let agent: AgentConnection
    private let pool: AgentPool
    private let engine: SpeechEngine
    private let voice: any VoiceProvider
    private let input: any TalkInput
    private let speaker: any TalkSpeaker
    private let log = Logger(subsystem: "com.hunterbohm.dictation", category: "talk")

    var onBar: ((TalkBar) -> Void)?
    var onCard: ((TalkCardEvent) -> Void)?
    var onNotice: ((BarNotice) -> Void)?
    var onTurn: ((TalkTurnReport) -> Void)?
    /// You are listening and the agent's turn is over, so the next words are yours.
    var onListening: (() -> Void)?
    var onEnd: ((TalkEnd) -> Void)?
    /// A call back's opening was said: true once the agent's first reply played to the end or you talked over it, false
    /// when that turn failed. Called at most once; a talk that ends before then never calls it.
    var onOpening: ((Bool) -> Void)?
    /// The session the talk went to, once it is open.
    private(set) var sessionID: String?

    private(set) var bar: TalkBar {
        didSet {
            // Setting it here doesn't run this again. Every bar carries the step behind its activity, so no place that
            // builds one has to.
            let full = withSteps(bar)
            if full != bar { bar = full }
            if bar != oldValue { onBar?(bar) }
        }
    }
    private var ear: TalkEar
    private var pending: [Float] = []
    private var ticker: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var client: ACPClient?
    private var connected = false
    /// A turn you finished before the agent was ready.
    private var waitingTurn: TalkUtterance?
    private let words = TurnAudio()
    private var previews: Task<Void, Never>?
    /// Your words up to a pause, being transcribed while the pause may still end the turn. `speechEnd` is the end of
    /// the last words it heard.
    private var early: (speechEnd: Instant, text: Task<String, any Error>)?
    private var transcribing: Task<Void, Never>?
    private(set) var ended = false

    // The agent's turn.
    private var turn = 0
    private var prompting: Task<Void, Never>?
    private var splitter = ShowSplitter()
    private var chunker = SpeechChunker()
    private var announcer = ToolAnnouncer()
    /// Each tool the agent starts shows on the island, held long enough to read before the next replaces it.
    private var steps = StepQueue()
    private var stepTimer: Task<Void, Never>?
    /// When your turn went to the agent, for the island's timer until a step shows.
    private var workingSince: Instant?
    /// Tool calls that set up a call back, until they finish and the island can say so.
    private var promised: Set<String> = []
    /// This turn's reply set up a call back, so the talk hangs up once the reply has played.
    private var callingBack = false
    private var choosing: Task<Void, Never>?
    private var clock: TurnClock?
    private var report: TalkTurnReport?
    private var replyDone = false
    private var lines: AsyncStream<Line>.Continuation?
    private var speaking: Task<Void, Never>?
    /// Says a finished sentence when the agent pauses after it, instead of waiting for the space after it.
    private var flush: Task<Void, Never>?
    /// Counts the reply's text, so a flush knows whether more came meanwhile.
    private var textCount = 0
    private var permission: (request: PermissionRequest, answer: CheckedContinuation<String?, Never>, turn: Int, byVoice: Bool)?
    private var permissionTimeout: Task<Void, Never>?
    /// What this talk's session carries beyond the agent's own settings, such as T3 Code's tools.
    private var extras: TalkExtras?
    /// A call back's opening, until its prompt is sent.
    private var opening: TalkOpening?
    /// The greeting is still to finish playing.
    private var greeting = false
    /// The turn that carries the opening, until it is said.
    private var openingTurn: Int?
    /// Some of the agent's reply to the opening has played, not only a tool line.
    private var openingHeard = false
    /// A line of the reply to the opening couldn't be voiced, so part of the result may be missing: not said.
    private var openingLost = false
    /// Until then the opening can't be talked over or superseded: a "hello" after the greeting would cancel the result.
    private var openingPending: Bool { opening != nil || (openingTurn != nil && !openingHeard) }

    private struct Line {
        var turn: Int
        var text: String
        /// The reply's last line, which plays nothing.
        var end = false
        /// Counts the lines queued, so a cut-in can drop the ones queued before it.
        var number = 0
    }
    private var queuedLines = 0
    /// Lines up to this number are not said: you talked over them while the agent waited on a permission.
    private var hushedThrough = 0
    /// Counts your turns, so a transcription that finishes after you started the next one is dropped.
    private var utterances = 0

    init(agent: AgentConnection, pool: AgentPool, engine: SpeechEngine, voice: any VoiceProvider, input: any TalkInput,
         speaker: any TalkSpeaker, opening: TalkOpening? = nil, cue: Double = 0) {
        (self.agent, self.pool, self.engine, self.voice, self.input, self.speaker) = (agent, pool, engine, voice, input, speaker)
        ear = TalkEar(cue: cue)
        self.opening = opening
        bar = TalkBar(agent: BarAgent(initial: agent.initial, name: agent.name), phase: .connecting)
    }

    /// The voice the bar's meter shows: the agent's while it talks, yours otherwise.
    var voiceTap: VoiceTap? { bar.phase == .speaking ? speaker.voice : input.voice }

    /// Your microphone is muted for the talk: nothing you say reaches the agent until you unmute. The agent's own turn
    /// goes on, and its voice still plays.
    private(set) var muted = false

    /// Mutes or unmutes your microphone, from the island's button or its shortcut. Muting drops a turn of yours under
    /// way, so what you said after deciding to mute never goes to the agent.
    func setMuted(_ on: Bool) {
        guard !ended, on != muted else { return }
        muted = on
        log.info("talk \(on ? "muted" : "unmuted", privacy: .public)")
        if on {
            if ear.muted(at: .now) { handle(.dropped, at: .now) }
            bar.endingSoon = false
        } else {
            // What the microphone heard while muted, and not yet read, is thrown away too.
            _ = input.read()
            pending.removeAll()
            ear.unmuted(at: .now)
        }
        refreshBar()
    }


    func start() {
        do {
            try speaker.start()
            try input.start()
        } catch {
            return end(.failed(error.localizedDescription))
        }
        speaker.onStarted = { [weak self] caption in self?.started(caption) }
        speaker.onIdle = { [weak self] in self?.idle() }
        engine.prepare()
        let (stream, continuation) = AsyncStream.makeStream(of: Line.self)
        lines = continuation
        speaking = Task { [weak self] in
            for await line in stream {
                guard let self, !self.ended else { return }
                await self.say(line)
            }
        }
        if let opening {
            greeting = true
            queue(opening.greeting, turn: turn)
        }
        connecting = Task { [weak self] in await self?.connect() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !self.ended else { return }
                self.tick()
            }
        }
    }

    private func connect() async {
        let agent = self.agent, pool = self.pool, voice = self.voice
        async let session = pool.talkSession(agent)
        async let ready: Void = voice.prepare()
        do {
            let (client, id, extras, continued) = try await session
            try await ready
            guard !ended else { return }
            (self.client, sessionID, self.extras, connected) = (client, id, extras, true)
            log.info("talk with \(agent.name, privacy: .public) in \(continued ? "the earlier" : "a new", privacy: .public) session \(id, privacy: .public)")
            if opening != nil {
                if !greeting { sendOpening() }
            } else if let waitingTurn {
                self.waitingTurn = nil
                transcribe(waitingTurn)
            } else if bar.phase == .connecting {
                bar = TalkBar(agent: bar.agent, phase: .listening)
                onListening?()
            }
        } catch {
            _ = try? await ready
            guard !ended else { return }
            end(.failed(error.localizedDescription))
        }
    }

    /// Ends the talk, from the key, the close button, a goodbye, the quiet or a failure.
    func end(_ reason: TalkEnd) {
        guard !ended else { return }
        ended = true
        log.info("talk ended: \(String(describing: reason), privacy: .public)")
        ticker?.cancel()
        connecting?.cancel()
        previews?.cancel()
        transcribing?.cancel()
        prompting?.cancel()
        permissionTimeout?.cancel()
        if let permission {
            self.permission = nil
            permission.answer.resume(returning: permission.request.rejection?.id)
        }
        lines?.finish()
        speaking?.cancel()
        speaker.close()
        input.stop()
        if let client, let sessionID { Task { await client.cancel(session: sessionID) } }
        Task { await OnMacVoices.shared.idle() }
        onEnd?(reason)
    }

    // MARK: Hearing

    /// The levels of the agent's voice as it went to the speakers, by host time, for the last second.
    private var played: [(time: Double, level: Float)] = []
    private var playedCursor = 0
    /// How far back the agent's voice can still be heard: the speakers' and the microphone's delays, and the room's echo.
    /// Short, so what is measured as playing matches what the microphone hears now.
    private static let echoReach = 0.2

    /// The loudest the agent's voice played in the `echoReach` before host time `time`.
    private func playing(before time: Double) -> Float {
        played.reduce(0) { $1.time > time - Self.echoReach && $1.time <= time ? max($0, $1.level) : $0 }
    }

    private func tick() {
        pending += input.read()
        let host = VoiceTap.now, now = Instant.now
        if let tap = speaker.voice {
            tap.read(from: &playedCursor, until: host) { played.append(($0, $1.rms)) }
            played.removeAll { $0.time < host - 1 }
        }
        // Muted, what the microphone hears is thrown away, and the quiet that ends a talk doesn't count.
        if muted { return pending.removeAll() }
        let block = Int(ear.timing.block * Recording.sampleRate)
        while pending.count >= block {
            let samples = Array(pending.prefix(block))
            pending.removeFirst(block)
            let ago = Double(pending.count) / Recording.sampleRate
            let time = now + -ago
            let event = ear.hear(samples, at: time, playing: playing(before: host - ago))
            if ear.isHearing, event?.startsTurn != true { words.append(samples) }
            if let event { handle(event, at: time) }
            if ended { return }
        }
    }

    private func handle(_ event: TalkEar.Event, at time: Instant) {
        switch event {
        case .began:
            hearing()
        case .cutIn:
            log.info("you talked over \(self.agent.name, privacy: .public)")
            if openingPending {
                hearing()
            } else if permission == nil {
                stopReply()
            } else {
                // The question stays open for your answer, but its voice stops, so the microphone hears only you.
                hushedThrough = queuedLines
                speaker.stop()
            }
            hearing()
        case .paused(let soFar):
            // Previews would only decode the quiet again, and would hold up the worker.
            previews?.cancel()
            early?.text.cancel()
            let recording = Recording(samples: soFar.samples, releasedAt: soFar.turnEnd)
            early = (soFar.speechEnd, Task { [engine] in try await engine.dictate(recording).text })
        case .resumed:
            early = nil
            startPreviews()
        case .dropped:
            early = nil
            previews?.cancel()
            if permission != nil {
                ear.agentWorking(at: time)
                bar = TalkBar(agent: bar.agent, phase: .thinking, activity: permissionHint)
            } else {
                bar = TalkBar(agent: bar.agent, phase: connected ? .listening : .connecting)
            }
        case .ended(let utterance):
            previews?.cancel()
            // Until the result starts playing, the next words are the agent's, so what you said meanwhile is dropped.
            if openingPending {
                ear.agentWorking(at: time)
                bar = TalkBar(agent: bar.agent, phase: connected ? .thinking : .connecting, activity: "Calling back")
                return
            }
            bar = TalkBar(agent: bar.agent, phase: .thinking, line: bar.line)
            if connected { transcribe(utterance) } else { waitingTurn = utterance }
        case .idleWarning:
            bar.endingSoon = true
        case .idleEnded:
            end(.quiet)
        }
    }

    private func hearing() {
        utterances += 1
        words.reset(ear.heard)
        early = nil
        bar = TalkBar(agent: bar.agent, phase: .hearing)
        startPreviews()
    }

    private func startPreviews() {
        previews?.cancel()
        let stream = engine.previews(of: words)
        previews = Task { [weak self] in
            for await text in stream {
                guard let self, self.ear.isHearing else { continue }
                self.bar.line = Speech.collapse(text)
            }
        }
    }

    /// Uses what was transcribed at the pause when no words came after it, since the rest of the turn is quiet.
    private func transcribe(_ utterance: TalkUtterance) {
        var clock = TurnClock(speechEnd: utterance.speechEnd)
        clock.mark(.turnEnd, at: utterance.turnEnd)
        let recording = Recording(samples: utterance.samples, releasedAt: utterance.turnEnd)
        let early = self.early.flatMap { $0.speechEnd == utterance.speechEnd ? $0.text : nil }
        self.early = nil
        let current = utterances
        transcribing = Task { [weak self, engine] in
            let text: String
            do {
                if let early, let heard = try? await early.value { text = heard } else { text = try await engine.dictate(recording).text }
            } catch {
                guard let self, current == self.utterances else { return }
                self.heardNothing(failed: error.localizedDescription)
                return
            }
            guard let self, !self.ended, current == self.utterances else { return }
            clock.mark(.transcribed, at: .now)
            self.heard(Speech.collapse(text), clock: clock)
        }
    }

    private func heardNothing(failed: String? = nil) {
        guard !ended else { return }
        if let failed { log.error("talk transcription failed: \(failed, privacy: .public)") }
        if permission != nil {
            ear.agentWorking(at: .now)
            bar = TalkBar(agent: bar.agent, phase: .thinking, activity: permissionHint)
            return
        }
        ear.agentDone(at: .now)
        bar = TalkBar(agent: bar.agent, phase: .listening)
        onListening?()
    }

    private func heard(_ text: String, clock: TurnClock) {
        log.info("talk heard \(text.count) characters, \(clock.summary, privacy: .public)")
        if text.isEmpty || TalkWords.isNoise(text) { return heardNothing() }
        if TalkWords.isGoodbye(text, agentNames: [agent.name]) { return end(.goodbye) }
        if permission != nil {
            let byVoice = permission?.byVoice ?? false
            switch TalkWords.answer(text) {
            case false?: return answerPermission(false)
            case true? where byVoice: return answerPermission(true)
            case true?:
                ear.agentWorking(at: .now)
                bar = TalkBar(agent: bar.agent, phase: .thinking, line: text, activity: "Click Allow, or say no")
                return queue("For that one, click Allow on the screen.", turn: turn)
            case nil:
                ear.agentWorking(at: .now)
                bar = TalkBar(agent: bar.agent, phase: .thinking, line: text, activity: byVoice ? "Say yes or no" : "Click Allow, or say no")
                return queue(byVoice ? "Sorry, was that a yes or a no?" : "Click Allow on the screen, or say no.", turn: turn)
            }
        }
        send(text, clock: clock)
    }

    // MARK: The agent's turn

    /// Sends a call back's result as the first turn, once the greeting has played and the session is open.
    private func sendOpening() {
        guard connected, !greeting, let opening else { return }
        self.opening = nil
        send(opening.prompt, clock: TurnClock(speechEnd: .now))
        (openingTurn, openingHeard, openingLost) = (turn, false, false)
        bar.line = ""
        bar.activity = "Calling back"
    }

    /// The opening turn is over: said, talked over, or failed.
    private func openingDone(_ said: Bool) {
        guard openingTurn != nil else { return }
        openingTurn = nil
        let said = said && !openingLost
        log.info("call back \(said ? "said" : "failed", privacy: .public)")
        onOpening?(said)
    }

    private func send(_ words: String, clock: TurnClock, retried: Bool = false) {
        guard let client, let sessionID else { return heardNothing() }
        let carriesOpening = openingTurn != nil && openingTurn == turn
        turn += 1
        let current = turn
        (steps, stepTimer) = (StepQueue(), stepTimer.map { $0.cancel(); return nil } ?? nil)
        (workingSince, promised, callingBack) = (.now, [], false)
        if carriesOpening {
            // The opening goes on in a new session, or you said something before the agent answered it: you are on
            // the line and the agent has the result, so that counts as said.
            if retried { openingTurn = current } else { openingDone(openingHeard) }
        }
        (splitter, chunker, replyDone) = (ShowSplitter(), SpeechChunker(), false)
        self.clock = clock
        report = TalkTurnReport(words: words, reply: "", tools: [], cards: 0, clock: clock)
        bar = TalkBar(agent: bar.agent, phase: .thinking, line: words)
        ear.agentWorking(at: .now)
        let message = TalkPrompt.message(words, extra: [agent.talkNote, extras?.note ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
        let (updates, sink) = AsyncStream.makeStream(of: SessionUpdate.self)
        prompting = Task { [weak self] in
            let reading = Task { [weak self] in
                for await update in updates { self?.received(update, turn: current) }
            }
            var failure: (any Error)?
            do {
                _ = try await client.prompt(message, session: sessionID, timeout: 300, onUpdate: { sink.yield($0) },
                                            onPermission: { [weak self] request in await self?.ask(request, turn: current) })
            } catch { failure = error }
            sink.finish()
            await reading.value
            guard let self, !self.ended, current == self.turn else { return }
            if failure is SessionRetired, !retried {
                return await self.reopen(then: words, clock: clock)
            }
            if let failure, !(failure is CancellationError) {
                self.log.error("talk turn failed: \(failure.localizedDescription, privacy: .public)")
                self.report?.failed = failure.localizedDescription
                if await client.exited { return self.end(.failed("\(self.agent.name) stopped: \(failure.localizedDescription)")) }
                self.queue("Sorry, that didn't go through.", turn: current)
            }
            self.finishReply(turn: current)
        }
    }

    /// The session wouldn't take another turn after a cut-in it ignored, so the talk goes on in a new one, which is the
    /// conversation from here on.
    private func reopen(then words: String, clock: TurnClock) async {
        do {
            let (client, id, extras, _) = try await pool.talkSession(agent, fresh: true)
            guard !ended else { return }
            (self.client, sessionID, self.extras) = (client, id, extras)
            log.info("talk moved to session \(id, privacy: .public)")
            send(words, clock: clock, retried: true)
        } catch {
            end(.failed(error.localizedDescription))
        }
    }

    private func received(_ update: SessionUpdate, turn current: Int) {
        guard current == turn, !ended else { return }
        switch update {
        case .message(let text):
            clock?.mark(.firstText, at: .now)
            for piece in splitter.feed(text) { take(piece, turn: current) }
        case .tool(let title, let status, let kind, let id):
            // Every step shows; only some are said, so the voice doesn't chatter.
            if status == "failed" {
                if let id, steps.fail(call: id) { refreshBar() }
            } else if status != "completed", !(title.isEmpty && id.map({ steps.has(call: $0) }) == true) {
                // An update with no title only says the call moved on; its step is already up.
                showStep(title: title, kind: kind, call: id, turn: current)
            }
            notePromise(title: title, status: status, kind: kind, id: id)
            guard let phrase = announcer.announce(id: id, title: title, kind: kind, at: .now) else { return }
            report?.tools.append(phrase)
            queue(phrase + ".", turn: current)
        default:
            break
        }
    }

    /// Shows each step in turn, each up long enough to read.
    private func showStep(title: String, kind: String?, call: String?, turn current: Int) {
        let showing = bar.phase == .thinking && bar.activity != nil && bar.activity == steps.shown
        steps.offer(ToolLine.phrase(title: title, kind: kind), app: ToolLine.app(title: title, kind: kind), call: call)
        // A call that said more about itself changed the step on show.
        var next = bar
        if showing { next.activity = steps.shown }
        bar = next
        drainSteps(turn: current)
    }

    /// The bar with the step behind its activity, the steps before it, and when the wait began.
    private func withSteps(_ bar: TalkBar) -> TalkBar {
        var bar = bar
        bar.muted = muted
        let step = bar.phase == .thinking ? steps.step.flatMap { $0.line == bar.activity ? $0 : nil } : nil
        (bar.step, bar.trail) = (step, step == nil ? [] : steps.trail)
        bar.since = bar.phase == .thinking && report != nil ? (step == nil ? workingSince : steps.since) : nil
        return bar
    }

    /// Shows a change to the steps that left the bar's own words alone, such as a step that failed.
    private func refreshBar() {
        let same = bar
        bar = same
    }

    /// Once `call-me-back run` has started the job, the island says the agent will ring when it is done.
    private func notePromise(title: String, status: String?, kind: String?, id: String?) {
        let over = status == "completed" || status == "failed"
        if ToolLine.promisesCallBack(title: title, kind: kind) {
            if let id {
                promised.insert(id)
            } else if !over {
                // With no id its end can't be told, so the start is the promise.
                callingBack = true
                onCard?(.callBackPromised(agent: agent.name))
            }
        }
        // Only a job that started is a promise to hang up on: an updated call carries its id, often without its title.
        guard over, let id, promised.remove(id) != nil, status == "completed" else { return }
        callingBack = true
        onCard?(.callBackPromised(agent: agent.name))
    }

    /// A button on a result was pressed: its label goes to the agent as your next words, over whatever it was saying.
    /// False when the talk can't take it now: it is still connecting, or it waits on a permission.
    @discardableResult
    func choose(_ words: String) -> Bool {
        guard !ended, connected, permission == nil, !openingPending, let client, let sessionID else { return false }
        log.info("talk chose a button, \(words.count) characters")
        let busy = report != nil
        stopReply()
        bar = TalkBar(agent: bar.agent, phase: .thinking, line: words)
        ear.agentWorking(at: .now)
        let current = turn
        choosing?.cancel()
        choosing = Task { [weak self] in
            // The agent has let go of the reply it was on before the words go, so the stop can't land on them.
            if busy { await client.cancel(session: sessionID) }
            guard let self, !Task.isCancelled, !self.ended, current == self.turn else { return }
            self.send(words, clock: TurnClock(speechEnd: .now))
        }
        return true
    }

    private func drainSteps(turn current: Int) {
        // While the agent speaks or asks, the steps wait in `steps`, and their hold starts once they show.
        guard stepTimer == nil, current == turn, !ended, bar.phase != .speaking, permission == nil else { return }
        let (line, wait) = steps.next(at: .now)
        if let line { bar.activity = line }
        guard let wait = line == nil ? wait : StepQueue.hold else { return }
        stepTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            stepTimer = nil
            drainSteps(turn: current)
        }
    }

    private func take(_ piece: ReplyPiece, turn current: Int) {
        switch piece {
        case .speech(let text):
            report?.reply += text
            for chunk in chunker.feed(text) { queue(chunk, turn: current) }
            textCount += 1
            flush?.cancel()
            guard let wait = chunker.sentenceEndWait else { break }
            let seen = textCount
            flush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, seen == self.textCount, current == self.turn, self.chunker.sentenceEndWait != nil else { return }
                for chunk in self.chunker.finish() { self.queue(chunk, turn: current) }
            }
        case .show(let body) where TalkPrompt.isClear(body):
            onCard?(.clear)
        case .show(let body):
            report?.cards += 1
            if let card = RichCard.parse(body) { onCard?(.result(card)) } else { onCard?(.show(ShowCard.classify(body))) }
        }
    }

    private func finishReply(turn current: Int) {
        flush?.cancel()
        for piece in splitter.finish() { take(piece, turn: current) }
        for chunk in chunker.finish() { queue(chunk, turn: current) }
        queuedLines += 1
        lines?.yield(Line(turn: current, text: "", end: true, number: queuedLines))
    }

    private func queue(_ text: String, turn current: Int) {
        let spoken = Speech.spoken(text)
        guard !spoken.isEmpty else { return }
        clock?.mark(.firstPiece, at: .now)
        queuedLines += 1
        lines?.yield(Line(turn: current, text: text, number: queuedLines))
    }

    /// Makes one line and hands it to the speaker, which plays it while the next is made.
    private func say(_ line: Line) async {
        guard line.turn == turn else { return }
        if line.end {
            replyDone = true
            if !speaker.isPlaying { turnOver() }
            return
        }
        guard line.number > hushedThrough else { return }
        do {
            let clip = try await voice.speak(Speech.spoken(line.text))
            guard line.turn == turn, !ended, line.number > hushedThrough else { return }
            speaker.play(clip, caption: Speech.caption(line.text))
        } catch {
            guard line.turn == turn, !ended else { return }
            log.error("talk voice failed: \(error.localizedDescription, privacy: .public)")
            onNotice?(.failed(error.localizedDescription))
            if openingTurn == line.turn { openingLost = true }
            if greeting {
                greeting = false
                sendOpening()
            }
        }
    }

    private func started(_ caption: String) {
        guard !ended else { return }
        let toolLine = report?.tools.contains(where: { Speech.caption($0 + ".") == caption }) ?? false
        if openingTurn == turn, !toolLine, report != nil { openingHeard = true }
        clock?.mark(.firstAudio, at: .now)
        ear.agentSpeaking(at: .now, speakers: !AudioDevices.outputIsHeadphones())
        if toolLine {
            // A step said out loud shows as a step, under your words, not as something the agent is telling you.
            let step = steps.shown ?? (caption.hasSuffix(".") ? String(caption.dropLast()) : caption)
            bar = TalkBar(agent: bar.agent, phase: .thinking, line: bar.phase == .thinking ? bar.line : "",
                          activity: permission == nil ? step : bar.activity)
            return drainSteps(turn: turn)
        }
        bar = TalkBar(agent: bar.agent, phase: .speaking, line: caption, endingSoon: false)
    }

    /// Everything handed to the speaker has played.
    private func idle() {
        guard !ended else { return }
        if greeting {
            greeting = false
            if !connected { bar = TalkBar(agent: bar.agent, phase: .connecting, activity: "Calling back") }
            return sendOpening()
        }
        guard !ear.isHearing else { return }
        if replyDone, permission == nil { return turnOver() }
        ear.agentWorking(at: .now)
        bar = TalkBar(agent: bar.agent, phase: .thinking, activity: permission == nil ? steps.shown ?? bar.activity : permissionHint)
        drainSteps(turn: turn)
    }

    private func turnOver() {
        guard !ended, let report else { return }
        self.report = nil
        var finished = report
        if let clock { finished.clock = clock }
        log.info("talk turn: \(finished.clock.summary, privacy: .public)")
        onTurn?(finished)
        if openingTurn == turn { openingDone(finished.failed == nil && openingHeard) }
        ear.agentDone(at: .now)
        if callingBack {
            // It said it will call back, and the job runs without the talk: hang up, after a breath.
            bar = TalkBar(agent: bar.agent, phase: .listening, activity: "Calling back when it's done")
            let current = turn
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                // You said something meanwhile, or pressed a button: the talk goes on.
                guard let self, current == self.turn, self.report == nil, !self.ear.isHearing else { return }
                self.end(.callBack)
            }
            return
        }
        bar = TalkBar(agent: bar.agent, phase: .listening)
        onListening?()
    }

    /// You talked over the reply: the agent stops, and what it hasn't said is dropped.
    private func stopReply() {
        guard report != nil else { return }
        // You talked over the result, so you are there and heard it start; the talk goes on from what you say.
        if openingTurn == turn { openingDone(openingHeard) }
        turn += 1
        report = nil
        speaker.stop()
        prompting?.cancel()
        if let client, let sessionID { Task { await client.cancel(session: sessionID) } }
    }

    // MARK: Permission

    private func ask(_ request: PermissionRequest, turn current: Int) async -> String? {
        guard current == turn, !ended, permission == nil else { return request.rejection?.id }
        let byVoice: Bool
        switch TalkPermission.decide(request) {
        case .answer(let option): return option
        case .ask(let voice): byVoice = voice
        }
        var (phrase, detail) = (ToolLine.permissionPhrase(title: request.title, kind: request.toolKind), request.title)
        if T3Talk.isLaunch(request) {
            // Said and shown from what the agent passes to T3 Code, not from what it says: where, what for, and the task.
            let details = T3Talk.launchDetails(request)
            var name: String?
            if let id = details.projectID { name = await extras?.projectName?(id) }
            guard current == turn, !ended, permission == nil else { return request.rejection?.id }
            (phrase, detail) = (T3Talk.launchPhrase(request, projectName: name), String(details.message.prefix(240)))
        }
        onCard?(.permission(agent: agent.name, phrase: phrase, detail: detail, byVoice: byVoice))
        bar.activity = byVoice ? "Say yes or no" : "Click Allow, or say no"
        queue(byVoice ? "\(agent.name) wants your OK for this: \(phrase). Say yes or no."
                      : "\(agent.name) wants your OK for this: \(phrase). Click Allow on the screen, or say no.", turn: current)
        return await withCheckedContinuation { continuation in
            permission = (request, continuation, current, byVoice)
            permissionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.answerPermission(false)
            }
        }
    }

    private var permissionHint: String { permission?.byVoice == true ? "Say yes or no" : "Click Allow, or say no" }

    /// Allow or Deny on the card, or a spoken yes or no.
    func answerPermission(_ allowed: Bool) {
        guard let permission else { return }
        self.permission = nil
        permissionTimeout?.cancel()
        permission.answer.resume(returning: TalkPermission.choice(permission.request, allowed: allowed))
        onCard?(.permissionAnswered)
        log.info("talk permission \(allowed ? "allowed" : "denied", privacy: .public)")
        guard !ended else { return }
        // The rest of the question isn't said, so its echo can't be taken for you talking over the agent and cancel
        // what you just allowed.
        if permission.turn == turn {
            hushedThrough = queuedLines
            speaker.stop()
        }
        bar = TalkBar(agent: bar.agent, phase: .thinking, activity: allowed ? "Going ahead" : "Skipping that")
        ear.agentWorking(at: .now)
    }
}
