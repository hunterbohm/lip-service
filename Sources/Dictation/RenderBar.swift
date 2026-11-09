import AppKit
import DictationCore

/// `--render-bar DIR`: lays out every bar state with the app's own Bar on a stand-in screen kept off the displays,
/// and writes each as a PNG, the whole stage, a close-up, and the close-up on a near-black screen, so the look can be checked without a key press. The
/// voice is frozen mid-speech and the animations settled, so a still shows the print at a fixed moment. One scene is captured while its words are still printing in.
@MainActor enum RenderBar {
    private struct Scene {
        var name: String
        var state: BarState
        var edge = BarEdge.bottom
        var dragNearest: BarEdge?
        var quiet = false
        /// How long to let the animations run before the snapshot. Short, and a word is caught mid-print.
        var settle = 1.2
        var card: CardModel?
        /// Cards a talk put up, newest last.
        var talkCards: [TalkCardEvent] = []
        /// A talk's island on a screen with a notch, and with the pointer over it.
        var notch = false
        var hovering = false
        /// How deep another app's bar is across the top of the stand-in screen, such as a tiling window manager's, or nil
        /// for none. The island floats below it.
        var topBar: Double?
        /// The notices a talk put in the island have had their time, so they wait under the pointer.
        var noticesClosed = false
        /// A button pressed on the result in the island.
        var press: String?
    }

    private static let notched = TalkIsland.Screen(hasNotch: true, notchWidth: 185, barHeight: 32)
    /// The MacBook Pro's tiling bar covers the same 32 points as its menu bar and notch.
    private static let tilerBar = 32.0

    private static let hermes = BarAgent(initial: "H", name: "Hermes")
    private static let said = "reply saying Tuesday at 3 works and I'll bring the latest cut"
    private static let draftText = "Hi Dana,\n\nTuesday at 3 works for me. I'll bring the latest cut so we can go through it together.\n\nHunter"
    private static let longDraft = (1...14).map { "Step \($0): build the next part of the 3D chess set, with real detail on every piece and a board that renders smoothly in a browser viewer." }
        .joined(separator: "\n\n")

    /// A draft card driven to a phase by the same events the app sends it.
    private static func draft(_ events: [DraftCard.Event]) -> DraftCard {
        var card = DraftCard(typesDirectly: false)
        for event in [DraftCard.Event.released, .heard(said)] + events { _ = card.handle(event) }
        return card
    }

    private static func cardModel(_ content: CardModel.Content, heading: String = "Hermes · draft for Dana Park") -> CardModel {
        CardModel(agent: hermes, heading: heading, content: content, changeKey: "⌃ fn", keysLive: true)
    }

    private static func handOff(_ events: [HandOffCard.Event], picks: Bool = false, destination: String = "Hermes in iMessage") -> HandOffCard {
        var card = HandOffCard(words: "remind me to call Theo at five", destination: destination, picksProject: picks, now: .now + 1.3)
        for event in events { _ = card.handle(event) }
        return card
    }

    private static let projects = [
        HandOffCard.Project(id: "1", name: "command-center", environmentName: "Mac mini", updatedAt: .now),
        HandOffCard.Project(id: "2", name: "dictation", environmentName: "Mac mini", updatedAt: .now - 3600),
        HandOffCard.Project(id: "3", name: "profitpilot-web", environmentName: "MacBook Pro", updatedAt: .now - 7200),
        HandOffCard.Project(id: "4", name: "vault", environmentName: "MacBook Pro", updatedAt: .now - 86_400),
    ]

