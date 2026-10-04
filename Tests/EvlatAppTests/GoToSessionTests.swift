import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// `[Go to session]`: when the terminal is looked up, what the button says,
/// and what a click on it does. The lookup and the activation are injected —
/// no test here walks this machine's processes or brings an app forward.
@MainActor
final class GoToSessionTests: XCTestCase {
    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    private let term = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
    private var resolved: [Int32?] = []
    private var activated: [SessionHost.App] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        resolved = []
        activated = []
    }

    private func signal(_ entity: String, pid: Int32? = 900) -> Signal {
        Signal(provider: "stub", entity: entity, phase: .waiting, label: entity,
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(pid: pid))
    }

    private func controller(_ signals: [Signal], host: @escaping () -> SessionHost) -> (AppController, Stub) {
        let controller = AppController()
        let provider = Stub()
        provider.signals = signals
        controller.registry.register(provider)
        controller.detail.resolveHost = { [unowned self] pid in self.resolved.append(pid); return host() }
        controller.detail.activate = { [unowned self] app in self.activated.append(app); return true }
        controller.installPanel()
        controller.refresh()
        return (controller, provider)
    }

    // MARK: - When the lookup runs

    func testTheTerminalIsLookedUpWhenTheCardComesUpNotOnEverySnapshot() {
        let (controller, provider) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        XCTAssertEqual(resolved, [900])
        XCTAssertEqual(controller.detail.detail?.host, .app(term))
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(resolved, [900], "the poll does not walk the processes again")

        provider.signals = [signal("a", pid: 901)]   // `claude --resume`: a new pid
        controller.refresh()
        XCTAssertEqual(resolved, [900, 901])

        controller.closeBar()
        controller.select("a")
        XCTAssertEqual(resolved, [900, 901, 901], "a card that comes up again looks again")
    }

    // MARK: - The click

    func testGoBringsTheAppForwardAndClosesTheListAndCard() {
        let (controller, _) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        controller.goToSession()
        XCTAssertEqual(activated, [term])
        XCTAssertEqual(resolved.count, 2, "looked up again at the click")
        XCTAssertFalse(controller.barState.isOpen)
        XCTAssertNil(controller.barState.selected)
    }

    /// Going to a finished session is seeing it: its row goes passive at
    /// once, however briefly the bar was open, and stays on the list.
    func testGoingToAFinishSeesIt() {
        let finished = Signal(provider: "stub", entity: "a", phase: .review, label: "a",
                              fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
                              activity: Signal.Activity(pid: 900))
        let (controller, _) = controller([finished]) { .app(self.term) }
        defer { controller.panel?.close() }
        XCTAssertEqual(controller.mascot.phase, .review)
        controller.select("a")
        controller.goToSession()
        XCTAssertEqual(controller.mascot.phase, .idle)
        XCTAssertFalse(controller.mascot.hasLive)
        XCTAssertEqual(controller.sessionRows.rows.map(\.entity), ["a"], "a session is not let go")
    }

    /// The app quit after the card came up: the click opens nothing, and the
    /// card now says the app is closed.
    func testAnAppThatQuitSinceIsSaidNotOpened() {
        var host = SessionHost.app(term)
        let (controller, _) = controller([signal("a")]) { host }
        defer { controller.panel?.close() }
        controller.select("a")
        host = .closed(name: "Metalterm")
        controller.goToSession()
        XCTAssertEqual(activated, [])
        XCTAssertEqual(controller.detail.detail?.host, .closed(name: "Metalterm"))
        XCTAssertTrue(controller.barState.isOpen, "nothing happened elsewhere: the card stays")
        XCTAssertEqual(controller.barState.selected, "a")
    }

    /// The button is hit by geometry, like the rows: its drawn rectangle is
    /// reported by the card and a click inside it goes to the session.
    func testAClickOnTheButtonsRectangleGoes() throws {
        let (controller, _) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        let button = CGRect(x: 40, y: 300, width: 230, height: 28)
        controller.goButtonFrameChanged(button)
        let onClick = try XCTUnwrap(controller.panel?.onClick)
        XCTAssertFalse(onClick(CGPoint(x: 40 - 1, y: 310)), "beside it: not ours")
        XCTAssertEqual(activated, [])
        XCTAssertTrue(onClick(CGPoint(x: 60, y: 310)))
        XCTAssertEqual(activated, [], "the press is drawn first")
        RunLoop.main.run(until: Date().addingTimeInterval(AppController.pressFeedback + 0.1))
        XCTAssertEqual(activated, [term])

        controller.goButtonFrameChanged(nil)
        XCTAssertFalse(onClick(CGPoint(x: 60, y: 310)), "no card, no button")
    }

    // MARK: - A remote row

    private func remote(_ entity: String) -> Signal {
        Signal(provider: "stub", entity: entity, phase: .waiting, label: "api",
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(), machine: Signal.Machine(name: "devbox"))
    }

    /// A remote session runs in a terminal on another computer: there is
    /// nothing on this Mac to look up or bring forward, so the card has no
    /// button at all — not the "terminal not found" one.
    func testARemoteRowLooksNothingUpAndGoesNowhere() throws {
        let (controller, _) = controller([remote("remote:d:1")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("remote:d:1")
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertEqual(detail.machine, "devbox")
        XCTAssertFalse(DetailCard.showsButton(detail), "no button, no terminal")
        XCTAssertNil(DetailCard.terminal(detail.host))
        XCTAssertFalse(controller.detail.go())
        controller.goToSession()
        XCTAssertEqual(resolved, [], "no process walk for a remote row")
        XCTAssertEqual(activated, [])
        XCTAssertTrue(controller.barState.isOpen, "nothing happened elsewhere: the card stays")
    }

    /// From a local card to a remote one: the old button's rectangle does not
    /// linger as a place to click.
    func testTheButtonsRectangleGoesWithARemoteCard() throws {
        let (controller, _) = controller([signal("a"), remote("remote:d:1")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
        controller.goButtonFrameChanged(CGRect(x: 40, y: 300, width: 230, height: 28))
        controller.select("remote:d:1")
        controller.goButtonFrameChanged(nil)   // the button's `onDisappear`
        let onClick = try XCTUnwrap(controller.panel?.onClick)
        XCTAssertFalse(onClick(CGPoint(x: 60, y: 310)))
        XCTAssertEqual(activated, [])
    }

    // MARK: - A remote row that can be asked

    private static let session = "8087b2ed-d738-42da-abf1-8693d1094eda"

    /// A remote Claude session on a machine with an id: its server can be
    /// asked where it runs (`RemoteHost`).
    private func askable(machine: String = "d", source: AgentID? = AgentID("claude")) -> Signal {
        Signal(provider: "stub", entity: "remote:\(machine):\(Self.session)", phase: .waiting, label: "api",
               detail: "/srv/api", source: source, fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(), machine: Signal.Machine(name: "devbox", id: machine))
    }

    private let found = RemoteHost.Reply.connection(
        RemoteHost.Connection(clientPort: 19554, serverPort: 22, startedAt: Date(timeIntervalSince1970: 0), offset: 0))

    /// The asks, and their completions to answer by hand: the server's
    /// answer arrives later, on the main queue.
    private var asked: [DetailModel.RemoteQuery] = []
    private var pending: [(RemoteHost.Reply?) -> Void] = []
    private var walked: [(RemoteHost.Reply, String)] = []

    private func remoteController(_ signals: [Signal], reachable: Bool = true,
                                  host: SessionHost? = nil) -> (AppController, Stub) {
        let (controller, provider) = controller(signals) { .app(self.term) }
        asked = []
        pending = []
        walked = []
        controller.detail.findRemote = { [unowned self] query, completion in
            guard reachable else { return false }
            self.asked.append(query)
            self.pending.append(completion)
            return true
        }
        controller.detail.resolveRemote = { [unowned self] reply, machine in
            self.walked.append((reply, machine))
            return host ?? .app(self.term)
        }
        return (controller, provider)
    }

    /// Asked once when the card comes up, with no button and no words while
    /// it is; the answer brings the button. Polls ask nothing more.
    func testARemoteCardAsksItsServerOnceAndShowsTheButtonWhenFound() throws {
        let (controller, _) = remoteController([askable()])
        defer { controller.panel?.close() }
        controller.select("remote:d:\(Self.session)")
        XCTAssertEqual(asked, [DetailModel.RemoteQuery(
            machineID: "d", sessionID: Self.session,
            records: SessionRecords(directory: ".claude/sessions", idKey: "sessionId", pidKey: "pid",
                                    startedAtKey: "startedAt"))])
        var detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertTrue(detail.searching)
        XCTAssertFalse(DetailCard.showsButton(detail), "searching draws no button")
        XCTAssertNil(DetailCard.terminal(detail.host))

        pending[0](found)
        detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertFalse(detail.searching)
        XCTAssertEqual(detail.host, .app(term))
        XCTAssertTrue(DetailCard.showsButton(detail))
        XCTAssertEqual(walked.map(\.1), ["d"])

        controller.refresh()
        controller.refresh()
        XCTAssertEqual(asked.count, 1, "the poll does not ask the server again")
        XCTAssertEqual(resolved, [], "a remote pid is never walked here")
    }

    /// The click walks this Mac again from the kept answer; the server is
    /// not asked a second time.
    func testGoWalksAgainWithoutAskingTheServer() {
        let (controller, _) = remoteController([askable()])
        defer { controller.panel?.close() }
        var selects = 0
        controller.detail.selectRemote = { _, _ in selects += 1; return true }
        controller.select("remote:d:\(Self.session)")
        pending[0](found)
        controller.goToSession()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(selects, 0, "in no herdr pane: nothing to select")
        XCTAssertEqual(walked.count, 2, "once on the answer, once on the click")
        XCTAssertEqual(activated, [term])
        XCTAssertFalse(controller.barState.isOpen)
    }

    // MARK: - A remote herdr pane

    private var selects: [DetailModel.RemoteQuery] = []
    private var selected: [() -> Void] = []
    private var waits: [(TimeInterval, () -> Void)] = []

    /// A remote card answered with a herdr pane, its select and its wait
    /// held to answer by hand.
    private func herdrController(asks: Bool = true, pane: RemoteHost.Pane = .selectable) -> AppController {
        let (controller, _) = remoteController([askable()])
        // The walk carries the server's pane to the app, as `Ssh` does.
        controller.detail.resolveRemote = { [unowned self] reply, machine in
            self.walked.append((reply, machine))
            guard case .connection(let connection) = reply else { return .notFound }
            var app = self.term
            app.serverPane = connection.herdrPane
            return .app(app)
        }
        selects = []
        selected = []
        waits = []
        controller.detail.selectRemote = { [unowned self] query, completion in
            guard asks else { return false }
            self.selects.append(query)
            self.selected.append(completion)
            return true
        }
        controller.detail.waitForSelect = { [unowned self] wait, then in self.waits.append((wait, then)) }
        controller.select("remote:d:\(Self.session)")
        pending[0](.connection(RemoteHost.Connection(clientPort: 19554, serverPort: 22,
                                                     startedAt: Date(timeIntervalSince1970: 0), offset: 0,
                                                     herdrPane: pane)))
        return controller
    }

    /// The app as the walk gives it, with the server's pane.
    private var herdrTerm: SessionHost.App {
        var app = term
        app.serverPane = .selectable
        return app
    }

    /// The click asks the server to select the pane, and the window waits
    /// for it — not on the main queue, at most a second — so it comes up
    /// on the pane. The bar closes at once.
    func testARemoteHerdrPaneIsSelectedBeforeTheWindowComes() {
        let controller = herdrController()
        defer { controller.panel?.close() }
        controller.goToSession()
        XCTAssertEqual(selects, asked, "the same session, the same machine")
        XCTAssertEqual(activated, [], "the window waits for the selection")
        XCTAssertFalse(controller.barState.isOpen)
        XCTAssertEqual(waits.map(\.0), [DetailModel.selectWait])
        XCTAssertEqual(DetailModel.selectWait, 1)
        selected[0]()
        XCTAssertEqual(activated, [herdrTerm])
        waits[0].1()
        XCTAssertEqual(activated, [herdrTerm], "once")
    }

    /// A server slower than the wait: the window comes anyway, and the
    /// late answer brings nothing more. One that could not select brings
    /// the window just the same.
    func testTheWindowComesWhenTheWaitIsOverOrTheSelectionFailed() {
        var controller = herdrController()
        controller.goToSession()
        waits[0].1()
        XCTAssertEqual(activated, [herdrTerm])
        selected[0]()
        XCTAssertEqual(activated, [herdrTerm], "a late answer does nothing")
        controller.panel?.close()

        activated = []
        controller = herdrController()
        defer { controller.panel?.close() }
        controller.goToSession()
        selected[0]()
        XCTAssertEqual(activated, [herdrTerm], "answered, selected or not: the window comes")
    }

    /// No tunnel to select through: the window comes at once. A pane herdr
    /// would not select is not waited for, nor asked about — the card did
    /// not promise it; a remote session in no herdr pane asks nothing
    /// (`testGoWalksAgainWithoutAskingTheServer`).
    func testWithoutATunnelOrAPaneToSelectTheWindowComesAtOnce() {
        var controller = herdrController(asks: false)
        controller.goToSession()
        XCTAssertEqual(activated, [herdrTerm])
        XCTAssertEqual(waits.count, 0)
        controller.panel?.close()

        activated = []
        controller = herdrController(pane: .unselectable)
        defer { controller.panel?.close() }
        controller.goToSession()
        var unselectable = term
        unselectable.serverPane = .unselectable
        XCTAssertEqual(activated, [unselectable])
        XCTAssertEqual(selects, [])
        XCTAssertEqual(waits.count, 0)
    }

    /// Nothing found, no tunnel to ask through, an answer of no connection,
    /// an agent that keeps no records: no button, and nothing pretends to
    /// search.
    func testARemoteCardWithNothingFoundHasNoButton() throws {
        var (controller, _) = remoteController([askable()], host: .notFound)
        controller.select("remote:d:\(Self.session)")
        pending[0](nil)
        var detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertFalse(detail.searching)
        XCTAssertFalse(DetailCard.showsButton(detail))
        XCTAssertEqual(walked.count, 0, "no answer, no walk")
        XCTAssertFalse(controller.detail.go())
        controller.panel?.close()

        (controller, _) = remoteController([askable()], reachable: false)
        controller.select("remote:d:\(Self.session)")
        detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertFalse(detail.searching, "no tunnel: nothing to wait for")
        XCTAssertFalse(DetailCard.showsButton(detail))
        controller.panel?.close()

        (controller, _) = remoteController([askable(source: AgentID("codex"))])
        defer { controller.panel?.close() }
        controller.select("remote:d:\(Self.session)")
        XCTAssertEqual(asked, [], "an agent without records is not asked about")
        XCTAssertFalse(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
    }

    /// A card that came up while its tunnel was down asks once it is up:
    /// a call that could not be made is no answer. The answer then holds.
    func testACardAsksOnceItsTunnelIsUp() throws {
        let (controller, _) = remoteController([askable()], reachable: false)
        defer { controller.panel?.close() }
        controller.select("remote:d:\(Self.session)")
        XCTAssertFalse(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
        XCTAssertEqual(asked, [])

        controller.detail.findRemote = { [unowned self] query, completion in
            self.asked.append(query)
            self.pending.append(completion)
            return true
        }
        controller.refresh()
        XCTAssertEqual(asked.count, 1, "the tunnel is back: asked")
        pending[0](found)
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
        controller.refresh()
        XCTAssertEqual(asked.count, 1, "answered: not asked again")
    }

    /// An answer that comes after its card closed draws nothing on the
    /// next one; the reopened card asks afresh.
    func testALateAnswerIsDropped() throws {
        let (controller, _) = remoteController([askable(), signal("a")])
        defer { controller.panel?.close() }
        controller.select("remote:d:\(Self.session)")
        controller.select("a")
        pending[0](found)
        XCTAssertEqual(walked.count, 0)
        XCTAssertEqual(controller.detail.detail?.entity, "a")
        controller.select("remote:d:\(Self.session)")
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(try XCTUnwrap(controller.detail.detail).searching)
    }

    /// A remote card answers no permission and names no branch: both are
    /// this Mac's (`hasLocalHost`).
    func testARemoteCardHasNoApprovalOrBranch() throws {
        let model = DetailModel()
        model.findRemote = { _, _ in true }
        model.resolveBranch = { _ in "main" }
        let request = HeldRequest(id: "p-1", token: nil, tool: "Bash", subject: nil, questions: nil,
                                  input: Data("{}".utf8))
        let signal = askable()
        model.update(row: SessionRow(signal), signal: signal,
                     approval: SessionDetail.ApprovalCard(request, armed: true))
        let detail = try XCTUnwrap(model.detail)
        XCTAssertTrue(detail.hasRemoteHost)
        XCTAssertFalse(detail.hasLocalHost)
        XCTAssertNil(detail.approval)
        XCTAssertNil(detail.branch)
    }

    func testCloseNowClosesThroughTheIntent() {
        var changes: [Bool] = []
        var scheduled: [DispatchWorkItem] = []
        let intent = HoverIntent { _, item in scheduled.append(item) }
        intent.onChange = { changes.append($0) }
        intent.closeNow()
        XCTAssertEqual(changes, [], "already closed")
        intent.openNow()
        intent.closeNow()
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(changes, [true, false])
        intent.pointerEntered()
        XCTAssertEqual(scheduled.count, 1, "the next enter opens again")
    }

    // MARK: - What the card says

    func testTheButtonsThreeStates() {
        XCTAssertEqual(DetailCard.button(for: .app(term), in: "tr"),
                       .init(title: "Metalterm ile aç", enabled: true), "named by where it goes")
        XCTAssertEqual(DetailCard.button(for: .app(term), in: "en"),
                       .init(title: "Open in Metalterm", enabled: true))
        XCTAssertEqual(DetailCard.button(for: .closed(name: "Orca"), in: "tr"),
                       .init(title: "Orca kapalı", enabled: false))
        XCTAssertEqual(DetailCard.button(for: .notFound, in: "tr"),
                       .init(title: "Terminal bulunamadı", enabled: false))
        XCTAssertEqual(DetailCard.button(for: .closed(name: "Orca"), in: "en"),
                       .init(title: "Orca is closed", enabled: false))
    }

    /// Through herdr the button promises the session only when its pane
    /// will be selected; otherwise it names herdr, which is what comes up.
    func testTheButtonNamesHerdrWhenItsPaneCannotBeSelected() {
        var app = term
        app.herdr = .pane(HerdrPane(socket: "/s", pane: "w1:p1"))
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"), .init(title: "Open in Metalterm", enabled: true))
        for lookup in [HerdrLookup.noSocket, .timeout, .unsupported, .noMatch, .ambiguous] {
            app.herdr = lookup
            XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"),
                           .init(title: "Open herdr in Metalterm", enabled: true), "\(lookup)")
            XCTAssertEqual(DetailCard.button(for: .app(app), in: "tr"),
                           .init(title: "herdr'ı Metalterm ile aç", enabled: true), "\(lookup)")
        }
    }

    /// A server's herdr pane follows the same rule: the button promises
    /// the session only when every pane on the way will be selected — the
    /// server's, and a local one the user's `ssh` runs in.
    func testTheButtonNamesHerdrWhenTheServersPaneCannotBeSelected() {
        var app = term
        app.serverPane = .selectable
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"), .init(title: "Open in Metalterm", enabled: true))
        app.serverPane = .unselectable
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"),
                       .init(title: "Open herdr in Metalterm", enabled: true))
        app.herdr = .pane(HerdrPane(socket: "/s", pane: "w1:p1"))
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"),
                       .init(title: "Open herdr in Metalterm", enabled: true), "the local pane alone is not the session")
        app.serverPane = .selectable
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"), .init(title: "Open in Metalterm", enabled: true))
        app.herdr = .noMatch
        XCTAssertEqual(DetailCard.button(for: .app(app), in: "en"),
                       .init(title: "Open herdr in Metalterm", enabled: true))
    }

    func testTheFooterEndsWithTheTerminal() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(DetailCard.footer(enteredAt: now.addingTimeInterval(-125),
                                         activity: .init(toolCount: 12), terminal: "Ghostty",
                                         now: now, in: "tr"),
                       "2 dk · 12 araç · Ghostty")
        XCTAssertEqual(DetailCard.footer(enteredAt: nil, activity: nil, terminal: "Orca",
                                         now: now, in: "en"), "Orca")
        XCTAssertEqual(DetailCard.terminal(.app(term)), "Metalterm")
        XCTAssertEqual(DetailCard.terminal(.closed(name: "Orca")), "Orca")
        XCTAssertNil(DetailCard.terminal(.notFound))
    }

    /// `--list` names the terminal and never the pid.
    func testTheListLineNamesTheTerminal() {
        let line = AppController.listLine(signal("a", pid: 4242), host: .closed(name: "Orca"))
        XCTAssertTrue(line.hasSuffix("→ Orca (closed)"), line)
        XCTAssertFalse(line.contains("4242"), line)
    }

    // MARK: - An outside job

    private func outside(_ id: String) -> Signal {
        Signal(provider: "signal", entity: "signal:\(id)", kind: .custom, phase: .working,
               progress: 0.4, label: "render", detail: "frame 12 of 30", fidelity: .manual,
               rawStatus: "working", updatedAt: Date(timeIntervalSince1970: 0), sender: "blender")
    }

    /// An outside job has no terminal and nothing to go back to: its card
    /// looks nothing up and has no button; it carries the sender's words.
    func testAnOutsideJobsCardHasNoButtonAndLooksNothingUp() throws {
        let (controller, _) = controller([outside("r")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("signal:r")
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertEqual(detail.kind, .custom)
        XCTAssertEqual(detail.sender, "blender")
        XCTAssertEqual(detail.note, "frame 12 of 30")
        XCTAssertEqual(detail.progress, 40)
        XCTAssertNil(detail.folder)
        XCTAssertFalse(DetailCard.showsButton(detail))
        XCTAssertEqual(resolved, [], "no process walk")
        XCTAssertFalse(controller.detail.go())
        controller.goToSession()
        XCTAssertEqual(activated, [])
        XCTAssertTrue(controller.barState.isOpen, "nothing happened elsewhere: the card stays")
        XCTAssertEqual(DetailCard.progressText(40, in: "tr"), "~%40")
        XCTAssertEqual(DetailCard.progressText(40, in: "en"), "~40%")
    }

    /// A local session's card keeps its button and its lookup.
    func testASessionsCardIsUnchanged() throws {
        let (controller, _) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertTrue(DetailCard.showsButton(detail))
        XCTAssertEqual(resolved, [900])
        XCTAssertNil(detail.note)
        XCTAssertNil(detail.progress)
    }

    /// `--list` names an outside row's sender, never its detail.
    func testTheListLineNamesTheSender() {
        let line = AppController.listLine(outside("r"))
        XCTAssertTrue(line.contains("blender"), line)
        XCTAssertFalse(line.contains("frame 12"), line)
    }

    // MARK: - Evlat's own chat

    private let chatID = "6B1F3C52-7B8B-4F4B-9C1E-2B7C1D0E9A11"

    /// A controller whose chats hold one finished, unseen chat — a row on
    /// the bar — read back from a temporary root.
    private func chatController() throws -> (AppController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evlat-go-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        try ChatIndex(entries: [ChatIndex.Entry(
            id: chatID, sessionID: "S1", title: "Tidy Downloads", folder: "/tmp/somewhere", isWorkspace: false,
            createdAt: now, lastActivity: now, lastReply: "Moved 42 files.", started: true, unseen: .review)])
            .encoded().write(to: root.appendingPathComponent(ChatStore.indexName))
        let controller = AppController()
        let chats = ChatStore(root: root, platform: .unknown,
                              locator: AgentLocator(name: "claude", environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        controller.chats = chats
        controller.registry.register(chats.provider)
        controller.detail.resolveHost = { [unowned self] pid in self.resolved.append(pid); return .notFound }
        controller.detail.activate = { [unowned self] app in self.activated.append(app); return true }
        controller.installPanel()
        controller.refresh()
        return (controller, root)
    }

    /// A chat's row is a job with the mascot's face and the "Evlat" tag;
    /// its card looks for no terminal and offers `[Back to chat]`, never a
    /// dim "not found".
    func testAChatsRowAndCard() throws {
        let (controller, root) = try chatController()
        defer { controller.panel?.close(); controller.chatPanel?.close(); try? FileManager.default.removeItem(at: root) }
        let row = try XCTUnwrap(controller.sessionRows.rows.first)
        XCTAssertEqual(row.kind, .job)
        XCTAssertEqual(row.tag, "Evlat")
        XCTAssertEqual(row.label, "Tidy Downloads")
        XCTAssertNotNil(row.enteredAt, "a chat's phase time is known even when first seen in it")
        controller.select(row.entity)
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertEqual(detail.kind, .job)
        XCTAssertEqual(detail.folder, "/tmp/somewhere")
        XCTAssertNil(detail.activity?.toolCount, "no \"0 tools\"")
        XCTAssertEqual(resolved, [], "no terminal to look for")
        XCTAssertTrue(DetailCard.showsButton(detail))
        XCTAssertEqual(DetailCard.returnButton(in: "tr"), .init(title: "Sohbete dön", enabled: true))
        XCTAssertEqual(DetailCard.returnButton(in: "en"), .init(title: "Back to chat", enabled: true))
    }

    /// With the chat switched off a chat's card has no `[Back to chat]` —
    /// the balloon would not open — and a session's keeps its button.
    func testSwitchedOffAChatsCardHasNoWayBack() throws {
        let (controller, root) = try chatController()
        defer { controller.closeChat(); controller.panel?.close(); controller.chatPanel?.close()
                try? FileManager.default.removeItem(at: root) }
        let entity = try XCTUnwrap(controller.sessionRows.rows.first).entity
        controller.select(entity)
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
        controller.setChatEnabled(false)
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertFalse(DetailCard.showsButton(detail), "the open card loses it at once")
        XCTAssertNil(DetailCard.go(detail))
        controller.goToSession()
        XCTAssertFalse(controller.isChatOpen)
        XCTAssertEqual(activated, [])
        controller.setChatEnabled(true)
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))

        let (sessions, _) = self.controller([signal("a")]) { .app(self.term) }
        defer { sessions.panel?.close() }
        sessions.setChatEnabled(false)
        sessions.select("a")
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(sessions.detail.detail)), "a session's card keeps it")
    }

    /// `[Back to chat]` opens the balloon with that chat; the bar closes,
    /// nothing is activated, and the chat, now seen, goes passive and leaves
    /// the bar at its next close.
    func testBackToChatOpensTheBalloonWithIt() throws {
        let (controller, root) = try chatController()
        defer { controller.closeChat(); controller.panel?.close(); controller.chatPanel?.close()
                try? FileManager.default.removeItem(at: root) }
        controller.select(try XCTUnwrap(controller.sessionRows.rows.first).entity)
        controller.goToSession()
        XCTAssertTrue(controller.isChatOpen)
        XCTAssertEqual(controller.currentChat, chatID)
        XCTAssertFalse(controller.barState.isOpen)
        XCTAssertEqual(activated, [])
        XCTAssertEqual(controller.chatModel.messages, [.reply("Moved 42 files.")])
        XCTAssertTrue(controller.chatModel.hasChat)
        controller.refresh()
        XCTAssertEqual(controller.mascot.phase, .idle, "seen: passive")
        XCTAssertEqual(controller.sessionRows.rows.count, 1, "still on the bar until it closes")
        controller.closeChat()
        controller.openBar()
        controller.closeBar()
        XCTAssertEqual(controller.sessionRows.rows, [], "let go: in the history now")
        XCTAssertEqual(controller.chats?.history.map(\.id), [chatID])
    }

    /// A balloon opened with nothing asked for takes the chat still on the
    /// bar; `[+ New]` empties it, and once the bar's close lets the seen chat
    /// go it is in the history list.
    func testTheBalloonOpensWithAnUnseenChatAndNewEmptiesIt() throws {
        let (controller, root) = try chatController()
        defer { controller.closeChat(); controller.panel?.close(); controller.chatPanel?.close()
                try? FileManager.default.removeItem(at: root) }
        controller.openChat()
        XCTAssertEqual(controller.currentChat, chatID)
        controller.chatModel.newChat()
        XCTAssertNil(controller.currentChat)
        XCTAssertFalse(controller.chatModel.hasChat)
        controller.closeChat()
        controller.openBar()
        controller.closeBar()
        controller.openChat()
        XCTAssertNil(controller.currentChat, "seen and off the bar: an empty balloon")
        XCTAssertEqual(controller.chatModel.history.map(\.id), [chatID])
        XCTAssertEqual(controller.chatModel.history.first?.folder, "/tmp/somewhere")
        controller.chatModel.open(chatID)
        XCTAssertEqual(controller.currentChat, chatID)
        controller.chatModel.removeFromHistory(chatID)
        XCTAssertNil(controller.currentChat, "its chat gone, the balloon empties")
        XCTAssertEqual(controller.chatModel.history, [])
    }
}
