import XCTest
import EvlatCore
@testable import EvlatApp

/// The setup rows' model on a real controller's writers, all
/// under a temporary home and a suite of its own: the user's files, domain
/// and login item are never touched.
@MainActor
final class SetupModelTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var login = LoginItem.inMemory()

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.setup.\(UUID().uuidString)", isDirectory: true)
        for directory in [".claude", ".codex"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        suiteName = "evlat.tests.setup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        login = LoginItem.inMemory()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func bundle(_ name: String) throws -> URL {
        let contents = root.appendingPathComponent("\(name)/Evlat.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": CommandLink.bundleID],
                                           format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let binary = contents.appendingPathComponent("MacOS/Evlat")
        try Data().write(to: binary)
        return binary
    }

    private func controller(home: URL?) throws -> AppController {
        let controller = AppController(defaults: defaults, home: home, loginItem: LoginItem(service: login))
        controller.installPanel()
        controller.executable = try bundle("this")
        return controller
    }

    private func model(_ controller: AppController, host: ((inout SetupModel.Host) -> Void)? = nil) -> SetupModel {
        var h = controller.setupHost
        host?(&h)
        return SetupModel(host: h, lang: "en")
    }

    func testEveryItemReadsFresh() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.rows.map(\.item), [.claudeHooks, .usageRelay, .codexHooks, .commandLink, .loginItem])
        XCTAssertEqual(model.rows.map(\.status), [.missing, .missing, .missing, .missing, .missing])
        XCTAssertEqual(model.row(.loginItem)?.note, "Opens \(root.path)/this/Evlat.app")
        try LocalHooks.install(at: AgentSource.claude.settingsFile(home: home), for: .claude)
        XCTAssertEqual(model.row(.claudeHooks)?.status, .missing, "nothing cached, nothing read unasked")
        model.check()
        XCTAssertEqual(model.row(.claudeHooks)?.status, .installed, "\"I added it, check\" reads")
        XCTAssertEqual(model.row(.claudeHooks)?.action, .remove)
    }

    func testAnAgentThatIsNotThereHasNoRow() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertFalse(model(controller).rows.contains { $0.item == .codexHooks })
    }

    /// The consent line counts only the queued items' files; the manual one
    /// and the installed ones are left out.
    func testTheConsentCountsOnlyTheQueue() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.queueConsent, [])
        model.queued = [.claudeHooks]
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks"])
        model.queued = [.claudeHooks, .usageRelay, .codexHooks]
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks and the usage line",
                                            "~/.codex/hooks.json · hooks"])
        model.toggleManual(.codexHooks)
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks and the usage line"],
                       "set up by hand: not written")
        model.queued.insert(.commandLink)
        model.queued.insert(.loginItem)
        XCTAssertEqual(model.queueConsent.count, 3)
        XCTAssertEqual(model.queueConsent[1], "~/.local/bin/evlat · a link to this copy of Evlat")

        model.applyQueue()
        XCTAssertEqual(model.row(.claudeHooks)?.status, .installed)
        XCTAssertEqual(model.row(.usageRelay)?.status, .installed)
        XCTAssertEqual(model.row(.codexHooks)?.status, .missing, "the manual one was not written")
        XCTAssertEqual(model.row(.commandLink)?.status, .installed)
        XCTAssertEqual(model.row(.loginItem)?.status, .installed)
        XCTAssertEqual(model.queueConsent, [], "nothing left to write")
    }

    /// Waiting for approval in System Settings is registered: the switch
    /// stays live and takes it back.
    func testALoginItemWaitingForApprovalCanBeTurnedOff() throws {
        login = LoginItem.inMemory(.needsApproval)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.row(.loginItem)?.status, .installed)
        XCTAssertEqual(model.row(.loginItem)?.action, .remove)
        XCTAssertEqual(model.row(.loginItem)?.note,
                       "Waiting for your approval in System Settings → General → Login Items.")
        model.perform(.loginItem)
        XCTAssertEqual(login.status(), .off)
        XCTAssertEqual(model.row(.loginItem)?.status, .missing)
    }

    func testWithoutAHomeNothingIsWritten() throws {
        var calls: [String] = []
        let controller = try controller(home: nil)
        defer { controller.panel?.close() }
        let model = model(controller) { host in
            host.setHooks = { source, _ in calls.append("hooks \(source)") }
            host.setUsageRelay = { _ in calls.append("usage") }
            host.setCommandLink = { _, _ in calls.append("link") }
        }
        XCTAssertEqual(model.rows.map(\.item), [.loginItem], "no file row without a home")
        model.queued = Set(SetupItem.allCases)
        for item in SetupItem.allCases where item != .loginItem { model.perform(item) }
        model.applyQueue()
        XCTAssertEqual(calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        // The controller's writers say the same on their own.
        controller.setHooks(.claude, installed: true)
        controller.setCommandLink(installed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    /// With the Antigravity CLI there, its usage line is a row of its own:
    /// read from and written to the CLI's settings, not the hooks file.
    func testTheAntigravityUsageLineIsItsOwnRow() throws {
        for directory in [".gemini/antigravity-cli", ".gemini/config"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.rows.map(\.item), [.claudeHooks, .usageRelay, .codexHooks, .antigravityHooks,
                                                .antigravityUsageRelay, .commandLink, .loginItem])
        let row = try XCTUnwrap(model.row(.antigravityUsageRelay))
        XCTAssertEqual(row.status, .missing)
        XCTAssertEqual(row.detail, "~/.gemini/antigravity-cli/settings.json")
        XCTAssertEqual(model.consent(.antigravityUsageRelay, .install),
                       ["~/.gemini/antigravity-cli/settings.json · the usage line"])

        model.perform(.antigravityUsageRelay)
        let file = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .antigravity), .current)
        XCTAssertEqual(model.row(.antigravityUsageRelay)?.status, .installed)
        XCTAssertEqual(model.row(.usageRelay)?.status, .missing, "Claude's file is not touched")

        let empty = root.appendingPathComponent("empty-agy.json")
        try StatusLineRelay.install(at: empty, source: .antigravity)
        XCTAssertEqual(model.manual(.antigravityUsageRelay)?.text, try String(contentsOf: empty))

        model.perform(.antigravityUsageRelay)
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .antigravity), .missing)
    }

    /// The Antigravity app or IDE alone has no status line: no usage row.
    func testWithoutTheAntigravityCLIThereIsNoUsageRow() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity"),
                                                withIntermediateDirectories: true)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertNotNil(model.row(.antigravityHooks))
        XCTAssertNil(model.row(.antigravityUsageRelay))
    }

    /// The block to paste is what the writer writes into an empty file.
    func testTheManualBlocksAreTheWritersBytes() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        for (item, source) in [(SetupItem.claudeHooks, AgentSource.claude), (.codexHooks, .codex)] {
            let file = root.appendingPathComponent("empty-\(source.rawValue).json")
            try LocalHooks.install(at: file, for: source)
            XCTAssertEqual(model.manual(item)?.text, try String(contentsOf: file), "\(item)")
        }
        let file = root.appendingPathComponent("empty-statusline.json")
        try StatusLineRelay.install(at: file, source: .claude)
        XCTAssertEqual(model.manual(.usageRelay)?.text, try String(contentsOf: file))
        XCTAssertEqual(model.manual(.commandLink)?.text, CommandLink.manualLine(binary: try XCTUnwrap(controller.executable)))
        XCTAssertNil(model.manual(.loginItem))
    }

    func testOneManualBlockIsOpen() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        model.toggleManual(.claudeHooks)
        model.toggleManual(.commandLink)
        XCTAssertEqual(model.manualOpen, .commandLink)
        model.toggleManual(.commandLink)
        XCTAssertNil(model.manualOpen)
    }

    /// Another copy's link is replaced only after the consent says so, and
    /// its row and the attention list say where it points.
    func testAnotherCopysLinkIsNamedAndReplaced() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let other = try bundle("other")
        let link = CommandLink.link(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let model = model(controller)
        XCTAssertEqual(model.row(.commandLink)?.status, .outdated)
        XCTAssertEqual(model.row(.commandLink)?.action, .update)
        XCTAssertTrue(model.attention.contains(.commandLinkElsewhere))
        let target = other.resolvingSymlinksInPath().path
        XCTAssertEqual(model.consent(.commandLink, .update),
                       ["~/.local/bin/evlat · the link to another copy (\(target)) is pointed at this one"])
        model.perform(.commandLink)
        XCTAssertEqual(model.row(.commandLink)?.status, .installed)
        XCTAssertFalse(model.attention.contains(.commandLinkElsewhere))
    }

    func testSomeoneElsesEvlatIsLeftAlone() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let link = CommandLink.link(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: link)
        let model = model(controller)
        XCTAssertEqual(model.row(.commandLink)?.status, .foreign)
        XCTAssertNil(model.row(.commandLink)?.action)
        model.queued = [.commandLink]
        XCTAssertEqual(model.queueConsent, [])
        model.applyQueue()
        XCTAssertEqual(try String(contentsOf: link), "mine")
    }

    func testThePathNoteComesFromTheLoginShell() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        var path: String? = nil
        let model = model(controller) { $0.loginPath = { path } }
        XCTAssertNil(model.row(.commandLink)?.note, "not read yet: nothing said")
        path = "/usr/bin:/bin"
        model.check()
        XCTAssertEqual(model.row(.commandLink)?.note, "~/.local/bin is not on your shell's PATH: add it to type evlat alone.")
        path = "/usr/bin:\(home.path)/.local/bin"
        model.check()
        XCTAssertNil(model.row(.commandLink)?.note)
    }

    func testTheAttentionList() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let settings = AgentSource.claude.settingsFile(home: home)
        let old = "curl -s http://127.0.0.1:\(LocalAPI.defaultPort)/hook/claude old"
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]}]},"statusLine":{"type":"command","command":"sh -c 'x' 127.0.0.1:\#(LocalAPI.defaultPort)/usage/claude"}}"#.utf8)
            .write(to: settings)
        // A refused write: `hooks.json` is a directory.
        try FileManager.default.createDirectory(at: AgentSource.codex.settingsFile(home: home),
                                                withIntermediateDirectories: true)
        controller.setHooks(.codex, installed: true)
        let model = model(controller) { host in
            host.hotKeyRefused = { true }
            host.unreachableMachines = { ["devbox"] }
        }
        XCTAssertEqual(model.row(.claudeHooks)?.status, .outdated)
        XCTAssertEqual(model.row(.usageRelay)?.status, .foreign, "changed by hand: dim, no button")
        XCTAssertNil(model.row(.usageRelay)?.action)
        XCTAssertNotNil(model.row(.codexHooks)?.failure)
        XCTAssertEqual(model.attention, [.hooksOutdated(.claude), .usageModified, .refused(.codexHooks),
                                         .hotKeyUnregistered, .machineUnreachable("devbox")])
        XCTAssertEqual(model.attention.map(\.section), [.sessions, .sessions, .sessions, .chat, .remote])
        XCTAssertEqual(model.text(.hooksOutdated(.claude)), "Claude Code hooks are old")
        XCTAssertEqual(model.text(.machineUnreachable("devbox")), "devbox: server unreachable")
    }

    /// A machine waiting for its password is its own line, at the remote
    /// section — not "unreachable": the server answered.
    func testAMachineWaitingForItsPasswordIsAnAttentionLine() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        var waiting: [String] = []
        let model = model(controller) { host in
            host.unreachableMachines = { [] }
            host.machinesNeedingPassword = { waiting }
        }
        XCTAssertFalse(model.attention.contains(.machineNeedsPassword("devbox")))
        waiting = ["devbox"]
        model.reloadIfMachinesChanged()
        XCTAssertTrue(model.attention.contains(.machineNeedsPassword("devbox")), "the line follows the tunnel")
        XCTAssertEqual(SetupAttention.machineNeedsPassword("devbox").section, .remote)
        XCTAssertEqual(model.text(.machineNeedsPassword("devbox")), "devbox: waiting for a password")
        XCTAssertEqual(SetupModel(host: controller.setupHost, lang: "tr").text(.machineNeedsPassword("devbox")),
                       "devbox: şifre bekliyor")
    }

    func testEveryKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in SetupModel.keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }
}