    private static var agentScenes: [Scene] {
        let listening = BarState(body: .listening(words: said, handsFree: false), agent: hermes)
        return [
            Scene(name: "30-agent-listening", state: listening),
            Scene(name: "31-agent-writing", state: BarState(body: .working(status: "Hermes is writing…", busy: true), agent: hermes)),
            Scene(name: "32-card-streaming", state: BarState(body: .working(status: "Writing", busy: true), agent: hermes),
                  card: cardModel(.draft(draft([.chunk("Hi Dana,\n\nTuesday at 3 works for me. I'll bring")])))),
            Scene(name: "33-card-ready", state: BarState(body: .working(status: "Ready", busy: false), agent: hermes),
                  card: cardModel(.draft(draft([.chunk(draftText), .finished])))),
            Scene(name: "34-card-change", state: BarState(body: .listening(words: "make it a bit warmer", handsFree: false), agent: hermes),
                  card: cardModel(.draft(draft([.chunk(draftText), .finished, .listen])))),
            Scene(name: "36-card-failed", state: BarState(body: .working(status: "Didn't finish", busy: false), agent: hermes),
                  card: cardModel(.draft(draft([.failed("Hermes couldn't be reached: ssh: connect to host mini port 22: Operation timed out")])),
                                  heading: "Hermes")),
            Scene(name: "38-handoff-confirming", state: BarState(body: .working(status: "Sending to Hermes…", busy: true), agent: hermes),
                  card: cardModel(.handOff(handOff([])), heading: "Hermes")),
            Scene(name: "39-handoff-sent", state: BarState(body: .working(status: "Nothing typed", busy: false), agent: hermes),
                  card: cardModel(.handOff(handOff([.key(.returnKey), .sent(note: "Hermes keeps going in iMessage, where it always answers you.")])),
                                  heading: "Hermes")),
            Scene(name: "40-handoff-picking", state: BarState(body: .working(status: "Sending to Claude Code…", busy: true), agent: BarAgent(initial: "C", name: "Claude Code")),
                  card: CardModel(agent: BarAgent(initial: "C", name: "Claude Code"), heading: "Claude Code",
                                  content: .handOff(handOff([.projects(projects), .key(.down)], picks: true, destination: "a new T3 Code thread")),
                                  changeKey: "⌃ fn", keysLive: true)),
            Scene(name: "41-handoff-reply", state: BarState(body: .working(status: "Nothing typed", busy: false), agent: hermes),
                  card: cardModel(.handOff(handOff([.key(.returnKey), .chunk("Done. I'll text you at 4:55 to call Theo.")])), heading: "Hermes")),
            Scene(name: "42-handoff-replied", state: BarState(body: .working(status: "Nothing typed", busy: false), agent: hermes),
                  card: cardModel(.handOff(handOff([.key(.returnKey), .chunk("Done. I'll text you at 4:55 to call Theo."), .sent(note: "Hermes answered.")])),
                                  heading: "Hermes")),
            Scene(name: "43-card-long", state: BarState(body: .working(status: "Ready", busy: false), agent: hermes),
                  card: cardModel(.draft(draft([.chunk(longDraft), .finished])))),
        ]
    }

    private static func talk(_ phase: TalkBar.Phase, line: String = "", activity: String? = nil, endingSoon: Bool = false) -> BarState.Body {
        .talk(TalkBar(agent: hermes, phase: phase, line: line, activity: activity, endingSoon: endingSoon))
    }

    /// The moment every scene's timers read.
    private static let renderNow = Instant(seconds: 100_000)

    /// The agent at work on `step`, which it has been on for `seconds`, after `trail`.
    private static func working(_ step: TalkStep, for seconds: Double, after trail: [TalkStep] = [], line: String = "") -> BarState.Body {
        .talk(TalkBar(agent: hermes, phase: .thinking, line: line, activity: step.line, step: step, trail: trail, since: renderNow + -seconds))
    }

    private static let trail = [
        TalkStep(line: "Loading media-request skill", id: 1),
        TalkStep(line: "Checking Gmail", app: .gmail, id: 2),
        TalkStep(line: "Checking your calendar", app: .calendar, id: 3),
    ]
    private static let threadStep = TalkStep(line: "Starting a thread in T3 Code", app: .t3Code, id: 4)

    private static func result(_ json: String) -> TalkCardEvent { .result(RichCard.parse(json)!) }

