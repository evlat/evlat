import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// News kept quiet while the user is at the session's tab (`isAtTab`): the
/// face, the ring and the news stay as they are, the sound and the peek do
/// not come, and nothing is taken for seen. The question is answered by the
/// test, now or later; no terminal is ever asked.
@MainActor
final class AtTabNewsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    @MainActor private final class Rig {
        let controller = AppController()
        let provider = Stub()
        var played: [AlertSound] = []
        var panel: BarPanel!
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        /// Who was asked about, in order.
        var asked: [String] = []
        /// The answer given at once; `nil` holds the question in `held`.
        var answer: Bool? = true
        var held: [(Bool) -> Void] = []

        /// The live question's parts (`live`): the server asked by the
        /// news's lookup, held to answer by hand; the server's answer
        /// walked here; the terminal asked about the app.
        var found: [DetailModel.RemoteQuery] = []
        var serverReplies: [(RemoteHost.Reply?) -> Void] = []
        /// `false`: the machine cannot be asked — no live master.
        var reachable = true
        var walked: [(RemoteHost.Reply, String)] = []
        var walk: SessionHost = .notFound
        var focused: [SessionHost.App] = []

        /// `live` keeps the controller's own question and answers its
        /// parts instead.
        init(live: Bool = false) {
            controller.now = { [unowned self] in self.now }
            controller.peekSchedule = { _, _ in }
            controller.soundTones = [.done: .evlat(.rise), .failed: .evlat(.fall),
                                     .approval: .evlat(.bell), .answer: .evlat(.question)]
            controller.soundOn = [.done: true, .failed: true, .approval: true, .answer: true]
            controller.registry.register(provider)
            panel = controller.installPanel()
            controller.playSound = { [unowned self] in self.played.append($0) }
            if live {
                controller.findRemoteForNews = { [unowned self] query, completion in
                    guard self.reachable else { return false }
                    self.found.append(query)
                    self.serverReplies.append(completion)
                    return true
                }
                controller.resolveRemoteForNews = { [unowned self] reply, machine in
                    self.walked.append((reply, machine))
                    return self.walk
                }
                controller.askTabFocus = { [unowned self] row, app, reply in
                    self.asked.append(row.entity)
                    self.focused.append(app)
                    if let answer = self.answer { reply(answer) } else { self.held.append(reply) }
                }
            } else {
                controller.isAtTab = { [unowned self] row, reply in
                    self.asked.append(row.entity)
                    if let answer = self.answer { reply(answer) } else { self.held.append(reply) }
                }
            }
            controller.refresh()
        }

        /// A remote session of `source` on the machine `d`.
        func setRemote(_ phase: Phase, source: String = "claude", machine: String = "d") {
            provider.signals = [Signal(provider: "stub", entity: "remote:\(machine):\(AtTabNewsTests.session)",
                                       phase: phase, label: "api", source: AgentID(source), fidelity: .official,
                                       updatedAt: Date(timeIntervalSince1970: 0), activity: Signal.Activity(),
                                       machine: Signal.Machine(name: "devbox", id: machine))]
            controller.refresh()
        }

        func set(_ rows: [(String, Phase)]) {
            provider.signals = rows.map {
                Signal(provider: "stub", entity: $0.0, phase: $0.1, label: $0.0, fidelity: .official,
                       updatedAt: Date(timeIntervalSince1970: 0),
                       activity: $0.1 == .waiting ? Signal.Activity(waitKind: .approval) : nil)
            }
            controller.refresh()
        }

        /// Answers the questions held, oldest first.
        func reply(_ at: Bool) {
            let replies = held
            held = []
            replies.forEach { $0(at) }
        }