/// The writers split out of the menu and the setup's opening
/// condition on the controller.
@MainActor
final class SetupWritersTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var home: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        suiteName = "evlat.tests.writers.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.writers.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    func testTheSetupOpensOnceForANewUserOnly() throws {
        let controller = AppController(defaults: defaults, home: home)
        let plain: [String: String] = ["HOME": home.path]
        XCTAssertTrue(controller.shouldOpenSetup(environment: plain))
        XCTAssertFalse(controller.shouldOpenSetup(environment: ["EVLAT_PORT": "48999"]))
        controller.markSetupSeen(environment: ["EVLAT_PORT": "48999"])
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey), "an isolated process keeps nothing")
        controller.markSetupSeen(environment: plain)
        XCTAssertFalse(controller.shouldOpenSetup(environment: plain))
        defaults.removeObject(forKey: AppController.setupSeenKey)
        defaults.set("top", forKey: AppController.edgeKey)
        XCTAssertFalse(controller.shouldOpenSetup(environment: plain), "any stored edge: not new")
        defaults.removeObject(forKey: AppController.edgeKey)
        try LocalHooks.install(at: AgentSource.claude.settingsFile(home: home), for: .claude)
        XCTAssertFalse(controller.shouldOpenSetup(environment: plain))
        XCTAssertFalse(AppController(defaults: nil, home: home).shouldOpenSetup(environment: plain), "no storage")
        XCTAssertFalse(AppController(defaults: defaults, home: nil).shouldOpenSetup(environment: plain))
    }

    func testTheEdgeAndTheShortcutWritersStore() {
        let controller = AppController(defaults: defaults, home: nil)
        controller.installPanel()
        defer { controller.panel?.close() }
        controller.setEdge(.left)
        XCTAssertEqual(defaults.string(forKey: AppController.edgeKey), "left")
        XCTAssertEqual(controller.panel?.edge, .left)
        controller.setHotKey(on: false)
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, false)
        controller.storeHotKey(.standard)
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, true, "a recorded one turns it on")
    }
}