    private static let flights = """
        {"type":"flights","from":"AUS","to":"SFO","date":"Fri, Nov 14","note":"1 adult · nonstop","options":[
        {"airline":"United","depart":"7:05a","arrive":"9:00a","duration":"3h 55m","stops":"Nonstop","price":214,"best":true,"url":"https://www.united.com"},
        {"airline":"Alaska","depart":"9:40a","arrive":"11:42a","duration":"4h 02m","stops":"Nonstop","price":238},
        {"airline":"Southwest","depart":"1:15p","arrive":"3:20p","duration":"4h 05m","stops":"Nonstop","price":"$189"}],
        "actions":["Hold the 7:05","Text me these"]}
        """
    private static let flightsSoFar = """
        {"type":"flights","from":"AUS","to":"SFO","date":"Fri, Nov 14","note":"1 adult · nonstop","options":[
        {"airline":"United","depart":"7:05a","arrive":"9:00a","duration":"3h 55m","stops":"Nonstop","price":214}]}
        """
    private static let rows = """
        [{"type":"task","id":"PP-3","title":"ProfitPilot outreach","status":"todo","due":"Nov 9","where":"vault","url":"obsidian://open?vault=vault&file=PP-3"},
        {"type":"event","title":"Design review with Dana","date":"2026-11-12","time":"3:00 PM","where":"Zoom"},
        {"type":"email","from":"Theo","subject":"Launch video cut","time":"2:14 PM","url":"https://mail.google.com"},
        {"type":"task","title":"Send the invoice","done":true}]
        """

    private static let chart = """
        <div style="font:600 13px -apple-system;color:#ECEDEE;margin-bottom:8px">Dictations this week</div>
        <svg viewBox="0 0 420 150" width="420" height="150" xmlns="http://www.w3.org/2000/svg">
        <g fill="#3B82F6">\((0..<7).map { i in
            let h = [62, 88, 74, 120, 96, 40, 28][i]
            return "<rect x=\"\(i * 60 + 10)\" y=\"\(130 - h)\" width=\"40\" height=\"\(h)\" rx=\"4\"/>"
        }.joined())</g>
        <g fill="#9A9BA0" font-size="11" font-family="-apple-system">\(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated().map { i, day in
            "<text x=\"\(i * 60 + 30)\" y=\"146\" text-anchor=\"middle\">\(day)</text>"
        }.joined())</g></svg>
        """

