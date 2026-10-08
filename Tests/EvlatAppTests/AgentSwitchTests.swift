import XCTest
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// An agent's switch on a real controller: what is stored and when, the
/// rows, usage windows and approval cards it takes away, the card's
/// question and the setup's choice. A temporary home and a suite of its own:
/// the user's files and domain are never touched.
@MainActor
final class AgentSwitchTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.switch.\(UUID().uuidString)", isDirectory: true)
        for directory in [".claude", ".codex"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        suiteName = "evlat.tests.switch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func controller() -> AppController {
        let controller = AppController(defaults: defaults, home: home)
        controller.registry.register(controller.hooks)
        controller.applyEnabledAgents()
        return controller
    }

    private func event(_ name: String, session: String, source: AgentID) -> HookEvent {
        HookEvent(json: ["hook_event_name": name, "session_id": session, "cwd": "/tmp/p"], source: source)
    }

    private func usage(_ source: AgentID, at date: Date) -> UsageReport {
        UsageReport(windows: [UsageReport.Window(minutes: 300, usedPercent: 40, resetsAt: date + 3600)],
                    unrecognizedWindows: [], source: source)
    }

    // MARK: - Stored only when changed

    func testNothingStoredFollowsTheAgentsFoundAndReadingWritesNothing() throws {
        let controller = controller()
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex])
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key), "launch and reading write nothing")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex, .antigravity], "installed later, on")
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key))
    }

    func testTheUsersChangeIsStoredAndReadFromThenOn() throws {
        let controller = controller()
        controller.setEnabled(.claude, true)
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key), "no change, nothing written")
        controller.setEnabled(.codex, false)
        XCTAssertEqual(defaults.stringArray(forKey: EnabledAgents.key), ["claude"])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(controller.enabledAgents, [.claude], "the stored set is the answer now")
    }

    func testAnIsolatedProcessKeepsTheSwitchesInMemory() {
        XCTAssertTrue(AppController.keepsAgentsInMemory(["EVLAT_SOCKET": "/tmp/e.sock"]))
        XCTAssertFalse(AppController.keepsAgentsInMemory(["EVLAT_SOCKET": " "]))
        XCTAssertFalse(AppController.keepsAgentsInMemory(["EVLAT_HOME": "/tmp/x"]))
        XCTAssertFalse(AppController.keepsAgentsInMemory([:]))
    }

    func testWithoutStorageTheSwitchStillWorks() {
        let controller = AppController(defaults: nil, home: home)
        controller.applyEnabledAgents()
        controller.setEnabled(.codex, false)
        XCTAssertEqual(controller.enabledAgents, [.claude])
    }

    // MARK: - What off takes away

    func testAnAgentOffOpensNoRowAndOnBringsItBack() {
        let controller = controller()
        controller.handleHookEvent(event("UserPromptSubmit", session: "codex-1", source: .codex))
        controller.handleHookEvent(event("UserPromptSubmit", session: "claude-1", source: .claude))
        controller.setEnabled(.codex, false)
        XCTAssertEqual(controller.registry.snapshot().ordered.map(\.entity), ["claude-1"])
        controller.setEnabled(.codex, true)
        XCTAssertEqual(Set(controller.registry.snapshot().ordered.map(\.entity)), ["claude-1", "codex-1"])
    }

    func testAWaitOfAnAgentOffIsNotOnTheFace() {
        let controller = controller()
        controller.setEnabled(.claude, false)
        controller.handleHookEvent(event("PermissionRequest", session: "claude-1", source: .claude))
        controller.refresh()
        XCTAssertNotEqual(controller.mascot.phase, .waiting)
        XCTAssertFalse(controller.registry.snapshot().hasLive)
    }

    /// Hidden is not gone: a finish already told stays told, so switching
    /// the agent back on peeks for nothing.
    func testOnAgainRetellsNothing() {
        let controller = controller()
        controller.handleHookEvent(event("Stop", session: "claude-1", source: .claude))
        controller.refresh()
        XCTAssertNil(controller.peekPhase, "the first scan's news is old news")
        controller.setEnabled(.claude, false)
        controller.refresh()
        controller.setEnabled(.claude, true)
        controller.refresh()
        XCTAssertNil(controller.peekPhase)
    }

    func testAnAgentInstalledWhileRunningBringsItsUsage() throws {
        let controller = controller()
        let seen = Date(timeIntervalSince1970: 1_790_200_000)
        controller.now = { seen }
        controller.handleDelivery(.usage(usage(.antigravity, at: seen)))
        controller.refresh()
        XCTAssertEqual(controller.registry.snapshot().usage.count, 0, "not on this Mac: not followed")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"),
                                                withIntermediateDirectories: true)
        controller.refresh()
        XCTAssertEqual(controller.registry.snapshot().usage.count, 1)
    }

    func testARefusedRemovalLeavesTheAgentOn() throws {
        try AgentIntegration.install(home: home, for: .codex)
        let controller = controller()
        var host = controller.setupHost
        host.setAgent = { _, _ in }
        host.agentFailure = { _ in AgentIntegration.Failure(part: .hooks, reason: .unwritable) }
        let refusing = SetupModel(host: host, lang: "en")
        refusing.setEnabled(.codex, false)
        refusing.confirmTurnOff(remove: true)
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex], "the parts are still there: still on")
    }

    func testAnAgentOffHasNoUsageProviderAndOnBringsIt() {
        let controller = controller()
        let seen = Date(timeIntervalSince1970: 1_790_200_000)
        controller.now = { seen }
        controller.handleDelivery(.usage(usage(.claude, at: seen)))
        XCTAssertEqual(controller.registry.snapshot().usage.count, 1)
        controller.setEnabled(.claude, false)
        XCTAssertEqual(controller.registry.snapshot().usage.count, 0, "unregistered with the switch")
        controller.setEnabled(.claude, true)
        XCTAssertEqual(controller.registry.snapshot().usage.count, 1)
        controller.setEnabled(.claude, true)
        controller.applyEnabledAgents()
        XCTAssertEqual(controller.registry.snapshot().usage.count, 1, "registered once, however often applied")
    }

    func testAnApprovalForAnAgentOffIsAnsweredAtOnceWithNoCard() {
        let controller = controller()
        var sent: [(String, LocalAPI.Response)] = []
        controller.approvals.respond = { sent.append(($0.id, $1)) }
        controller.setEnabled(.claude, false)
        controller.handleDelivery(.approval(HeldRequest(id: "r-1", token: nil, tool: "Bash",
                                                                   subject: "ls", command: "ls",
                                                                   sessionID: "s-1", source: .claude)))
        XCTAssertEqual(controller.approvals.pending, [])
        XCTAssertEqual(sent.map(\.0), ["r-1"])
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
    }

    func testTurningTheAgentOffLetsItsHeldApprovalsGo() {
        let controller = controller()
        var sent: [String] = []
        controller.approvals.respond = { request, _ in sent.append(request.id) }
        controller.handleDelivery(.approval(HeldRequest(id: "r-1", token: nil, tool: "Bash",
                                                                   subject: "ls", command: "ls",
                                                                   sessionID: "s-1", source: .claude)))
        XCTAssertEqual(controller.approvals.pending.map(\.id), ["r-1"], "held while on")
        controller.setEnabled(.claude, false)
        XCTAssertEqual(controller.approvals.pending, [])
        XCTAssertEqual(sent, ["r-1"])
    }

    // MARK: - The card

    func testAnAgentOffAsksForNoAttention() throws {
        // An old copy's command: the card would say "old" and the menu
        // would light up.
        let old = "curl -s http://127.0.0.1:\(LocalAPI.defaultPort)/hook/codex old"
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]}]}}"#.utf8)
            .write(to: Codex().hooksFile(home: home))
        let controller = controller()
        XCTAssertTrue(SetupModel(host: controller.setupHost, lang: "en").attention.contains(.hooksOutdated(.codex)))
        controller.setEnabled(.codex, false)
        let model = SetupModel(host: controller.setupHost, lang: "en")
        XCTAssertEqual(model.attention, [])
        XCTAssertEqual(model.row(.agent(.codex))?.enabled, false)
        model.perform(.agent(.codex))
        XCTAssertEqual(try LocalHooks.state(at: Codex().hooksFile(home: home), for: .codex), .outdated,
                       "an agent off offers no button")
    }

    func testOffWithNothingInstalledIsAtOnce() {
        let controller = controller()
        let model = SetupModel(host: controller.setupHost, lang: "en")
        model.setEnabled(.codex, false)
        XCTAssertNil(model.turningOff)
        XCTAssertEqual(controller.enabledAgents, [.claude])
        XCTAssertEqual(model.row(.agent(.codex))?.enabled, false)
    }

    func testOffWithPartsInstalledAsksAndRemovesByDefault() throws {
        try AgentIntegration.install(home: home, for: .codex)
        let controller = controller()
        let model = SetupModel(host: controller.setupHost, lang: "en")
        model.setEnabled(.codex, false)
        XCTAssertEqual(model.turningOff, .codex, "asked before anything moves")
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex])
        model.confirmTurnOff(remove: true)
        XCTAssertNil(model.turningOff)
        XCTAssertEqual(controller.enabledAgents, [.claude])
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .codex).status, .missing)
    }

    func testOffCanLeaveTheFilesAndCancelChangesNothing() throws {
        try AgentIntegration.install(home: home, for: .codex)
        let controller = controller()
        let model = SetupModel(host: controller.setupHost, lang: "en")
        model.setEnabled(.codex, false)
        model.cancelTurnOff()
        XCTAssertNil(model.turningOff)
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex])
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key))
        model.setEnabled(.codex, false)
        model.confirmTurnOff(remove: false)
        XCTAssertEqual(controller.enabledAgents, [.claude])
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .codex).status, .current, "the files are left")
    }

    // MARK: - The setup's choice

    private func flow(_ controller: AppController) -> SetupFlowModel {
        let flow = SetupFlowModel(settings: controller.settingsHost,
                                  setup: SetupModel(host: controller.setupHost, lang: "en"),
                                  close: {}, lang: "en")
        flow.start(at: .agents)
        return flow
    }

    func testConnectingWhatWasFoundKeepsTheDefaultLive() {
        let controller = controller()
        let flow = flow(controller)
        flow.primary()
        XCTAssertNil(defaults.object(forKey: EnabledAgents.key))
        XCTAssertEqual(controller.enabledAgents, [.claude, .codex])
    }

    func testAnAgentLeftOutOfTheSetupIsSwitchedOff() {
        let controller = controller()
        let flow = flow(controller)
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        XCTAssertEqual(defaults.stringArray(forKey: EnabledAgents.key), ["claude"])
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .missing, "nothing written to it")
    }

    func testNotNowWritesTheChoiceAndNothingElse() {
        let controller = controller()
        let flow = flow(controller)
        flow.setQueued(.agent(.claude), false)
        flow.skip()
        XCTAssertEqual(defaults.stringArray(forKey: EnabledAgents.key), ["codex"])
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .missing)
    }

    func testAnAgentOffStartsUnchecked() {
        let controller = controller()
        controller.setEnabled(.codex, false)
        let flow = flow(controller)
        XCTAssertFalse(flow.isQueued(.agent(.codex)))
        XCTAssertTrue(flow.isQueued(.agent(.claude)))
    }
}
