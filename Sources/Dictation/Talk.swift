import DictationCore
import Foundation
import os
import Synchronization

/// Where a talk hears you from: the microphone, or, for the end-to-end test, WAV clips played in real time.
@MainActor protocol TalkInput: AnyObject {
    func start() throws
    /// The 16 kHz samples that arrived since the last read.
    func read() -> [Float]
    var level: Float { get }
    func stop()
}

/// The shared microphone, which dictation can't use while a talk runs.
@MainActor final class MicTalkInput: TalkInput {
    private let microphone: Microphone
    private let choice: MicrophoneChoice

    init(_ microphone: Microphone, choice: MicrophoneChoice) { (self.microphone, self.choice) = (microphone, choice) }

    func start() throws { try microphone.start(from: choice) }
    func read() -> [Float] { microphone.drain() }
    var level: Float { microphone.level }
    func stop() { microphone.cancel() }
}

/// Clips played one at a time, in real time, with silence between: each clip starts when `next()` is called.
@MainActor final class ClipInput: TalkInput {
    private var clips: [[Float]]
    private var playing: [Float] = []
    private var position = 0
    private var last: Instant?
    private(set) var level: Float = 0

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
        level = TalkEar.rms(out)
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

/// How a talk ended.
enum TalkEnd: Equatable {
    case byYou
    case goodbye
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
    /// The session the talk went to, once it is open.
    private(set) var sessionID: String?

    private(set) var bar: TalkBar { didSet { if bar != oldValue { onBar?(bar) } } }
    private var ear = TalkEar()
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
         speaker: any TalkSpeaker) {
        (self.agent, self.pool, self.engine, self.voice, self.input, self.speaker) = (agent, pool, engine, voice, input, speaker)
        bar = TalkBar(agent: BarAgent(initial: agent.initial, name: agent.name), phase: .connecting)
    }

    /// The level the bar's meter shows: the agent's voice while it talks, yours otherwise.
    var level: Float { bar.phase == .speaking ? speaker.level : input.level }

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
            let (client, id) = try await session
            try await ready
            guard !ended else { return }
            (self.client, sessionID, connected) = (client, id, true)
            log.info("talk with \(agent.name, privacy: .public) in session \(id, privacy: .public)")
            if let waitingTurn {
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

    private func tick() {
        pending += input.read()
        let block = Int(ear.timing.block * Recording.sampleRate)
        let now = Instant.now
        while pending.count >= block {
            let samples = Array(pending.prefix(block))
            pending.removeFirst(block)
            let time = now + -Double(pending.count) / Recording.sampleRate
            let event = ear.hear(samples, at: time)
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
            if permission == nil {
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
            bar = TalkBar(agent: bar.agent, phase: .thinking, line: bar.line)
            if connected { transcribe(utterance) } else { waitingTurn = utterance }
        case .idleWarning:
            bar.endingSoon = true
            onNotice?(.talkEndingSoon(seconds: Int(ear.timing.idleEnd - ear.timing.idleWarning)))
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

    private func send(_ words: String, clock: TurnClock, retried: Bool = false) {
        guard let client, let sessionID else { return heardNothing() }
        turn += 1
        let current = turn
        (splitter, chunker, replyDone) = (ShowSplitter(), SpeechChunker(), false)
        self.clock = clock
        report = TalkTurnReport(words: words, reply: "", tools: [], cards: 0, clock: clock)
        bar = TalkBar(agent: bar.agent, phase: .thinking, line: words)
        ear.agentWorking(at: .now)
        let message = TalkPrompt.message(words, extra: agent.talkNote)
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

    /// The session wouldn't take another turn after a cut-in it ignored, so the talk goes on in a new one.
    private func reopen(then words: String, clock: TurnClock) async {
        do {
            let (client, id) = try await pool.talkSession(agent)
            guard !ended else { return }
            (self.client, sessionID) = (client, id)
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
        case .tool(let title, _, let kind, let id):
            guard let phrase = announcer.announce(id: id, title: title, kind: kind, at: .now) else { return }
            report?.tools.append(phrase)
            if bar.phase != .speaking { bar.activity = phrase }
            queue(phrase + ".", turn: current)
        default:
            break
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
        case .show(let body):
            report?.cards += 1
            onCard?(.show(ShowCard.classify(body)))
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
        }
    }

    private func started(_ caption: String) {
        guard !ended else { return }
        clock?.mark(.firstAudio, at: .now)
        ear.agentSpeaking(at: .now)
        bar = TalkBar(agent: bar.agent, phase: .speaking, line: caption, endingSoon: false)
    }

    /// Everything handed to the speaker has played.
    private func idle() {
        guard !ended, !ear.isHearing else { return }
        if replyDone, permission == nil { return turnOver() }
        ear.agentWorking(at: .now)
        bar = TalkBar(agent: bar.agent, phase: .thinking, activity: permission == nil ? bar.activity : permissionHint)
    }

    private func turnOver() {
        guard !ended, let report else { return }
        self.report = nil
        var finished = report
        if let clock { finished.clock = clock }
        log.info("talk turn: \(finished.clock.summary, privacy: .public)")
        onTurn?(finished)
        ear.agentDone(at: .now)
        bar = TalkBar(agent: bar.agent, phase: .listening)
        onListening?()
    }

    /// You talked over the reply: the agent stops, and what it hasn't said is dropped.
    private func stopReply() {
        guard report != nil else { return }
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
        let phrase = ToolLine.permissionPhrase(title: request.title, kind: request.toolKind)
        onCard?(.permission(agent: agent.name, phrase: phrase, detail: request.title, byVoice: byVoice))
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