    /// Every state of a live talk, which always sits at the top.
    private static var talkScenes: [Scene] {
        [
            Scene(name: "50-talk-connecting", state: BarState(body: talk(.connecting)), edge: .top, quiet: true),
            Scene(name: "52-talk-listening", state: BarState(body: talk(.listening)), edge: .top, quiet: true),
            Scene(name: "53-talk-you-talking", state: BarState(body: talk(.hearing, line: "what's on my calendar this afternoon")), edge: .top),
            Scene(name: "54-talk-thinking", state: BarState(body: talk(.thinking)), edge: .top, quiet: true),
            Scene(name: "55-talk-tool", state: BarState(body: talk(.thinking, activity: "Running t3-run status")), edge: .top, quiet: true),
            Scene(name: "55b-talk-tool-skill", state: BarState(body: talk(.thinking, line: "what's left on the media request",
                                                                          activity: "Loading media-request skill")), edge: .top, quiet: true),
            Scene(name: "56-talk-agent-talking", state: BarState(body: talk(.speaking, line: "You have two meetings this afternoon, the first at three.")),
                  edge: .top),
            Scene(name: "57-talk-ending-soon", state: BarState(body: talk(.listening, endingSoon: true)),
                  edge: .top, quiet: true),
            Scene(name: "58-talk-cards", state: BarState(body: talk(.speaking, line: "The link is on your screen.")), edge: .top,
                  talkCards: [.show(.text("git switch -c live-talk\nswift build -c release\nscripts/test.sh")),
                              .show(.link(URL(string: "https://www.swift.org/documentation/")!))]),
            Scene(name: "58b-talk-notice", state: BarState(body: talk(.speaking, line: "I added it to your vault for today.")), edge: .top,
                  talkCards: [.show(.text("PP-3 · ProfitPilot outreach: run it and improve overall, maybe add another channel · due Nov 9 · todo"))]),
            Scene(name: "58c-talk-notice-listening", state: BarState(body: talk(.listening)), edge: .top, quiet: true,
                  talkCards: [.show(.text("PP-3 · ProfitPilot outreach: run it and improve overall · due Nov 9"))]),
            Scene(name: "59-talk-permission", state: BarState(body: talk(.speaking, line: "Hermes wants your OK for this: Running a command. Click Allow on the screen, or say no.")),
                  edge: .top,
                  talkCards: [.permission(agent: "Hermes", phrase: "Running a command", detail: "terminal: hermes send -t photon", byVoice: false)]),
            Scene(name: "60-talk-visual", state: BarState(body: talk(.speaking, line: "Here's your week.")), edge: .top, settle: 2.5,
                  talkCards: [.show(.html(chart))]),
            Scene(name: "61-talk-hover", state: BarState(body: talk(.listening)), edge: .top, quiet: true, hovering: true),
            Scene(name: "62-talk-notch-listening", state: BarState(body: talk(.hearing, line: "what's on")), edge: .top, notch: true),
            Scene(name: "63-talk-notch-thinking", state: BarState(body: talk(.thinking, line: "what's on my calendar this afternoon",
                                                                               activity: "Checking your calendar")), edge: .top, quiet: true, notch: true),
            Scene(name: "64-talk-notch-agent-talking", state: BarState(body: talk(.speaking, line: "You have two meetings this afternoon, the first at three.")),
                  edge: .top, notch: true),
            Scene(name: "65-talk-notch-bar-listening", state: BarState(body: talk(.listening)), edge: .top, quiet: true, notch: true, topBar: tilerBar),
            Scene(name: "66-talk-notch-bar-agent-talking", state: BarState(body: talk(.speaking, line: "You have two meetings this afternoon, the first at three.")),
                  edge: .top, notch: true, topBar: tilerBar),
            Scene(name: "67-talk-notch-bar-cards", state: BarState(body: talk(.speaking, line: "The link is on your screen.")), edge: .top,
                  talkCards: [.show(.text("git switch -c live-talk\nswift build -c release\nscripts/test.sh")),
                              .show(.link(URL(string: "https://www.swift.org/documentation/")!))],
                  notch: true, topBar: tilerBar),
            Scene(name: "68-talk-notch-bar-hover", state: BarState(body: talk(.listening)), edge: .top, quiet: true, notch: true, hovering: true,
                  topBar: tilerBar),
            Scene(name: "69-talk-bar-no-notch", state: BarState(body: talk(.thinking, activity: "Checking Gmail")), edge: .top, quiet: true,
                  topBar: tilerBar),
            Scene(name: "70-call-back-ringing", state: BarState(body: talk(.ringing, line: "the flight search")), edge: .top, quiet: true),
            Scene(name: "71-call-back-ringing-notch", state: BarState(body: talk(.ringing, line: "the flight search")), edge: .top, quiet: true,
                  notch: true),
            Scene(name: "72-talk-steps", state: BarState(body: working(threadStep, for: 2, after: trail, line: "what's left on the media request")),
                  edge: .top, quiet: true),
            Scene(name: "73-talk-steps-long", state: BarState(body: working(TalkStep(line: "Running t3-run status", app: .t3Code, id: 5), for: 12, after: [
                TalkStep(line: "Checking Slack", app: .slack, id: 2), TalkStep(line: "Checking Stripe", app: .stripe, failed: true, id: 3),
                TalkStep(line: "Searching the web for flight prices", app: .browser, id: 4),
            ])), edge: .top, quiet: true),
            Scene(name: "74-talk-step-failed", state: BarState(body: working(TalkStep(line: "Checking Notion", app: .notion, failed: true, id: 2), for: 3,
                                                                              after: [TalkStep(line: "Reading a note in your vault", app: .obsidian, id: 1)])),
                  edge: .top, quiet: true),
            Scene(name: "75-talk-call-back-promised", state: BarState(body: working(threadStep, for: 134, after: Array(trail.suffix(1)))), edge: .top,
                  quiet: true, talkCards: [.callBackPromised(agent: "Hermes")]),
            Scene(name: "76-talk-step-closed", state: BarState(body: working(threadStep, for: 134)), edge: .top, quiet: true),
            Scene(name: "77-talk-step-closed-notch", state: BarState(body: working(threadStep, for: 134)), edge: .top, quiet: true, notch: true),
            Scene(name: "78-talk-step-closed-notch-bar", state: BarState(body: working(TalkStep(line: "Checking Gmail", app: .gmail, id: 2), for: 31)),
                  edge: .top, quiet: true, notch: true, topBar: tilerBar),
            Scene(name: "79-talk-step-closed-quick", state: BarState(body: working(TalkStep(line: "Searching the web for flights", app: .browser, id: 2), for: 21)),
                  edge: .top, quiet: true, notch: true),
            Scene(name: "80-talk-flights", state: BarState(body: talk(.speaking, line: "Three nonstops on Friday. The 7:05 on United is the best.")),
                  edge: .top, settle: 2.2, talkCards: [result(flights)]),
            Scene(name: "81-talk-flights-coming", state: BarState(body: working(TalkStep(line: "Searching the web for flights", app: .browser, id: 2),
                                                                                 for: 8, after: Array(trail.prefix(1)))),
                  edge: .top, quiet: true, settle: 2.2, talkCards: [result(flightsSoFar)]),
            Scene(name: "82-talk-flights-chosen", state: BarState(body: talk(.thinking, line: "Hold the 7:05")), edge: .top, quiet: true, settle: 2.2,
                  talkCards: [result(flights)], press: "Hold the 7:05"),
            Scene(name: "83-talk-flights-notch", state: BarState(body: talk(.speaking, line: "Three nonstops on Friday.")), edge: .top, settle: 2.2,
                  talkCards: [result(flights)], notch: true),
            Scene(name: "84-talk-results", state: BarState(body: talk(.speaking, line: "Here's what's on your plate.")), edge: .top, settle: 1.6,
                  talkCards: [result(rows)]),
            Scene(name: "85-talk-results-waiting", state: BarState(body: talk(.listening)), edge: .top, quiet: true, talkCards: [result(rows)],
                  noticesClosed: true),
            Scene(name: "86-talk-results-waiting-notch", state: BarState(body: talk(.listening)), edge: .top, quiet: true, talkCards: [result(rows)],
                  notch: true, noticesClosed: true),
        ]
    }