        var news: [Finish] { controller.registry.snapshot(seen: controller.seen).news }
    }

    // MARK: - A finish

    /// At the tab: no sound, no peek; still news, still told once, and its
    /// reminder comes as any told finish's would — asked again then.
    func testAFinishAtItsTabIsQuietAndStillNews() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.nudgeScope = .all
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.asked, ["s"])
        XCTAssertEqual(rig.played, [])
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertEqual(rig.news.map(\.entity), ["s"], "never taken for seen")
        XCTAssertTrue(rig.controller.seen.isEmpty)
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s"], "told once, asked once")
        rig.answer = false
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s", "s"])
        XCTAssertEqual(rig.played, [.evlat(.rise)], "the reminder, away from the tab")
    }

    func testAFinishAwayFromItsTabIsToldAsAlways() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = false
        rig.controller.bodyMode = .tucked
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    func testFinishesTogetherAreToldWithoutAsking() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("a", .working), ("b", .working)])
        rig.set([("a", .review), ("b", .failed)])
        XCTAssertEqual(rig.asked, [])
        XCTAssertEqual(rig.played, [.evlat(.fall)])
    }

    /// Nothing to keep quiet, nothing asked: its sound off and a body that
    /// shows no finish. Under Tucked its peek would show it. With the peek
    /// off the sliver's dot is the row's state, which is no news to keep
    /// quiet — unless a wait's amber covers it, and the dot tells the finish.
    func testAFinishThatWouldShowNothingAsksNothing() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.soundOn[.done] = false
        for mode in [BodyPresence.Mode.always, .hidden] {
            rig.controller.bodyMode = mode
            rig.set([("s-\(mode)", .working)])
            rig.set([("s-\(mode)", .review)])
        }
        XCTAssertEqual(rig.asked, [])
        rig.controller.bodyMode = .tucked
        rig.set([("t", .working)])
        rig.set([("t", .review)])
        XCTAssertEqual(rig.asked, ["t"], "its peek")
        rig.controller.bodyToggles.peekDone = false
        rig.set([("u", .working)])
        rig.set([("u", .review)])
        XCTAssertEqual(rig.asked, ["t"], "the dot already shows the review")
        rig.controller.bodyToggles.peekWaiting = false
        rig.controller.soundOn[.approval] = false
        rig.set([("w", .waiting), ("v", .working)])
        rig.set([("w", .waiting), ("v", .review)])
        XCTAssertEqual(rig.asked, ["t", "v"], "the dot tells it over the amber")
    }

    /// A late "no" tells the finish if nothing moved meanwhile.
    func testALateAnswerTellsAFinishStillUnwatched() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [], "waiting for the answer")
        rig.reply(false)
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    /// What the user saw while the question was out is not told late: the
    /// bar opened, or the row moved on.
    func testALateAnswerDoesNotTellWhatMovedMeanwhile() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        rig.controller.openBar()
        rig.reply(false)
        XCTAssertEqual(rig.played, [])
        rig.controller.closeBar()
        rig.set([("t", .working)])
        rig.set([("t", .review)])
        rig.set([("t", .working)])
        rig.reply(false)
        XCTAssertEqual(rig.played, [], "no longer news")
        XCTAssertNil(rig.controller.peekPhase)
    }

    // MARK: - A remote session

    static let session = "8087b2ed-d738-42da-abf1-8693d1094eda"
    private var entity: String { "remote:d:\(Self.session)" }

    private static func reply(direct: Bool) -> RemoteHost.Reply {
        .connection(RemoteHost.Connection(clientPort: 19554, serverPort: 22, startedAt: Date(timeIntervalSince1970: 0),
                                          offset: 0, forwarded: ["LC_BATERI_TAB_URL=bateri://tab/T"], direct: direct))
    }

    private let bateri = SessionHost.App(bundleID: "dev.bateri.bateri", name: "bateri", pid: 580,
                                         tab: URL(string: "bateri://tab/9F6818EC-BBCE-41B8-8818-571597ADAEE2"))

    /// A connected machine's Claude Code session, walked on its server from
    /// the agent itself: its server is asked by the news's own lookup, the
    /// answer is walked here, and the terminal is asked about the tab the
    /// walk found. At it, the finish is quiet.
    func testARemoteFinishAtItsTabAsksItsTerminal() throws {
        let rig = Rig(live: true)
        defer { rig.panel.close() }
        rig.walk = .app(bateri)
        rig.setRemote(.working)
        rig.setRemote(.review)
        let query = try XCTUnwrap(rig.found.first)
        XCTAssertEqual(rig.found.count, 1)
        XCTAssertEqual(query.machineID, "d")
        XCTAssertEqual(query.sessionID, Self.session)
        XCTAssertEqual(rig.played, [], "waiting for the server")
        rig.serverReplies.removeFirst()(Self.reply(direct: true))
        XCTAssertEqual(rig.walked.map(\.1), ["d"])
        XCTAssertEqual(rig.focused, [bateri])
        XCTAssertEqual(rig.asked, [entity])
        XCTAssertEqual(rig.played, [], "at its tab")
        XCTAssertEqual(rig.news.map(\.entity), [entity], "never taken for seen")
    }

    func testARemoteFinishAwayFromItsTabIsTold() {
        let rig = Rig(live: true)
        defer { rig.panel.close() }
        rig.walk = .app(bateri)
        rig.answer = false
        rig.setRemote(.working)
        rig.setRemote(.review)
        rig.serverReplies.removeFirst()(Self.reply(direct: true))
        XCTAssertEqual(rig.focused, [bateri])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
    }

    /// The server walked from a pane's client, or herdr's bridge: the tab
    /// is not sure, so nothing is walked or asked here, and it is told.
    func testARemoteAnswerFromAClientAsksNoTerminal() {
        let rig = Rig(live: true)
        defer { rig.panel.close() }
        rig.walk = .app(bateri)
        rig.setRemote(.working)
        rig.setRemote(.review)
        rig.serverReplies.removeFirst()(Self.reply(direct: false))
        XCTAssertTrue(rig.walked.isEmpty)
        XCTAssertEqual(rig.asked, [])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
    }

    /// No live master: nothing asked, told at once. A server that did not
    /// answer in time, or a walk that finds no tab here: told.
    func testARemoteFinishThatCannotBeAskedIsTold() {
        let rig = Rig(live: true)
        defer { rig.panel.close() }
        rig.reachable = false
        rig.setRemote(.working)
        rig.setRemote(.review)
        XCTAssertEqual(rig.played, [.evlat(.rise)], "the machine is not connected")

        let late = Rig(live: true)
        defer { late.panel.close() }
        late.setRemote(.working)
        late.setRemote(.review)
        late.serverReplies.removeFirst()(nil)
        XCTAssertEqual(late.asked, [])
        XCTAssertEqual(late.played, [.evlat(.rise)], "no answer in time")

        let nowhere = Rig(live: true)
        defer { nowhere.panel.close() }
        nowhere.setRemote(.working)
        nowhere.setRemote(.review)
        nowhere.serverReplies.removeFirst()(Self.reply(direct: true))
        XCTAssertEqual(nowhere.walked.count, 1)
        XCTAssertEqual(nowhere.asked, [], "no tab found here")
        XCTAssertEqual(nowhere.played, [.evlat(.rise)])
    }

    /// An agent that keeps no session records (Codex) has nothing to ask
    /// its server, and a sandbox's session has no server: told at once.
    func testARemoteRowWithNothingToAskIsToldAtOnce() {
        let rig = Rig(live: true)
        defer { rig.panel.close() }
        rig.setRemote(.working, source: "codex")
        rig.setRemote(.review, source: "codex")
        XCTAssertEqual(rig.found, [])
        XCTAssertEqual(rig.played, [.evlat(.rise)])

        let sandbox = Rig(live: true)
        defer { sandbox.panel.close() }
        sandbox.setRemote(.working, machine: SandboxListener.identity.id)
        sandbox.setRemote(.review, machine: SandboxListener.identity.id)
        XCTAssertEqual(sandbox.found, [])
        XCTAssertEqual(sandbox.played, [.evlat(.rise)])
    }

    // MARK: - A wait

    func testAWaitBeginningAtItsTabIsQuiet() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        XCTAssertEqual(rig.asked, ["s"])
        XCTAssertEqual(rig.played, [])
        XCTAssertEqual(rig.controller.mascot.phase, .waiting, "the face is the registry's")
    }

    func testAWaitAnsweredBeforeTheAnswerIsNotTold() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.set([("s", .working)])
        rig.reply(false)
        XCTAssertEqual(rig.played, [])
    }

    /// Due at its tab: no reminder, timed again; due once more after the
    /// same minutes, and away from the tab then, it speaks.
    func testAWaitDueAtItsTabIsTimedAgain() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s", "s"])
        XCTAssertEqual(rig.played, [])
        rig.now += 119
        rig.controller.refresh()
        XCTAssertEqual(rig.asked.count, 2, "not before the minutes again")
        rig.answer = false
        rig.now += 1
        rig.controller.refresh()
        XCTAssertEqual(rig.asked.count, 3)
        XCTAssertEqual(rig.played, [.evlat(.bell)])
    }

    /// The reminder is the user's to have asked for: it speaks on the open
    /// bar as it always did, a late answer included.
    func testAWaitDueAwayFromItsTabSpeaksOnTheOpenBarToo() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.answer = nil
        rig.controller.openBar()
        rig.now += 120
        rig.controller.refresh()
        rig.reply(false)
        XCTAssertEqual(rig.played, [.evlat(.bell)])
    }
}
