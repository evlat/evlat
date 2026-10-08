import XCTest
import AppKit
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The setup: its four steps forward and back, what "Connect" and "Finish"
/// write, what the second step hears, the launch that opens it once, and its
/// fixed size. Every writer is a real controller's under a temporary home and
/// a suite of its own, recorded on the way: the user's files, domain and login
/// item are never touched.
@MainActor
final class SetupFlowTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var login = LoginItem.inMemory()
    private var writes: [String] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.flow.\(UUID().uuidString)", isDirectory: true)
        for directory in [".claude", ".codex"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        suiteName = "evlat.tests.flow.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        login = LoginItem.inMemory()
        writes = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func controller(home: URL?) throws -> AppController {
        let controller = AppController(defaults: defaults, home: home, loginItem: LoginItem(service: login))
        controller.installPanel()
        // Evlat is not the app in front: a setup that opens by itself takes
        // no keyboard.
        controller.isFrontmost = { false }
        let contents = root.appendingPathComponent("this/Evlat.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": CommandLink.bundleID],
                                           format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let binary = contents.appendingPathComponent("MacOS/Evlat")
        try Data().write(to: binary)
        controller.executable = binary
        return controller
    }

    /// What the readings the controller owns say, and what the updater is.
    private struct World {
        var sessions: [AgentID: Int] = [:]
        var covered: Bool?
        var edgeReads = 0
        /// Agents whose write is refused (the writer does nothing).
        var refusing: Set<AgentID> = []
        /// An updater of Sparkle's kind: its own switch and the parts'.
        var updater: Bool?
        var sparkle = false
    }

    private var world = World()

    /// The controller's own writers, each call noted first.
    private func flow(_ controller: AppController, step: SetupFlowModel.Step = .agents,
                      firstRun: Bool = false) -> SetupFlowModel {
        var setup = controller.setupHost
        let agent = setup.setAgent
        let link = setup.setCommandLink, loginItem = setup.setLoginItem
        setup.setAgent = { [unowned self] in
            writes.append("agent \($0.rawValue) \($1)")
            if !world.refusing.contains($0) { agent($0, $1) }
        }
        setup.setCommandLink = { [unowned self] in writes.append("link \($0)"); link($0, $1) }
        setup.setLoginItem = { [unowned self] in writes.append("login \($0)"); loginItem($0) }
        var settings = controller.settingsHost
        let setEdge = settings.setEdge, setBody = settings.setBodyMode, setSound = settings.setSoundOn
        let setParts = settings.setKeepsPartsCurrent
        settings.setEdge = { [unowned self] in writes.append("edge \($0.isLeft ? "left" : "right")"); setEdge($0) }
        settings.setBodyMode = { [unowned self] in writes.append("body \($0.storedValue)"); setBody($0) }
        settings.setSoundOn = { [unowned self] in writes.append("sound \($0) \($1.rawValue)"); setSound($0, $1) }
        settings.preview = { [unowned self] in writes.append("preview \($0.rawValue)") }
        settings.setKeepsPartsCurrent = { [unowned self] in writes.append("parts \($0)"); setParts($0) }
        settings.openSessions = { [unowned self] in world.sessions }
        settings.edgeCovered = { [unowned self] in world.edgeReads += 1; return world.covered }
        if world.updater != nil {
            settings.hasUpdater = { true }
            settings.automaticallyUpdates = { [unowned self] in world.sparkle }
            settings.setAutomaticallyUpdates = { [unowned self] in writes.append("sparkle \($0)"); world.sparkle = $0 }
        }
        let flow = SetupFlowModel(settings: settings, setup: SetupModel(host: setup, lang: "en"),
                                  close: { [unowned self] in writes.append("close") }, lang: "en")
        flow.start(at: step, firstRun: firstRun)
        return flow
    }

    private func event(_ source: AgentID = .claude, cwd: String? = "/Users/me/evlat", task: String? = nil) -> HookEvent {
        var json: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "s-1"]
        if let cwd { json["cwd"] = cwd }
        if let task { json[HookEvent.taskKey] = task }
        return HookEvent(json: json, source: source)
    }

    // MARK: - Steps

    func testTheStepsGoForwardAndBackAndBackWritesNothing() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertEqual(flow.step, .agents)
        XCTAssertFalse(flow.showsBack)
        XCTAssertTrue(flow.showsSkip, "something to connect: not now is offered")
        XCTAssertEqual(flow.primaryKey, "setup.flow.connect")
        flow.primary()
        XCTAssertEqual(flow.step, .connected, "an agent was written: the second step asks after it")
        XCTAssertTrue(flow.showsBack)
        XCTAssertFalse(flow.showsSkip)
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        flow.primary()
        XCTAssertEqual(flow.step, .bar)
        flow.primary()
        XCTAssertEqual(flow.step, .finish)
        XCTAssertEqual(flow.primaryKey, "setup.flow.finish")
        writes = []

        flow.back()
        XCTAssertEqual(flow.step, .bar)
        flow.back()
        XCTAssertEqual(flow.step, .connected)
        flow.back()
        XCTAssertEqual(flow.step, .agents)
        flow.back()
        XCTAssertEqual(flow.step, .agents, "nothing before the first step")
        XCTAssertEqual(writes, [], "going back calls no writer")
    }

    /// Connect writes exactly the checked agents and the second step is
    /// theirs alone; the one left out is switched off.
    func testConnectWritesTheCheckedAgentsAndTheSecondStepIsTheirs() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertEqual(flow.pendingWrites, [.agent(.claude), .agent(.codex)])
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        XCTAssertEqual(writes, ["agent claude true"], "only the checked one")
        XCTAssertEqual(flow.connected, [.claude])
        XCTAssertEqual(flow.step, .connected)
        XCTAssertEqual(flow.setup.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .missing)
        XCTAssertEqual(defaults.stringArray(forKey: EnabledAgents.key), ["claude"], "the one left out is switched off")
        XCTAssertEqual(flow.setup.row(.commandLink)?.status, .missing, "the last step's item is not this step's")
        XCTAssertEqual(flow.setup.row(.loginItem)?.status, .missing)
    }

    func testAnAgentOffStartsUnchecked() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        controller.setEnabled(.codex, false)
        let flow = flow(controller)
        XCTAssertEqual(flow.tiles.map(\.selected), [true, false])
        XCTAssertEqual(flow.pendingWrites, [.agent(.claude)])
    }

    /// With nothing to connect the second step is skipped, forward and back.
    func testWithNothingConnectedTheSecondStepIsSkippedBothWays() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        for source in [AgentID.claude, .codex] { flow.setQueued(.agent(source), false) }
        XCTAssertEqual(flow.pendingWrites, [])
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        XCTAssertFalse(flow.showsSkip, "nothing to skip")
        flow.primary()
        XCTAssertEqual(flow.step, .bar)
        XCTAssertEqual(writes, [])
        flow.back()
        XCTAssertEqual(flow.step, .agents, "back skips it too")
    }

    func testAnAlreadyConnectedAgentIsNotTheSecondStepsAndAnOldOneIsUpdated() throws {
        try AgentIntegration.install(home: home, for: .codex)
        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]]])
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertTrue(flow.reopened)
        XCTAssertEqual(flow.pendingWrites, [.agent(.claude)], "the connected one is not written again")
        XCTAssertEqual(flow.primaryKey, "setup.flow.update", "only an old one to write: the button says so")
        flow.primary()
        XCTAssertEqual(writes, ["agent claude true"])
        XCTAssertEqual(flow.connected, [.claude], "Codex was connected before this visit")
        XCTAssertEqual(flow.step, .connected)
    }

    /// A refused write stays on its step; the agent whose write went in is
    /// the second step's all the same.
    func testARefusedWriteStaysOnTheFirstStep() throws {
        world.refusing = [.codex]
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.primary()
        XCTAssertEqual(flow.step, .agents)
        XCTAssertEqual(flow.connected, [.claude], "the one that went in")
        XCTAssertEqual(flow.pendingWrites, [.agent(.codex)])
        XCTAssertEqual(flow.primaryKey, "setup.flow.connect", "again")
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        XCTAssertEqual(flow.step, .connected, "nothing refused left")
    }

    /// Going back shows what was done as connected and does not undo it.
    func testGoingBackAfterConnectingKeepsIt() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.primary()
        flow.primary()
        XCTAssertEqual(flow.step, .bar)
        let before = writes
        flow.back()
        flow.back()
        XCTAssertEqual(flow.step, .agents)
        XCTAssertEqual(flow.setup.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(flow.tiles.map(\.mood), [.done, .done])
        XCTAssertTrue(flow.pendingWrites.isEmpty)
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        XCTAssertEqual(writes, before, "back undoes nothing")
        flow.primary()
        XCTAssertEqual(flow.step, .connected, "this visit's agents are still the second step's")
    }

    // MARK: - First step

    /// The tiles are the catalogue's, in its order: no fixed list of agents.
    /// One not found is not drawn.
    func testTheTilesComeFromTheCatalogueAndHideWhatIsNotFound() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertEqual(SetupFlowModel.agentItems, Set(Agents.all.ids.map(SetupItem.agent)))
        XCTAssertEqual(flow.tiles.map(\.source), [.claude, .codex], "Antigravity is not on this Mac")
        XCTAssertEqual(flow.tiles.map(\.mood), [.choice, .choice])
        XCTAssertEqual(flow.tiles.map(\.selected), [true, true], "found and switched on: checked")
        XCTAssertFalse(flow.isQueued(.agent(.antigravity)))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        XCTAssertEqual(self.flow(controller).tiles.map(\.source), [.claude])
    }

    func testTheTilesSayTheirOpenSessionsOutdatedAndConnected() throws {
        world.sessions = [.claude: 3, .codex: 1]
        try AgentIntegration.install(home: home, for: .codex)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        let claude = try XCTUnwrap(flow.tiles.first { $0.source == .claude })
        XCTAssertEqual(claude.note, "3 sessions")
        XCTAssertEqual(claude.mood, .choice)
        let codex = try XCTUnwrap(flow.tiles.first { $0.source == .codex })
        XCTAssertEqual(codex.mood, .done, "connected, untouchable")
        XCTAssertEqual(codex.note, "Connected")
        XCTAssertEqual(flow.openSessionTotal, 4, "the sentence counts every ring")

        world.sessions = [.claude: 1]
        XCTAssertEqual(self.flow(controller).tiles.first { $0.source == .claude }?.note, "1 session")
        world.sessions = [:]
        XCTAssertNil(self.flow(controller).tiles.first { $0.source == .claude }?.note)

        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]]])
        let old = try XCTUnwrap(self.flow(controller).tiles.first { $0.source == .claude })
        XCTAssertEqual(old.note, "outdated")
        XCTAssertEqual(old.tone, .caution)
        XCTAssertEqual(old.mood, .choice)
    }

    /// Opened again with something connected, the first step is "your
    /// connections", not a welcome.
    func testReopenedWithSomethingConnectedReadsAsTheConnections() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertFalse(flow(controller).reopened)
        try AgentIntegration.install(home: home, for: .claude)
        XCTAssertTrue(self.flow(controller).reopened)
    }

    // MARK: - Not now

    func testNotNowWritesTheChoiceAndNothingElse() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.setQueued(.agent(.claude), false)
        flow.skip()
        XCTAssertEqual(defaults.stringArray(forKey: EnabledAgents.key), ["codex"])
        XCTAssertEqual(writes, [], "no file")
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .missing)
        XCTAssertEqual(flow.step, .bar, "nothing was written: no second step")
    }

    // MARK: - Second step

    func testOnlyTheFirstEventOfAConnectedAgentWithoutATaskIsHeard() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.heard(event(.claude))
        XCTAssertEqual(flow.heardFrom, [:], "before Connect nothing is heard")
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        flow.heard(event(.codex))
        XCTAssertEqual(flow.heardFrom, [:], "an agent that was not connected")
        flow.heard(event(.claude, task: "t-1"))
        XCTAssertEqual(flow.heardFrom, [:], "Evlat's own chat turn")
        XCTAssertFalse(flow.allHeard)
        flow.heard(event(.claude, cwd: "/Users/me/evlat"))
        XCTAssertEqual(flow.heardFrom[.claude], SetupFlowModel.Heard(session: "evlat"))
        flow.heard(event(.claude, cwd: "/elsewhere"))
        XCTAssertEqual(flow.heardFrom[.claude], SetupFlowModel.Heard(session: "evlat"), "the first one")
        XCTAssertTrue(flow.allHeard)
        XCTAssertEqual(flow.listening.map(\.line), ["Heard · evlat"])
    }

    func testTheSecondStepAsksPerAgentAndSaysWhatItHeard() throws {
        world.sessions = [.claude: 2]
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.primary()
        XCTAssertEqual(flow.listening.map(\.source), [.claude, .codex])
        XCTAssertEqual(flow.listening[0].line, "To try it, write a message in an open session.")
        XCTAssertEqual(flow.listening[1].line, "In Codex, type /hooks and approve Evlat.", "the agent's own line")
        flow.heard(event(.codex, cwd: nil))
        XCTAssertEqual(flow.listening[1].line, "Heard", "no folder to name")
        XCTAssertTrue(flow.listening[1].heard)
        XCTAssertFalse(flow.allHeard)
    }

    func testWithoutAnOpenSessionTheGeneralLineSaysToOpenOne() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.primary()
        XCTAssertEqual(flow.listening[0].line, "To try it, open a session.")
    }

    /// A panel that closes forgets what only the second step holds, so
    /// nothing listens and no ring turns in a panel nobody sees.
    func testClosingThePanelForgetsWhatWasConnectedAndHeard() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        flow.primary()
        flow.heard(event(.claude))
        XCTAssertFalse(flow.heardFrom.isEmpty)
        flow.panelClosed()
        XCTAssertEqual(flow.connected, [])
        XCTAssertEqual(flow.heardFrom, [:])
        XCTAssertEqual(flow.step, .agents)
        flow.heard(event(.claude))
        XCTAssertEqual(flow.heardFrom, [:], "nothing is connected any more")
    }

    /// The controller's one gate for this Mac's events reaches the flow, and
    /// a flow opened again starts clean.
    func testTheControllerHandsItsHookEventsToTheFlow() throws {
        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        controller.openSetup(step: .agents)
        let flow = try XCTUnwrap(controller.setupFlow)
        flow.primary()
        XCTAssertEqual(flow.connected, [.claude, .codex])
        controller.handleHookEvent(event(.codex))
        XCTAssertEqual(Set(flow.heardFrom.keys), [.codex])
        controller.openSetup(step: .agents)
        XCTAssertEqual(flow.heardFrom, [:], "starting over")
        XCTAssertEqual(flow.connected, [])
    }

    func testTheForcedSecondStepStandsInForWhatWasConnected() throws {
        try AgentIntegration.install(home: home, for: .codex)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertEqual(flow(controller, step: .connected).connected, [.codex])
    }

    // MARK: - Bar

    func testTheEdgeAndTheVisibilityAreAppliedAtOnce() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .bar)
        XCTAssertEqual(flow.edge, .right)
        XCTAssertEqual(flow.visibility, .always)
        flow.chooseEdge(.left)
        XCTAssertEqual(writes, ["edge left"])
        XCTAssertEqual(controller.panel?.edge, .left)
        flow.chooseEdge(.left)
        XCTAssertEqual(writes, ["edge left"], "the same edge again writes nothing")
        flow.chooseVisibility(.smart)
        XCTAssertEqual(writes, ["edge left", "body smart"])
        XCTAssertEqual(controller.bodyMode, .smart)
        flow.chooseVisibility(.smart)
        XCTAssertEqual(writes.count, 2)
        flow.chooseVisibility(.always)
        XCTAssertEqual(controller.bodyMode, .always)
    }

    /// The edge is read once on entering the step and once per change of
    /// edge: no poll, no timer.
    func testTheEdgeIsReadOnEntryAndWhenItChanges() throws {
        world.covered = true
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertEqual(world.edgeReads, 0, "not on the first step")
        XCTAssertNil(flow.edgeCovered)
        flow.setQueued(.agent(.claude), false)
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        XCTAssertEqual(flow.step, .bar)
        XCTAssertEqual(world.edgeReads, 1)
        XCTAssertEqual(flow.edgeCovered, true)
        world.covered = nil
        flow.chooseEdge(.left)
        XCTAssertEqual(world.edgeReads, 1, "not before the window list can carry the move")
        XCTAssertNil(flow.edgeCovered, "and the old edge's sentence is not left up meanwhile")
        hop()
        XCTAssertEqual(world.edgeReads, 2)
        XCTAssertNil(flow.edgeCovered, "a bar not on screen says nothing")
        flow.chooseVisibility(.smart)
        hop()
        XCTAssertEqual(world.edgeReads, 2, "the visibility reads nothing")
        world.covered = true
        flow.chooseEdge(.right)
        flow.chooseEdge(.left)
        hop()
        XCTAssertEqual(world.edgeReads, 3, "two moves before the turn are one read")
        XCTAssertEqual(flow.edgeCovered, true)
    }

    /// One turn of the main queue: what a read waiting for the window list
    /// has been given.
    private func hop() {
        let turn = expectation(description: "a turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
    }

    /// A bar moved from elsewhere (the menu's edge, a screen) while the step
    /// is on screen: the sentence is read once more, a turn later.
    func testAMovedBarReadsTheEdgeOnceMoreAndOnlyOnTheBarStep() throws {
        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        var reads = 0
        controller.edgeReader = { _ in reads += 1; return true }
        controller.openSetup(step: .bar)
        let flow = try XCTUnwrap(controller.setupFlow)
        XCTAssertNil(flow.edgeCovered, "the bar may have just come on screen: a turn first")
        hop()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(flow.edgeCovered, true)
        controller.dock(.left)
        XCTAssertNil(flow.edgeCovered)
        XCTAssertEqual(reads, 1, "not before the window list can carry the move")
        hop()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(flow.edgeCovered, true)

        controller.openSetup(step: .agents)
        controller.dock(.right)
        hop()
        XCTAssertEqual(reads, 2, "another step reads nothing")
    }

    /// The controller's reading goes through the edge reader it was given,
    /// so a test never reads the user's windows.
    func testTheControllersEdgeReadingGoesThroughItsReader() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertNil(controller.readEdgeCover(), "a test's reader tells nothing")
        var strips: [EdgeCover.Strip] = []
        controller.edgeReader = { strips.append($0); return true }
        XCTAssertEqual(controller.readEdgeCover(), true)
        XCTAssertEqual(strips.count, 1)
        XCTAssertEqual(strips.first?.edge, controller.panel?.edge)
        XCTAssertEqual(controller.bodyMode, .always, "whatever the mode, and it changes nothing")
        XCTAssertFalse(controller.edgeClear)
    }

    /// The sessions the first step counts are the bar's session rows by
    /// agent: a chat or a usage window is not one.
    func testTheOpenSessionCountsAreTheSessionRowsByAgent() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        controller.registry.register(controller.hooks)
        controller.applyEnabledAgents()
        XCTAssertEqual(controller.openSessionCounts(), [:], "before the first scan")
        func session(_ id: String, _ source: AgentID) -> HookEvent {
            HookEvent(json: ["hook_event_name": "UserPromptSubmit", "session_id": id, "cwd": "/tmp/p"], source: source)
        }
        controller.handleHookEvent(session("c-1", .claude))
        controller.handleHookEvent(session("c-2", .claude))
        controller.handleHookEvent(session("x-1", .codex))
        controller.refresh()
        XCTAssertEqual(controller.openSessionCounts(), [.claude: 2, .codex: 1])
    }

    // MARK: - Finish

    func testTheSoundRowWritesBothMomentsAndThePlayHearsTheApproval() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish)
        XCTAssertFalse(flow.soundOn)
        flow.setSound(true)
        XCTAssertEqual(writes, ["sound true approval", "sound true answer"])
        XCTAssertTrue(flow.soundOn)
        XCTAssertEqual(controller.soundOn[.approval], true)
        XCTAssertEqual(controller.soundOn[.answer], true)
        XCTAssertNotEqual(controller.soundOn[.done], true, "the finishes keep their own switch")
        flow.setSound(true)
        XCTAssertEqual(writes.count, 2, "no change, no write")
        flow.previewSound()
        XCTAssertEqual(writes.last, "preview approval")
        flow.setSound(false)
        XCTAssertEqual(controller.soundOn[.answer], false)
    }

    func testOneMomentOnReadsAsOffAndASwitchOnWritesBoth() throws {
        defaults.set(true, forKey: SoundMoment.approval.onKey)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish)
        XCTAssertFalse(flow.soundOn)
        flow.setSound(true)
        XCTAssertEqual(controller.soundOn[.answer], true)
    }

    /// "Finish" writes the link (on by default) and the login item only when
    /// turned on (off by default) — nothing of the first step.
    func testFinishWritesOnlyTheCheckedItemsAndCloses() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish)
        XCTAssertEqual(flow.toggle(.commandLink), SetupFlowModel.Switch(on: true, enabled: true))
        XCTAssertEqual(flow.toggle(.loginItem), SetupFlowModel.Switch(on: false, enabled: true),
                       "open at login is off by default")
        flow.primary()
        XCTAssertEqual(writes.filter { !$0.hasPrefix("parts") }, ["link true", "close"])
        XCTAssertEqual(flow.setup.row(.agent(.claude))?.status, .missing)
    }

    func testTheLoginItemIsWrittenWhenCheckedAndAnInstalledOneIsNotAnOffer() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish)
        flow.setQueued(.loginItem, true)
        flow.setQueued(.commandLink, false)
        flow.primary()
        XCTAssertTrue(writes.contains("login true"))
        XCTAssertFalse(writes.contains("link true"))
        let again = self.flow(controller, step: .finish)
        XCTAssertEqual(again.toggle(.loginItem), SetupFlowModel.Switch(on: true, enabled: false), "set up: shown, not offered")
    }

    // MARK: - Update automatically

    /// A first run shows the row on and writes what it shows, so nothing
    /// stored (off) becomes the choice made. Without an updater only the
    /// parts' setting is there to write.
    func testAFirstRunWritesTheRowItShowedAndWithoutAnUpdaterOnlyTheParts() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish, firstRun: true)
        XCTAssertTrue(flow.autoUpdate)
        XCTAssertFalse(flow.offersUpdater)
        flow.primary()
        XCTAssertEqual(updateWrites, ["parts true"])
        XCTAssertEqual(controller.updatesAutomatic, true)
    }

    func testAFirstRunWithTheRowTurnedOffWritesOff() throws {
        world.updater = true
        world.sparkle = true
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish, firstRun: true)
        flow.autoUpdate = false
        flow.primary()
        XCTAssertEqual(updateWrites, ["sparkle false", "parts false"], "the updater's switch and the parts' together")
        XCTAssertFalse(world.sparkle)
    }

    func testAFirstRunWithAnUpdaterWritesBothOn() throws {
        world.updater = true
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .finish, firstRun: true)
        XCTAssertTrue(flow.offersUpdater)
        flow.primary()
        XCTAssertEqual(updateWrites, ["sparkle true", "parts true"])
    }

    /// Opened again, the row starts from what is set and writes a change
    /// only: a mixed state is not closed without being asked.
    func testAReopenedFlowWritesTheRowOnlyWhenItChanged() throws {
        world.updater = true
        world.sparkle = true
        defaults.set(false, forKey: AppController.updatesAutomaticKey)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let mixed = flow(controller, step: .finish)
        XCTAssertFalse(mixed.autoUpdate, "the updater on and the parts off: not both on")
        mixed.primary()
        XCTAssertEqual(updateWrites, [], "untouched: not written")

        writes = []
        let changed = flow(controller, step: .finish)
        changed.autoUpdate = true
        changed.primary()
        XCTAssertEqual(updateWrites, ["sparkle true", "parts true"])
    }

    func testAReopenedFlowStartsOnWhenBothAreOn() throws {
        world.updater = true
        world.sparkle = true
        defaults.set(true, forKey: AppController.updatesAutomaticKey)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertTrue(flow(controller, step: .finish).autoUpdate)
    }

    private var updateWrites: [String] { writes.filter { $0.hasPrefix("parts") || $0.hasPrefix("sparkle") } }

    // MARK: - Launch

    func testTheSetupOpensAtLaunchOnceAndMarksItShown() throws {
        let plain = ["HOME": home.path]
        let first = try controller(home: home)
        defer { first.closeSetup(); first.panel?.close() }
        first.openSetupAtLaunch(environment: plain)
        XCTAssertEqual(first.setupPanel?.isVisible, true)
        XCTAssertEqual(first.setupPanel?.isKeyWindow, false, "Evlat is not in front: the keyboard stays where it was")
        XCTAssertEqual(first.setupFlow?.step, .agents)
        XCTAssertEqual(first.setupFlow?.autoUpdate, true, "a first run offers the row on")
        XCTAssertEqual(defaults.object(forKey: AppController.setupSeenKey) as? Bool, true, "shown is seen")

        let second = try controller(home: home)
        defer { second.closeSetup(); second.panel?.close() }
        second.openSetupAtLaunch(environment: plain)
        XCTAssertNil(second.setupPanel, "once")
    }

    /// Either way it opens by itself, the keyboard comes with it only when
    /// Evlat is the app in front.
    func testTheLaunchOpeningTakesTheKeyboardOnlyWhenEvlatIsInFront() throws {
        let environment = ["EVLAT_SETUP": "bar", "EVLAT_HOME": home.path]
        let away = try controller(home: home)
        defer { away.closeSetup(); away.panel?.close() }
        away.openSetupAtLaunch(environment: environment)
        XCTAssertEqual(away.setupPanel?.isVisible, true)
        XCTAssertEqual(away.setupPanel?.isKeyWindow, false)

        let inFront = try controller(home: home)
        defer { inFront.closeSetup(); inFront.panel?.close() }
        inFront.isFrontmost = { true }
        inFront.openSetupAtLaunch(environment: environment)
        XCTAssertEqual(inFront.setupPanel?.isKeyWindow, true)
    }

    func testTheSetupStaysShutWhenTheTriggerSaysNo() throws {
        let plain = ["HOME": home.path]
        defaults.set("left", forKey: AppController.edgeKey)
        let stored = try controller(home: home)
        defer { stored.panel?.close() }
        stored.openSetupAtLaunch(environment: plain)
        XCTAssertNil(stored.setupPanel, "a stored edge: not a new user")
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey))
    }

    func testAnIsolatedOrStorelessLaunchNeverOpensIt() throws {
        let isolated = try controller(home: home)
        defer { isolated.panel?.close() }
        for environment in [["EVLAT_HOME": home.path], ["EVLAT_EDGE": "left"], ["EVLAT_SOCKET": "/tmp/e.sock"]] {
            isolated.openSetupAtLaunch(environment: environment)
            XCTAssertNil(isolated.setupPanel, "\(environment)")
        }
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey), "nothing kept")

        let storeless = AppController(defaults: nil, home: home, loginItem: nil)
        storeless.installPanel()
        defer { storeless.panel?.close() }
        storeless.openSetupAtLaunch(environment: ["HOME": home.path])
        XCTAssertNil(storeless.setupPanel, "every test's controller: no storage, no setup")
    }

    // MARK: - After the cut to the socket

    /// The command every copy before the socket installed.
    private let tcpCommand = "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true"

    private func writeClaude(_ settings: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: settings).write(to: Claude().hooksFile(home: home))
    }

    /// An agent still on the bytes from before the socket is silent: the
    /// update window opens by itself at each launch, with its row, until
    /// it is updated; the box comes checked.
    func testTheUpdateWindowOpensAtEachLaunchWhileSomethingIsOld() throws {
        let plain = ["HOME": home.path]
        defaults.set("right", forKey: AppController.edgeKey)
        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]]])
        let first = try controller(home: home)
        first.updatesActivation = { }
        defer { first.updatesWindow?.close(); first.panel?.close() }
        first.openSetupAtLaunch(environment: plain)
        XCTAssertNil(first.setupPanel, "not a new user")
        XCTAssertNil(first.settingsWindow, "the update window instead")
        XCTAssertEqual(first.updatesWindow?.isVisible, true)
        XCTAssertEqual(first.updates?.agents.map(\.kind), [.agent(.claude)])
        XCTAssertEqual(first.updates?.agents.first?.state, .needsUpdate)
        XCTAssertEqual(first.updates?.title, "Evlat needs an update from you")
        XCTAssertEqual(first.updates?.keepCurrent, true)
        first.updatesWindow?.close()

        let second = try controller(home: home)
        second.updatesActivation = { }
        defer { second.updatesWindow?.close(); second.panel?.close() }
        second.openSetupAtLaunch(environment: plain)
        XCTAssertEqual(second.updatesWindow?.isVisible, true, "not once: still old")
        XCTAssertNil(defaults.object(forKey: AppController.updatesAutomaticKey), "opening writes nothing")

        // Its one press moves the hooks to the socket and, the box checked,
        // turns automatic updates on.
        second.updates?.updateAll()
        XCTAssertEqual(second.updates?.agents.first?.state, .updated)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: Claude()).hooks, .current)
        XCTAssertEqual(defaults.object(forKey: AppController.updatesAutomaticKey) as? Bool, true)

        let third = try controller(home: home)
        third.updatesActivation = { }
        defer { third.updatesWindow?.close(); third.panel?.close() }
        third.openSetupAtLaunch(environment: plain)
        XCTAssertNil(third.updatesWindow, "nothing old")
    }

    /// With automatic updates on, a launch updates the old hooks itself and
    /// stays silent; a usage line taken out stays out.
    func testAutomaticUpdatesAtLaunchAreSilent() throws {
        let plain = ["HOME": home.path]
        defaults.set("right", forKey: AppController.edgeKey)
        defaults.set(true, forKey: AppController.updatesAutomaticKey)
        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]],
                         "statusLine": ["type": "command", "command": "bash ~/s.sh"]])
        let controller = try controller(home: home)
        controller.updatesActivation = { }
        defer { controller.updatesWindow?.close(); controller.panel?.close() }
        controller.openSetupAtLaunch(environment: plain)
        XCTAssertNotEqual(controller.updatesWindow?.isVisible, true, "nothing left to the user")
        XCTAssertEqual(try AgentIntegration.state(home: home, for: Claude()),
                       AgentIntegration.State(hooks: .current, relay: .missing), "its own line is not wrapped")

        // An isolated launch writes nothing of the user's.
        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]]])
        let isolated = try self.controller(home: home)
        isolated.updatesActivation = { }
        defer { isolated.updatesWindow?.close(); isolated.panel?.close() }
        isolated.openSetupAtLaunch(environment: ["EVLAT_SOCKET": "/tmp/e.sock"])
        XCTAssertEqual(try AgentIntegration.state(home: home, for: Claude()).hooks, .outdated)
        XCTAssertNil(isolated.updatesWindow)
    }

    func testTheUpdateWindowStaysShutForTodaysBytesAnIsolatedLaunchOrTheSetup() throws {
        let plain = ["HOME": home.path]
        defaults.set("right", forKey: AppController.edgeKey)
        try LocalHooks.install(at: Claude().hooksFile(home: home), for: .claude)
        let current = try controller(home: home)
        current.updatesActivation = { }
        defer { current.updatesWindow?.close(); current.panel?.close() }
        current.openSetupAtLaunch(environment: plain)
        XCTAssertNil(current.updatesWindow, "today's bytes")

        try writeClaude(["hooks": ["Stop": [["hooks": [["type": "command", "command": tcpCommand]]]]]])
        let isolated = try controller(home: home)
        isolated.updatesActivation = { }
        defer { isolated.updatesWindow?.close(); isolated.panel?.close() }
        isolated.openSetupAtLaunch(environment: ["EVLAT_SOCKET": "/tmp/e.sock"])
        XCTAssertNil(isolated.updatesWindow, "a second Evlat")

        // A usage line from before the socket and no hooks: a new user by
        // the setup's rule, and the setup shows the same cards.
        defaults.removeObject(forKey: AppController.edgeKey)
        try writeClaude(["statusLine": ["type": "command", "command": "sh -c 'i=$(cat; printf x); i=${i%x}; printf %s \"$i\" | curl -s -m 2 -X POST -H \"Content-Type: application/json\" --data-binary @- http://127.0.0.1:48151/usage/claude >/dev/null 2>&1 &'"]])
        let fresh = try controller(home: home)
        fresh.updatesActivation = { }
        defer { fresh.closeSetup(); fresh.updatesWindow?.close(); fresh.panel?.close() }
        fresh.openSetupAtLaunch(environment: plain)
        XCTAssertEqual(fresh.setupPanel?.isVisible, true)
        XCTAssertNil(fresh.updatesWindow, "the setup instead")
    }

    /// `EVLAT_SETUP` opens it at a step for looking and writes nothing.
    func testTheEnvironmentOpensAStepAndKeepsNothing() throws {
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": "connected"]), .connected)
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": " Finish "]), .finish)
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": "3"]), .bar, "one-based, as the dots count")
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": "1"]), .agents)
        XCTAssertNil(AppController.forcedSetup(["EVLAT_SETUP": "5"]))
        XCTAssertNil(AppController.forcedSetup(["EVLAT_SETUP": "hello"]), "a step of the old flow")
        XCTAssertNil(AppController.forcedSetup(["EVLAT_SETUP": "nope"]))
        XCTAssertNil(AppController.forcedSetup([:]))

        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        controller.openSetupAtLaunch(environment: ["EVLAT_SETUP": "bar", "EVLAT_HOME": home.path])
        XCTAssertEqual(controller.setupPanel?.isVisible, true)
        XCTAssertEqual(controller.setupFlow?.step, .bar)
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey))
        XCTAssertNil(defaults.object(forKey: AppController.updatesAutomaticKey))
        XCTAssertNil(defaults.object(forKey: AppController.edgeKey))
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key))
        XCTAssertEqual(controller.setupFlow?.autoUpdate, false, "not a first run: it shows what is set")
    }

    func testTheMenuAndTheSettingsOpenIt() throws {
        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let entry = try XCTUnwrap(menu.items.first { $0.title == "Setup…" })
        XCTAssertTrue(entry.target === controller)
        XCTAssertEqual(entry.action, #selector(AppController.openSetupFromMenu(_:)))
        controller.settingsHost.openSetup()
        let panel = try XCTUnwrap(controller.setupPanel)
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.isKeyWindow, "asked for from Settings: the keyboard comes with it")
        XCTAssertEqual(panel.frame.size, SetupPanel.size, "a fixed size, the view's 380 × 460 in it")
        XCTAssertEqual(panel.title, "Setup")
        XCTAssertFalse(try XCTUnwrap(controller.panel).canBecomeKey, "the bar stays a non-activating panel")
    }

    /// The × and "Finish" fold the panel and start the flow over: nothing is
    /// heard, no ring turns for a panel nobody sees, the body goes back to
    /// its mode — and the setup opens again from the first step.
    func testTheXAndFinishFoldThePanelAndStartTheFlowOver() throws {
        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        controller.bodyMode = .hidden
        controller.openSetup()
        let panel = try XCTUnwrap(controller.setupPanel)
        let flow = try XCTUnwrap(controller.setupFlow)
        flow.primary()
        controller.handleHookEvent(event(.claude))
        XCTAssertEqual(flow.step, .connected)
        XCTAssertFalse(flow.heardFrom.isEmpty)
        XCTAssertEqual(controller.presence.level, .full)

        flow.dismiss()
        XCTAssertFalse(controller.isSetupOpen)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(flow.step, .agents)
        XCTAssertEqual(flow.connected, [])
        XCTAssertEqual(flow.heardFrom, [:])
        XCTAssertEqual(controller.presence.level, .none, "the body is back to its mode")
        controller.handleHookEvent(event(.claude))
        XCTAssertEqual(flow.heardFrom, [:], "nothing is listening")

        controller.openSetup(step: .finish)
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(flow.step, .finish)
        flow.primary()
        XCTAssertFalse(controller.isSetupOpen, "Finish closes it the same way")
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(flow.step, .agents)
        XCTAssertEqual(controller.presence.level, .none)
    }

    /// A second opening starts over from the step asked for, while it is out.
    func testOpeningItAgainStartsOver() throws {
        let controller = try controller(home: home)
        defer { controller.closeSetup(); controller.panel?.close() }
        controller.openSetup(step: .bar)
        let flow = try XCTUnwrap(controller.setupFlow)
        XCTAssertEqual(flow.step, .bar)
        controller.openSetup()
        XCTAssertEqual(flow.step, .agents)
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(try XCTUnwrap(controller.setupPanel).isVisible)
    }

    // MARK: - Keys

    func testEveryKeyIsInBothTables() {
        for lang in L10nTests.languages {
            for key in SetupFlowModel.keys + ["menu.setup"] {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }
}