    /// Mid-speech: loud now, with swells before it that the print carries rightward, so the print rises and falls from left to right.
    nonisolated private static func speaking(_ age: Double) -> Float {
        Float(min(max(0.45 + 0.4 * cos(age * 10) * exp(-age * 0.7), 0), 1))
    }
    /// The same speech as heard in each band, a little apart, so the three waves are not the same shape.
    nonisolated private static func speakingBand(_ band: Int, _ age: Double) -> Float {
        let shift = [0.0, 0.11, 0.23][band], scale = [1.0, 0.85, 0.6][band]
        return Float(min(max(scale * Double(speaking(age + shift)), 0), 1))
    }
    private static let frozenAt = 0.9
    private static let short = "Teo Yep, I'll share the latest version in a few minutes"
    private static let long = "Okay so the plan for Friday is to ship the new onboarding flow to everyone, then check the "
        + "Beehiiv numbers on Monday and ask ProfitPilot to draft the follow-up email for the people who signed up late"
    private static let stage = NSRect(x: -9000, y: -9000, width: 1000, height: 700)
    private static let scale: CGFloat = 2

    private static let scenes: [Scene] = [
        Scene(name: "01-listening-start", state: BarState(body: .listening(words: "", handsFree: false))),
        Scene(name: "02-listening-short", state: BarState(body: .listening(words: short, handsFree: false))),
        Scene(name: "03-listening-long", state: BarState(body: .listening(words: long, handsFree: false))),
        Scene(name: "04-hands-free", state: BarState(body: .listening(words: short, handsFree: true))),
        Scene(name: "05-hands-free-start", state: BarState(body: .listening(words: "", handsFree: true))),
        Scene(name: "06-transcribing", state: BarState(body: .transcribing(words: short, waitingOn: nil))),
        Scene(name: "07-transcribing-waiting-on-model", state: BarState(body: .transcribing(words: short, waitingOn: .compiling))),
        Scene(name: "08-preparing-download", state: BarState(body: .preparing(.downloading(fraction: 0.42)))),
        Scene(name: "09-preparing-compile", state: BarState(body: .preparing(.compiling))),
        Scene(name: "10-toast-copied", state: BarState(body: .hidden, toast: .copied(.focusMoved))),
        Scene(name: "11-toast-failed", state: BarState(body: .hidden, toast: .failed("Transcription failed: The model stopped responding."))),
        Scene(name: "12-toast-microphone-missing", state: BarState(body: .listening(words: "", handsFree: false),
                                                                    toast: .microphoneMissing(chosen: "Shure MV7+", using: "MacBook Pro Microphone"))),
        Scene(name: "13-toast-nothing-to-paste", state: BarState(body: .idle, toast: .nothingToPaste)),
        Scene(name: "14-toast-model-failed-retry", state: BarState(body: .hidden, toast: .modelFailed("The network connection was lost."))),
        Scene(name: "15-toast-fn-key-setting", state: BarState(body: .listening(words: "", handsFree: false), toast: .fnKeySetting)),
        Scene(name: "16-idle-bottom", state: BarState(body: .idle)),
        Scene(name: "17-idle-top", state: BarState(body: .idle), edge: .top),
        Scene(name: "18-idle-left", state: BarState(body: .idle), edge: .left),
        Scene(name: "19-idle-right", state: BarState(body: .idle), edge: .right),
        Scene(name: "20-listening-top", state: BarState(body: .listening(words: short, handsFree: false)), edge: .top),
        Scene(name: "21-listening-left", state: BarState(body: .listening(words: short, handsFree: false)), edge: .left),
        Scene(name: "22-listening-right", state: BarState(body: .listening(words: short, handsFree: false)), edge: .right),
        Scene(name: "23-listening-right-long", state: BarState(body: .listening(words: long, handsFree: true)), edge: .right),
        Scene(name: "24-toast-right", state: BarState(body: .listening(words: "", handsFree: false),
                                                       toast: .microphoneMissing(chosen: "Shure MV7+", using: "MacBook Pro Microphone")),
              edge: .right),
        Scene(name: "25-toast-top", state: BarState(body: .idle, toast: .copied(.focusMoved)), edge: .top),
        Scene(name: "26-dragging", state: BarState(body: .idle), edge: .bottom, dragNearest: .right),
        Scene(name: "27-listening-quiet", state: BarState(body: .listening(words: "", handsFree: false)), quiet: true),
        Scene(name: "28-listening-word-printing", state: BarState(body: .listening(words: short, handsFree: false)), settle: 0.12),
        Scene(name: "29-toast-learned", state: BarState(body: .listening(words: "", handsFree: false), toast: .learned("Siobhan"))),
    ]

