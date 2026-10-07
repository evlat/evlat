import XCTest
import AppKit
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The setup window: its steps forward and back,
/// what "Install" and "Finish" write, the chat step without a `claude`, the
/// launch that opens it once, and its fixed height. Every writer is a real
/// controller's under a temporary home and a suite of its own, recorded on
/// the way: the user's files, domain and login item are never touched.
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
        controller.setupActivation = { }
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

    /// The controller's own writers, each call noted first.
    private func flow(_ controller: AppController, claude: String? = "/usr/local/bin/claude",
                      step: SetupFlowModel.Step = .hello,
                      sandboxes: SettingsModel.Sandboxes? = nil) -> SetupFlowModel {
        var setup = controller.setupHost
        let agent = setup.setAgent
        let link = setup.setCommandLink, loginItem = setup.setLoginItem
        setup.setAgent = { [unowned self] in writes.append("agent \($0.rawValue) \($1)"); agent($0, $1) }
        setup.setCommandLink = { [unowned self] in writes.append("link \($0)"); link($0, $1) }
        setup.setLoginItem = { [unowned self] in writes.append("login \($0)"); loginItem($0) }
        var settings = controller.settingsHost
        let setEdge = settings.setEdge, setMode = settings.setDefaultMode
        settings.setEdge = { [unowned self] in writes.append("edge \($0.isLeft ? "left" : "right")"); setEdge($0) }
        settings.setDefaultMode = { [unowned self] in writes.append("mode \($0.id)"); setMode($0) }
        settings.locateBackend = { _, done in done(claude) }
        if var sandboxes {
            settings.sandboxes = { sandboxes }
            settings.setSandboxes = { [unowned self] on in writes.append("sandboxes \(on)"); sandboxes.on = on }
        }
        let flow = SetupFlowModel(settings: settings, setup: SetupModel(host: setup, lang: "en"),
                                  recorder: HotKeyRecorder(systemHotKeys: { SystemHotKeys(entries: [:]) }),
                                  close: { [unowned self] in writes.append("close") }, lang: "en")
        flow.start(at: step)
        return flow
    }

    // MARK: - Steps

    func testTheStepsGoForwardAndBackAndBackWritesNothing() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller)
        XCTAssertEqual(flow.step, .hello)
        XCTAssertFalse(flow.showsBack)
        XCTAssertFalse(flow.showsSkip)
        XCTAssertEqual(flow.primaryKey, "setup.flow.start")
        flow.primary()
        XCTAssertEqual(flow.step, .edge)
        XCTAssertTrue(flow.showsBack)
        XCTAssertTrue(flow.showsSkip)
        flow.primary()
        XCTAssertEqual(flow.step, .sessions)
        XCTAssertEqual(flow.primaryKey, "setup.flow.install", "something to write: Install")
        flow.skip()
        XCTAssertEqual(flow.step, .chat, "skip moves on and writes nothing")
        flow.skip()
        XCTAssertEqual(flow.step, .optional)
        XCTAssertEqual(flow.primaryKey, "setup.flow.finish")

        flow.back()
        XCTAssertEqual(flow.step, .chat)
        flow.go(to: .optional)
        XCTAssertEqual(flow.step, .chat, "a dot ahead is not a way forward")
        XCTAssertTrue(flow.canGo(to: .edge))
        XCTAssertFalse(flow.canGo(to: .chat), "the current dot")
        flow.go(to: .edge)
        XCTAssertEqual(flow.step, .edge, "a passed dot goes back")
        flow.go(to: .hello)
        XCTAssertEqual(flow.step, .hello)
        flow.back()
        XCTAssertEqual(flow.step, .hello, "nothing before the first step")
        XCTAssertEqual(writes, [], "going back and skipping call no writer")
    }

    /// Going back shows what was done with a ✓ and does not undo it: the
    /// rows read their state again, and "Install" becomes "Continue".
    func testGoingBackAfterInstallingKeepsIt() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        flow.primary()
        XCTAssertEqual(flow.step, .sessions, "Install stays on its step")
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        XCTAssertTrue(flow.installed)
        flow.primary()
        XCTAssertEqual(flow.step, .chat)
        let before = writes
        flow.back()
        XCTAssertEqual(flow.step, .sessions)
        XCTAssertEqual(flow.setup.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        XCTAssertEqual(writes, before, "back undoes nothing")
    }

    // MARK: - Sessions

    private let wraps = "Your statusLine command is wrapped: it prints what it printed, and Evlat also gets what it is given."

    /// The step's cards are the catalogue's, in its order: no fixed list of
    /// agents. The ones found are switched on, one not found is dim.
    func testTheCardsComeFromTheCatalogue() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        XCTAssertEqual(SetupFlowModel.sessionItems, Set(Agents.all.ids.map(SetupItem.agent)))
        XCTAssertEqual(flow.sessionRows.map(\.item), Agents.all.ids.map(SetupItem.agent))
        XCTAssertEqual(flow.sessionRows.map(\.status), [.missing, .missing, .notFound])
        XCTAssertTrue(flow.isQueued(.agent(.claude)))
        XCTAssertTrue(flow.isQueued(.agent(.codex)))
        XCTAssertFalse(flow.isQueued(.agent(.antigravity)), "not on this Mac: nothing to queue")
    }

    /// "Install" writes the lines above it and nothing else: an agent
    /// turned off, one set up by hand and the optional step's items stay
    /// unwritten. Claude's hooks and usage line are one write.
    func testInstallWritesOnlyWhatItsConsentLists() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        XCTAssertEqual(flow.installConsent, ["~/.claude/settings.json · hooks and the usage line",
                                             "~/.codex/hooks.json · hooks", wraps])
        flow.setup.toggleManual(.agent(.codex))
        XCTAssertEqual(flow.installConsent, ["~/.claude/settings.json · hooks and the usage line", wraps])
        flow.primary()
        XCTAssertEqual(writes, ["agent claude true"], "only the consent's line")
        XCTAssertEqual(flow.setup.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .missing)
        XCTAssertEqual(flow.setup.row(.commandLink)?.status, .missing, "the optional step's item is not this step's")
        XCTAssertEqual(flow.setup.row(.loginItem)?.status, .missing)
    }

    /// After "Install", whenever the button says "Install" again its lines
    /// are there: the consent follows the queue, not the first press.
    func testInstallAgainListsWhatItWrites() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        flow.setQueued(.agent(.codex), false)
        flow.primary()
        XCTAssertEqual(flow.installConsent, [])
        flow.setQueued(.agent(.codex), true)
        XCTAssertEqual(flow.primaryKey, "setup.flow.install")
        XCTAssertEqual(flow.installConsent, ["~/.codex/hooks.json · hooks"], "the lines of the next press")
    }

    /// A block set up by hand closes once the check finds it: no row keeps
    /// waiting for what is already there.
    func testACheckedManualRowStopsWaiting() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        flow.setup.toggleManual(.agent(.claude))
        try AgentIntegration.install(home: home, for: .claude)
        flow.setup.check()
        XCTAssertNil(flow.setup.manualOpen)
        XCTAssertTrue(flow.summary.contains { $0.mark == .done && $0.text == "Claude Code connected" })
    }

    func testNothingToWriteIsContinue() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        for source in [AgentID.claude, .codex] { flow.setQueued(.agent(source), false) }
        XCTAssertEqual(flow.installConsent, [])
        XCTAssertEqual(flow.primaryKey, "setup.flow.continue")
        flow.primary()
        XCTAssertEqual(flow.step, .chat)
        XCTAssertEqual(writes, [])
    }

    func testCodexIsDimWithoutItsDirectory() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .sessions)
        XCTAssertEqual(flow.setup.row(.agent(.codex))?.status, .notFound)
        XCTAssertEqual(flow.installConsent, ["~/.claude/settings.json · hooks and the usage line", wraps])
    }

    // MARK: - Chat, edge

    func testTheModesNeedAClaude() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertFalse(flow(controller, claude: nil, step: .chat).showsModes)
        let found = flow(controller, step: .chat)
        XCTAssertTrue(found.showsModes)
        found.setMode(.ask)
        XCTAssertEqual(writes, ["mode default"], "`ask` is claude's `default`")
    }

    /// The new chats' backend is derived from what is found, so the chat
    /// step looks every backend up, not only the one derived before it.
    func testTheChatStepLooksEveryBackendUp() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        var settings = controller.settingsHost
        var asked: [AgentID] = []
        settings.locateBackend = { id, done in asked.append(id); done(nil) }
        let flow = SetupFlowModel(settings: settings, setup: SetupModel(host: controller.setupHost, lang: "en"),
                                  recorder: HotKeyRecorder(systemHotKeys: { SystemHotKeys(entries: [:]) }),
                                  close: {}, lang: "en")
        flow.start(at: .chat)
        XCTAssertEqual(asked, Agents.chatBackends.map(\.id))
        XCTAssertEqual(flow.backend, .missing)
    }

    func testTheEdgeIsAppliedAtOnceAndTheMascotLooksThere() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .edge)
        XCTAssertEqual(flow.mascot.gaze.width, 1, "the bar is on the right: it looks right")
        let blinks = flow.blinks
        flow.chooseEdge(.left)
        XCTAssertEqual(writes, ["edge left"])
        XCTAssertEqual(controller.panel?.edge, .left)
        XCTAssertEqual(flow.mascot.gaze.width, -1)
        XCTAssertEqual(flow.blinks, blinks + 1, "one blink on the choice")
        flow.chooseEdge(.left)
        XCTAssertEqual(writes, ["edge left"], "the same edge again writes nothing")
        XCTAssertEqual(flow.blinks, blinks + 1)
    }

    // MARK: - Optional, done

    /// "Finish" writes the link (on by default) and the login item only when
    /// turned on (off by default) — nothing of the sessions step.
    func testFinishWritesOnlyTheOptionalItems() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let flow = flow(controller, step: .optional)
        XCTAssertTrue(flow.isQueued(.commandLink))
        XCTAssertFalse(flow.isQueued(.loginItem), "open at login is off by default")
        XCTAssertEqual(flow.finishConsent, ["~/.local/bin/evlat · a link to this copy of Evlat"])
        flow.setQueued(.loginItem, true)
        XCTAssertEqual(flow.finishConsent.count, 2)
        flow.setQueued(.loginItem, false)
        flow.primary()
        XCTAssertEqual(writes, ["link true"])
        XCTAssertEqual(flow.step, .done)
        XCTAssertFalse(flow.showsBack)
        XCTAssertFalse(flow.showsSkip)
        XCTAssertEqual(flow.primaryKey, "setup.flow.close")
        XCTAssertTrue(flow.summary.contains { $0.mark == .done && $0.text == "evlat command in ~/.local/bin" })
        XCTAssertTrue(flow.summary.contains { $0.mark == .skipped && $0.text.contains("Claude Code") })
        flow.primary()
        XCTAssertEqual(writes.last, "close")
    }

    /// With `sbx` here the optional step offers its switch, off; "Finish"
    /// lists it above the button and turns it on. Without `sbx`, or with
    /// the switch already on, no row and nothing written.
    func testTheSandboxesRowIsOfferedOnlyWithSbx() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertFalse(flow(controller, step: .optional).offersSandboxes, "a test's controller has no sbx")

        var found = SettingsModel.Sandboxes()
        found.availability = .found
        let flow = flow(controller, step: .optional, sandboxes: found)
        XCTAssertTrue(flow.offersSandboxes)
        XCTAssertFalse(flow.sandboxesQueued, "off unless turned on")
        let before = flow.finishConsent
        flow.sandboxesQueued = true
        XCTAssertEqual(flow.finishConsent, before + [
            "Each running Claude Code sandbox · one file of Evlat's, and a rule for port 48152",
        ])
        flow.primary()
        XCTAssertTrue(writes.contains("sandboxes true"))
        XCTAssertEqual(flow.step, .done)

        var on = found
        on.on = true
        XCTAssertFalse(self.flow(controller, step: .optional, sandboxes: on).offersSandboxes)
        var missing = found
        missing.availability = .missing
        let without = self.flow(controller, step: .optional, sandboxes: missing)
        without.sandboxesQueued = true
        XCTAssertFalse(without.finishConsent.contains { $0.contains("sandbox") })
        writes = []
        without.primary()
        XCTAssertFalse(writes.contains { $0.hasPrefix("sandboxes") })
    }

    // MARK: - Launch

    func testTheSetupOpensAtLaunchOnceAndMarksItShown() throws {
        let plain = ["HOME": home.path]
        let first = try controller(home: home)
        defer { first.setupWindow?.close(); first.panel?.close() }
        first.openSetupAtLaunch(environment: plain)
        XCTAssertEqual(first.setupWindow?.isVisible, true)
        XCTAssertEqual(first.setupFlow?.step, .hello)
        XCTAssertEqual(defaults.object(forKey: AppController.setupSeenKey) as? Bool, true, "shown is seen")

        let second = try controller(home: home)
        defer { second.setupWindow?.close(); second.panel?.close() }
        second.openSetupAtLaunch(environment: plain)
        XCTAssertNil(second.setupWindow, "once")
    }

    func testTheSetupStaysShutWhenTheTriggerSaysNo() throws {
        let plain = ["HOME": home.path]
        defaults.set("left", forKey: AppController.edgeKey)
        let stored = try controller(home: home)
        defer { stored.panel?.close() }
        stored.openSetupAtLaunch(environment: plain)
        XCTAssertNil(stored.setupWindow, "a stored edge: not a new user")
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey))
    }

    func testAnIsolatedOrStorelessLaunchNeverOpensIt() throws {
        let isolated = try controller(home: home)
        defer { isolated.panel?.close() }
        for environment in [["EVLAT_HOME": home.path], ["EVLAT_EDGE": "left"], ["EVLAT_SOCKET": "/tmp/e.sock"]] {
            isolated.openSetupAtLaunch(environment: environment)
            XCTAssertNil(isolated.setupWindow, "\(environment)")
        }
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey), "nothing kept")

        let storeless = AppController(defaults: nil, home: home, loginItem: nil)
        storeless.installPanel()
        storeless.setupActivation = { }
        defer { storeless.panel?.close() }
        storeless.openSetupAtLaunch(environment: ["HOME": home.path])
        XCTAssertNil(storeless.setupWindow, "every test's controller: no storage, no setup")
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
        XCTAssertNil(first.setupWindow, "not a new user")
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
        defer { fresh.setupWindow?.close(); fresh.updatesWindow?.close(); fresh.panel?.close() }
        fresh.openSetupAtLaunch(environment: plain)
        XCTAssertEqual(fresh.setupWindow?.isVisible, true)
        XCTAssertNil(fresh.updatesWindow, "the setup instead")
    }

    /// `EVLAT_SETUP` opens it at a step for looking and writes nothing.
    func testTheEnvironmentOpensAStepAndKeepsNothing() throws {
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": "sessions"]), .sessions)
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": " Done "]), .done)
        XCTAssertEqual(AppController.forcedSetup(["EVLAT_SETUP": "3"]), .sessions, "one-based, as the dots count")
        XCTAssertNil(AppController.forcedSetup(["EVLAT_SETUP": "nope"]))
        XCTAssertNil(AppController.forcedSetup([:]))

        let controller = try controller(home: home)
        defer { controller.setupWindow?.close(); controller.panel?.close() }
        controller.openSetupAtLaunch(environment: ["EVLAT_SETUP": "chat", "EVLAT_HOME": home.path])
        XCTAssertEqual(controller.setupWindow?.isVisible, true)
        XCTAssertEqual(controller.setupFlow?.step, .chat)
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey))
    }

    func testTheMenuAndTheSettingsOpenIt() throws {
        let controller = try controller(home: home)
        defer { controller.setupWindow?.close(); controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let entry = try XCTUnwrap(menu.items.first { $0.title == "Setup…" })
        XCTAssertTrue(entry.target === controller)
        XCTAssertEqual(entry.action, #selector(AppController.openSetupFromMenu(_:)))
        controller.settingsHost.openSetup()
        let window = try XCTUnwrap(controller.setupWindow?.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.styleMask.contains(.resizable), "a fixed size")
        XCTAssertEqual(window.contentLayoutRect.width, SetupWindow.width, accuracy: 0.5)
        XCTAssertFalse(try XCTUnwrap(controller.panel).canBecomeKey, "the bar stays a non-activating panel")
    }

    // MARK: - Size, keys

    func testTheHeightIsCappedAndFitsSmallScreens() {
        XCTAssertEqual(SetupWindow.height(visible: 1200), 468)
        XCTAssertEqual(SetupWindow.height(visible: 585), 468)
        XCTAssertEqual(SetupWindow.height(visible: 500), 400)
        for visible in stride(from: 200.0, through: 1600, by: 37) {
            let height = SetupWindow.height(visible: visible)
            XCTAssertLessThanOrEqual(height, 468)
            XCTAssertLessThanOrEqual(height, visible * 0.8)
        }
    }

    func testEveryKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in SetupFlowModel.keys + ["menu.setup"] {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }
}
