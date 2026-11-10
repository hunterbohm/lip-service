import Foundation
import Testing
@testable import DictationCore

@Suite("What the island shows of the agent's work") struct TalkStepsTests {
    private let hermes = BarAgent(initial: "H", name: "Hermes")

    @Test func aStepKnowsTheAppItUses() {
        #expect(ToolLine.app(title: "terminal: t3-run status 1a7431fb-4f9e-45ec", kind: "execute") == .t3Code)
        #expect(ToolLine.app(title: "terminal: ~/bin/gog --account me@example.com gmail search 'from:zach' --max 5", kind: "execute") == .gmail)
        #expect(ToolLine.app(title: "terminal: gh pr list", kind: "execute") == .github)
        #expect(ToolLine.app(title: "terminal: ls -la", kind: "execute") == .terminal)
        #expect(ToolLine.app(title: "web_search: flights AUS to SFO", kind: "fetch") == .browser)
        #expect(ToolLine.app(title: "mcp__t3-code__t3_thread_launch", kind: nil) == .t3Code)
        #expect(ToolLine.app(title: "slack_send_message: #general", kind: nil) == .slack)
        #expect(ToolLine.app(title: "read_file: /Users/h/vault/Daily/2026-11-09.md", kind: "read") == .obsidian)
        // A file anywhere else, and what the agent does inside itself, have no app.
        #expect(ToolLine.app(title: "read_file: plan.md", kind: "read") == nil)
        #expect(ToolLine.app(title: "skill_view: productivity/media-request", kind: "read") == nil)
        #expect(ToolLine.app(title: "session_search: flights", kind: "search") == nil)
    }

    @Test func aServiceInsideADottedToolPathIsFoundAndAFileNameIsNot() {
        #expect(ToolLine.phrase(title: "terminal: executor call tools.google.gmail.search --query x", kind: "execute") == "Checking Gmail")
        #expect(ToolLine.app(title: "terminal: executor call tools.google.gmail.search --query x", kind: "execute") == .gmail)
        #expect(ToolLine.app(title: "terminal: python3 drive.py", kind: "execute") == .terminal)
        #expect(ToolLine.phrase(title: "terminal: python3 drive.py", kind: "execute") != "Checking Google Drive")
    }

    @Test func aCommandThatSetsUpACallBackIsKnown() {
        let run = "terminal: call-me-back run --about 'the flight search' -- sleep 600"
        #expect(ToolLine.promisesCallBack(title: run, kind: "execute"))
        #expect(ToolLine.promisesCallBack(title: "terminal: ~/.local/bin/call-me-back run --about x -- sleep 5", kind: "execute"))
        #expect(!ToolLine.promisesCallBack(title: "terminal: call-me-back done", kind: "execute"))
        #expect(!ToolLine.promisesCallBack(title: "read_file: call-me-back run", kind: "read"))
        #expect(!ToolLine.promisesCallBack(title: "terminal: echo call-me-back run", kind: "execute"))
        #expect(ToolLine.phrase(title: run, kind: "execute") == "Setting up a call back")
        #expect(ToolLine.phrase(title: "terminal: call-me-back done", kind: "execute") == "Calling you back")
        #expect(ToolLine.app(title: run, kind: "execute") == .callBack)
    }

    @Test func aFinishedStepReadsInThePast() {
        #expect(ToolLine.done("Checking Gmail") == "Checked Gmail")
        #expect(ToolLine.done("Running t3-run status") == "Ran t3-run status")
        #expect(ToolLine.done("Setting up a call back") == "Set up a call back")
        #expect(ToolLine.done("Hold on") == "Hold on")
    }

    @Test func theClosedIslandGetsAWordOrTwo() {
        #expect(ToolLine.short("Checking Gmail") == "Gmail")
        #expect(ToolLine.short("Checking your calendar") == "Calendar")
        #expect(ToolLine.short("Running t3-run status") == "t3-run status")
        #expect(ToolLine.short("Loading media-request skill") == "media-request")
        #expect(ToolLine.short("Starting a thread in T3 Code") == "New thread")
        #expect(ToolLine.short("Searching the web for flights to San Francisco") == "Web search")
        #expect(ToolLine.short("Reading a note in your vault") == "Note")
        #expect(ToolLine.short("Setting up a call back") == "Call back")
        for line in ["Running a-very-long-program-name with-arguments", "Something the table has never heard of at all", "Checking"] {
            #expect(ToolLine.short(line).count <= ToolLine.shortLongest)
            #expect(!ToolLine.short(line).isEmpty)
        }
    }