    static func run(into directory: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        let bar = Bar(voice: { nil }, area: { _ in stage })
        let cards = CardPanel()
        let talkCards = TalkCardPanel()
        let island = TalkIslandPanel()
        island.model.frozenAt = frozenAt
        island.model.frozenNow = renderNow
        island.model.level = { [bar] in bar.meter.reading(at: frozenAt).level(delay: 0) }
        island.onMoved = { [bar] rect in bar.talkAnchor = rect }
        for scene in scenes + agentScenes + talkScenes {
            bar.render(BarState(body: .hidden), edge: scene.edge)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            if scene.quiet { bar.meter.freeze(at: frozenAt, profile: { _ in 0 }) } else { bar.meter.freeze(at: frozenAt, profile: speaking, band: speakingBand) }
            bar.render(scene.state, edge: scene.edge)
            bar.showOutlines(nearest: scene.dragNearest)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if let card = scene.card { cards.show(card, above: bar.anchor()) } else { cards.hide() }
            (island.model.notices, island.model.noticeOpen) = ([], false)
            if case .talk(let talk) = scene.state.body {
                let clear = scene.topBar.map { BarRect(x: stage.minX, y: stage.minY, width: stage.width, height: stage.height - $0) } ?? BarRect(stage)
                island.place(in: stage, placement: TalkIsland.placement(frame: BarRect(stage), screen: scene.notch ? notched : .plain, clear: clear))
                island.model.hovering = scene.hovering
                island.show(talk)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
            } else {
                island.show(nil)
            }
            talkCards.closeAll()
            for event in scene.talkCards where !island.take(event) { talkCards.handle(event, agent: hermes, under: (island.islandRect, .top)) }
            if let press = scene.press, let result = island.model.notices.first(where: \.isRich) {
                island.model.onAction = { _ in true }
                island.model.choose(press, on: result.key)
            }
            if scene.noticesClosed { island.model.noticeOpen = false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: scene.settle))
            let shown = bar.visiblePanels + (island.isVisible && scene.state.body.isTalkBody ? [(panel: island.window, shadow: false)] : [])
                + (cards.isVisible ? [(panel: cards.window, shadow: true)] : [])
                + (talkCards.isVisible ? [(panel: talkCards.window, shadow: true)] : [])
            let webShots = talkCards.isVisible ? webSnapshots(talkCards) : []
            let panels = shown.map {
                (frame: $0.panel.frame.offsetBy(dx: -stage.minX, dy: -stage.minY),
                 image: $0.panel === talkCards.window ? snapshot($0.panel, adding: webShots) : snapshot($0.panel), shadow: $0.shadow)
            }
            let stagePath = directory.appending(path: "\(scene.name).png")
            let closeUpPath = directory.appending(path: "\(scene.name)-closeup.png")
            let darkCloseUpPath = directory.appending(path: "\(scene.name)-closeup-dark.png")
            // The stand-in tiling bar, drawn behind the panels so the close-up shows what the island clears.
            let barFrame = scene.topBar.map { NSRect(x: 0, y: stage.height - $0, width: stage.width, height: $0) }
            let closeUpRegion = closeUp(around: panels.map(\.frame) + (barFrame.map { [$0.insetBy(dx: (stage.width - 700) / 2, dy: 0)] } ?? []))
            guard write(compose(panels, in: NSRect(origin: .zero, size: stage.size), topBar: barFrame), to: stagePath),
                  write(compose(panels, in: closeUpRegion, topBar: barFrame), to: closeUpPath),
                  write(compose(panels, in: closeUpRegion, dark: true, topBar: barFrame), to: darkCloseUpPath)
            else { return 1 }
            print(stagePath.path)
        }
        return 0
    }

    /// A web view draws in its own process, so drawing the panel leaves it blank. Its snapshots go on top instead.
    private static func webSnapshots(_ panel: TalkCardPanel) -> [(frame: NSRect, image: NSImage)] {
        var shots: [(frame: NSRect, image: NSImage)]?
        panel.webSnapshots { shots = $0 }
        let deadline = Date(timeIntervalSinceNow: 5)
        while shots == nil, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return shots ?? []
    }

    private static func snapshot(_ panel: NSPanel, adding shots: [(frame: NSRect, image: NSImage)]) -> NSImage {
        let image = snapshot(panel)
        guard !shots.isEmpty else { return image }
        image.lockFocusFlipped(false)
        for shot in shots { shot.image.draw(in: shot.frame) }
        image.unlockFocus()
        return image
    }

    private static func snapshot(_ panel: NSPanel) -> NSImage {
        guard let view = panel.contentView else { return NSImage() }
        view.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                   pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func closeUp(around frames: [NSRect]) -> NSRect {
        guard let first = frames.first else { return NSRect(origin: .zero, size: stage.size) }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return union.insetBy(dx: -36, dy: -24)
    }

    /// A light window with a darker sidebar stands in for the screen, so the bar's contrast reads as it would. `dark` swaps
    /// it for a near-black window like a dark-mode editor, where the bar must stand out by its glow.
    private static func compose(_ panels: [(frame: NSRect, image: NSImage, shadow: Bool)], in region: NSRect, dark: Bool = false,
                                topBar: NSRect? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale), pixelsHigh: Int(region.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = region.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.translateX(by: -region.minX, yBy: -region.minY)
        transform.concat()
        NSColor(white: dark ? 0.045 : 0.97, alpha: 1).setFill()
        region.fill()
        NSColor(white: dark ? 0.08 : 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 180, height: stage.height).fill()
        NSColor(white: dark ? 0.14 : 0.82, alpha: 1).setFill()
        for row in 0..<9 { NSRect(x: 220, y: stage.height - 70 - CGFloat(row) * 52, width: 360 + CGFloat(row % 3) * 90, height: 10).fill() }
        if let topBar {
            // Another app's bar, like OmniWM's: a dark strip across the top with a few small items.
            NSColor(white: 0.13, alpha: 1).setFill()
            topBar.fill()
            NSColor(white: 0.32, alpha: 1).setFill()
            for index in 0..<5 { NSRect(x: 16 + CGFloat(index) * 30, y: topBar.midY - 5, width: 22, height: 10).fill() }
            for index in 0..<4 { NSRect(x: topBar.maxX - 24 - CGFloat(index) * 64, y: topBar.midY - 5, width: 52, height: 10).fill() }
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        for panel in panels {
            NSGraphicsContext.saveGraphicsState()
            if panel.shadow { shadow.set() }
            panel.image.draw(in: panel.frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("cannot write \(url.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

private extension BarState.Body {
    var isTalkBody: Bool { if case .talk = self { true } else { false } }
}