    @Test func stepsLeaveATrailAndAToolThatSaysMoreKeepsItsRow() {
        var steps = StepQueue()
        steps.offer("Working on it", call: "a")
        #expect(steps.next(at: Instant(seconds: 0)).line == "Working on it")
        steps.offer("Checking Gmail", app: .gmail, call: "a")
        #expect(steps.step == TalkStep(line: "Checking Gmail", app: .gmail, call: "a", id: 1))
        #expect(steps.trail.isEmpty)
        steps.offer("Running t3-run status", app: .t3Code, call: "b")
        #expect(steps.next(at: Instant(seconds: 0.5)).line == nil)
        #expect(steps.next(at: Instant(seconds: 1)).line == "Running t3-run status")
        #expect(steps.trail.map(\.line) == ["Checking Gmail"])
        #expect(steps.since == Instant(seconds: 1))
        // A call that is already behind doesn't come back as a new step.
        steps.offer("Checking Gmail", app: .gmail, call: "a")
        #expect(steps.next(at: Instant(seconds: 5)).line == nil)
        #expect(steps.has(call: "a") && steps.has(call: "b") && !steps.has(call: "c"))
    }

    @Test func aFailedToolMarksItsStepWhereverItIs() {
        var steps = StepQueue()
        steps.offer("Checking Stripe", app: .stripe, call: "a")
        _ = steps.next(at: Instant(seconds: 0))
        let current = steps.fail(call: "a")
        #expect(current && steps.step?.failed == true)
        steps.offer("Checking Gmail", app: .gmail, call: "b")
        _ = steps.next(at: Instant(seconds: 2))
        #expect(steps.trail.map(\.failed) == [true])
        let (known, unknown) = (steps.fail(call: "b"), steps.fail(call: "nobody"))
        #expect(known && !unknown)
    }

    @Test func aNewCallInTheSameWordsIsItsOwnStep() {
        var steps = StepQueue()
        steps.offer("Checking Gmail", app: .gmail, call: "a")
        _ = steps.next(at: Instant(seconds: 0))
        steps.offer("Checking Gmail", app: .gmail, call: "b")
        #expect(steps.has(call: "b"))
        #expect(steps.next(at: Instant(seconds: 3)).line == "Checking Gmail")
        #expect(steps.since == Instant(seconds: 3))
        let failed = steps.fail(call: "b")
        #expect(failed && steps.step?.failed == true && steps.trail.map(\.failed) == [false])
        // With no id to tell them apart, the same words twice are one step.
        steps.offer("Checking Slack")
        steps.offer("Checking Slack")
        #expect(steps.next(at: Instant(seconds: 6)).line == "Checking Slack")
        #expect(steps.next(at: Instant(seconds: 9)).line == nil)
    }

    @Test func theTrailKeepsOnlyTheLastFew() {
        var steps = StepQueue()
        for index in 0..<7 {
            steps.offer("Step \(index)", call: "c\(index)")
            _ = steps.next(at: Instant(seconds: Double(index) * 2))
        }
        #expect(steps.shown == "Step 6")
        #expect(steps.trail.map(\.line) == ["Step 3", "Step 4", "Step 5"])
        #expect(Set(steps.trail.map(\.id) + [steps.step?.id ?? 0]).count == StepQueue.trailMost + 1)
    }

    private let flights = #"""
        {"type":"flights","from":"AUS","to":"SFO","date":"Fri, Nov 14","options":[
        {"airline":"United","depart":"7:05a","arrive":"9:00a","duration":"3h 55m","price":214,"best":true,"url":"https://united.com/x"},
        {"depart":"9:40a","arrive":"11:42a","price":"$238","url":"file:///etc/passwd"},
        {"airline":"No times"}],
        "actions":["Hold the 7:05","Text me these","A third","Hold the 7:05"]}
        """#

    @Test func flightsWrittenAsDataBecomeACard() throws {
        let card = try #require(RichCard.parse(flights))
        guard case .flights(let found) = card.body else { Issue.record("not flights"); return }
        #expect(found.from == "AUS" && found.to == "SFO" && found.subtitle == "Fri, Nov 14")
        #expect(found.options.count == 2)
        #expect(found.options[0].price == "$214")
        #expect(found.options[0].detail == "United · 3h 55m")
        #expect(found.options[0].best && found.options[0].url == URL(string: "https://united.com/x"))
        // Only a web page or an Obsidian note opens on a click.
        #expect(found.options[1].url == nil && found.options[1].price == "$238" && !found.options[1].best)
        #expect(card.actions == ["Hold the 7:05", "Text me these"])
        #expect(card.key == "flights:aus-sfo")
        #expect(RichCard.parse("```json\n\(flights)\n```") == card)
    }

    @Test func aTaskAMeetingAndAnEmailBecomeRows() throws {
        let card = try #require(RichCard.parse(#"""
            [{"type":"task","id":"PP-3","title":"ProfitPilot outreach","status":"todo","due":"Nov 9","where":"vault","url":"obsidian://open?file=PP-3"},
            {"type":"event","title":"Design review","date":"2026-11-12","time":"3:00 PM","where":"Zoom"},
            {"type":"email","from":"Theo","subject":"Launch video cut","time":"2:14 PM"},
            {"type":"task","title":"Send the invoice","done":true}]
            """#))
        guard case .rows(let rows) = card.body else { Issue.record("not rows"); return }
        #expect(rows[0] == ResultRow(kind: .task(done: false), title: "PP-3 · ProfitPilot outreach", detail: "todo · due Nov 9 · vault",
                                     url: URL(string: "obsidian://open?file=PP-3"), app: .obsidian))
        #expect(rows[1] == ResultRow(kind: .event(month: "NOV", day: "12"), title: "Design review", detail: "Thu 3:00 PM · Zoom", app: .calendar))
        #expect(rows[2] == ResultRow(kind: .email, title: "Theo: “Launch video cut”", detail: "2:14 PM", app: .gmail))
        #expect(rows[3].kind == .task(done: true))
        let one = try #require(RichCard.parse(#"{"type":"task","title":"Call Theo","actions":["Mark it done"]}"#))
        #expect(one.actions == ["Mark it done"])
        #expect(ResultRow.day("Nov 12")?.day == "12")
    }

    @Test func aClickOnlyOpensAWebPageOrANote() {
        func link(_ text: String) -> URL? { RichCard.link(.string(text)) }
        for kept in ["https://united.com/x", "http://example.com", "obsidian://open?vault=Main&file=Tasks%2FPP-3", "obsidian://open?path=%2FUsers%2Fh%2Fvault%2Fa.md"] {
            #expect(link(kept) == URL(string: kept), "\(kept)")
        }
        // An Obsidian address that makes or changes a note, or runs a plugin's command, is not a link.
        for dropped in ["file:///etc/passwd", "javascript:alert(1)", "https://", "obsidian://new?vault=Main&name=x&content=y",
                        "obsidian://advanced-uri?vault=Main&commandid=app%3Adelete-file", "obsidian://open?vault=Main&file=a&commandid=x",
                        "obsidian://shell-commands/?execute=1", "x-apple.systempreferences:com.apple.preference", "ssh://host", ""] {
            #expect(link(dropped) == nil, "\(dropped)")
        }
    }

    @Test func anythingElseStaysTheCardItWas() {
        for text in ["PP-3 · ProfitPilot outreach · due Nov 9", #"{"foo":1}"#, "[1, 2]", "{not json",
                     #"[{"type":"task","title":"a"},{"type":"mystery","title":"b"}]"#, #"{"type":"flights","from":"AUS"}"#,
                     #"{"type":"task"}"#, "git switch -c live-talk"] {
            #expect(RichCard.parse(text) == nil, "\(text)")
        }
    }

    @Test func aResultTakesItsOwnPlaceAndKeepsOneLineBesideIt() throws {
        let start = Instant(seconds: 100)
        var notices = TalkIsland.adding(.text("one"), to: [], at: start)
        notices = TalkIsland.adding(.text("two"), to: notices, at: start + 1)
        notices = TalkIsland.adding(.text("three"), to: notices, at: start + 2)
        #expect(notices.map(\.key) == ["text:three", "text:two"])
        let first = try #require(RichCard.parse(#"{"type":"flights","from":"AUS","to":"SFO","options":[{"depart":"7:05a","arrive":"9:00a"}]}"#))
        let more = try #require(RichCard.parse(flights))
        notices = TalkIsland.adding(.rich(first), to: notices, at: start + 3)
        #expect(notices.map(\.key) == ["flights:aus-sfo", "text:three"])
        // The same route again is the same card with more on it.
        notices = TalkIsland.adding(.rich(more), to: notices, at: start + 4)
        #expect(notices.map(\.content) == [.rich(more), .text("three")])
        let rows = try #require(RichCard.parse(#"{"type":"task","title":"Call Theo"}"#))
        notices = TalkIsland.adding(.rich(rows), to: notices, at: start + 5)
        #expect(notices.map(\.content) == [.rich(rows), .text("three")])
        // A line goes after two minutes; a result waits ten.
        notices = TalkIsland.adding(.callBack(agent: "Hermes"), to: notices, at: start + 200)
        #expect(notices.map(\.content) == [.callBack(agent: "Hermes"), .rich(rows)])
        #expect(TalkIsland.adding(.text("late"), to: notices, at: start + 700).map(\.key) == ["text:late"])
    }

    @Test func aResultWithButtonsHoldsTheIslandOpenLongest() throws {
        let plain = try #require(RichCard.parse(#"{"type":"task","title":"Call Theo"}"#))
        let buttons = try #require(RichCard.parse(flights))
        #expect(TalkIsland.noticeHold(.text("x")) < TalkIsland.noticeHold(.callBack(agent: "Hermes")))
        #expect(TalkIsland.noticeHold(.callBack(agent: "Hermes")) < TalkIsland.noticeHold(.rich(plain)))
        #expect(TalkIsland.noticeHold(.rich(plain)) < TalkIsland.noticeHold(.rich(buttons)))
        #expect(TalkIsland.noticeHold(.rich(buttons)) < TalkIsland.noticeLife(.rich(buttons)))
    }

    @Test func theIslandFoldsDownOnALongStepAndCarriesIt() {
        let step = TalkStep(line: "Checking Gmail", app: .gmail, id: 1)
        let bar = TalkBar(agent: hermes, phase: .thinking, activity: "Checking Gmail", step: step, since: Instant(seconds: 10))
        #expect(!TalkIsland.isSettled(bar, at: Instant(seconds: 10 + TalkIsland.settleAfter - 1)))
        #expect(TalkIsland.isSettled(bar, at: Instant(seconds: 10 + TalkIsland.settleAfter)))
        #expect(TalkIsland.isOpen(bar, hovering: false))
        #expect(!TalkIsland.isOpen(bar, hovering: false, settled: true))
        #expect(TalkIsland.isOpen(bar, hovering: true, settled: true))
        #expect(TalkIsland.showsStep(bar))
        // A question it waits on you for never folds away.
        let asking = TalkBar(agent: hermes, phase: .thinking, activity: "Waiting for your OK", since: Instant(seconds: 10))
        #expect(!TalkIsland.isSettled(asking, at: Instant(seconds: 500)))
        #expect(!TalkIsland.showsStep(asking))
        let speaking = TalkBar(agent: hermes, phase: .speaking, line: "Done.", step: step, since: Instant(seconds: 10))
        #expect(!TalkIsland.isSettled(speaking, at: Instant(seconds: 500)) && !TalkIsland.showsStep(speaking))
    }

    @Test func theClosedIslandWidensForAStepAndStaysNarrowerThanOpen() {
        let notched = TalkIsland.Screen(hasNotch: true, notchWidth: 185, barHeight: 32)
        for screen in [notched, TalkIsland.Screen.plain] {
            #expect(TalkIsland.compactWidth(screen, step: true) > TalkIsland.compactWidth(screen))
            #expect(TalkIsland.compactWidth(screen, step: true) <= TalkIsland.openWidth(screen))
        }
        // The notch itself never changes.
        #expect(TalkIsland.centerWidth(notched, step: true) == 185)
    }

    @Test func theTimerReadsLikeAClock() {
        #expect(TalkIsland.elapsed(42) == "0:42")
        #expect(TalkIsland.elapsed(134.9) == "2:14")
        #expect(TalkIsland.elapsed(3725) == "1:02:05")
        #expect(TalkIsland.elapsed(-3) == "0:00")
    }

    @Test func theAgentCanClearWhatItShowed() {
        #expect(TalkPrompt.note.contains("<show>clear</show>"))
        for body in ["clear", " Clear\n", "CLEAR.", "clear screen"] { #expect(TalkPrompt.isClear(body), "\(body)") }
        for body in ["clear skies all week", "https://clear.example.com", "<p>clear</p>"] { #expect(!TalkPrompt.isClear(body), "\(body)") }
    }

    @Test func theAgentIsToldHowToShowACard() throws {
        for word in [#""type":"flights""#, #""type":"task""#, #""type":"event""#, #""type":"email""#, #""actions""#] {
            #expect(TalkPrompt.note.contains(word), "\(word)")
        }
        // The example it is given is one the island draws.
        let start = try #require(TalkPrompt.note.range(of: #"{"type":"flights""#))
        let end = try #require(TalkPrompt.note.range(of: #""actions":["Hold the 7:05"]}"#))
        #expect(RichCard.parse(String(TalkPrompt.note[start.lowerBound..<end.upperBound])) != nil)
    }
}
