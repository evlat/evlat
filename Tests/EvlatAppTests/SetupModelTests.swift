import XCTest
import EvlatCore
@testable import EvlatAgents
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

    private let wraps = "Your statusLine command is wrapped: it prints what it printed, and Evlat also gets what it is given."

    func testEveryItemReadsFresh() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.rows.map(\.item), [.agent(.claude), .agent(.codex), .agent(.antigravity),
                                                .commandLink, .loginItem], "every agent in the catalogue has a card")
        XCTAssertEqual(model.rows.map(\.status), [.missing, .missing, .notFound, .missing, .missing])
        XCTAssertEqual(model.row(.loginItem)?.note, "Opens \(root.path)/this/Evlat.app")
        try AgentIntegration.install(home: home, for: .claude)
        XCTAssertEqual(model.row(.agent(.claude))?.status, .missing, "nothing cached, nothing read unasked")
        model.check()
        XCTAssertEqual(model.row(.agent(.claude))?.status, .installed, "\"I added it, check\" reads")
        XCTAssertEqual(model.row(.agent(.claude))?.action, .remove)
    }

    /// An agent that is not here is a dim card: nothing to press, nothing
    /// to write, no attention.
    func testAnAgentThatIsNotThereIsDimWithNothingToPress() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        let row = try XCTUnwrap(model.row(.agent(.codex)))
        XCTAssertEqual(row.status, .notFound)
        XCTAssertNil(row.action)
        XCTAssertEqual(row.detail, "~/.codex/hooks.json")
        XCTAssertEqual(model.consent(.agent(.codex), .install), [])
        XCTAssertEqual(model.attention, [])
    }

    /// The consent counts only the queued items' files; the manual one and
    /// the installed ones are left out. Claude's hooks and usage line are
    /// one file, one line, and the wrapping is said once, under the files.
    func testTheConsentCountsOnlyTheQueue() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.queueConsent, [])
        model.queued = [.agent(.claude)]
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks and the usage line", wraps])
        model.queued = [.agent(.claude), .agent(.codex)]
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks and the usage line",
                                            "~/.codex/hooks.json · hooks", wraps])
        model.toggleManual(.agent(.codex))
        XCTAssertEqual(model.queueConsent, ["~/.claude/settings.json · hooks and the usage line", wraps],
                       "set up by hand: not written")
        model.queued.insert(.commandLink)
        model.queued.insert(.loginItem)
        XCTAssertEqual(model.queueConsent.count, 4)
        XCTAssertEqual(model.queueConsent[1], "~/.local/bin/evlat · a link to this copy of Evlat")

        model.applyQueue()
        XCTAssertEqual(model.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(model.row(.agent(.codex))?.status, .missing, "the manual one was not written")
        XCTAssertEqual(model.row(.commandLink)?.status, .installed)
        XCTAssertEqual(model.row(.loginItem)?.status, .installed)
        XCTAssertEqual(model.queueConsent, [], "nothing left to write")
    }

    /// Hooks without the usage line: the card offers the rest, the menu
    /// and the side list stay quiet (no attention, no dot).
    func testOnlyTheHooksReadsNeedsUpdateAndWantsNoAttention() throws {
        try LocalHooks.install(at: Claude().hooksFile(home: home), for: .claude)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        let row = try XCTUnwrap(model.row(.agent(.claude)))
        XCTAssertEqual(row.status, .outdated)
        XCTAssertEqual(row.action, .update)
        XCTAssertEqual(row.parts.map(\.status), [.installed, .missing])
        XCTAssertEqual(row.parts.map(\.name), ["Hooks and the approval hook", "Usage line"])
        XCTAssertEqual(model.attention, [])
        XCTAssertEqual(controller.makeMenu(diagnostics: false, in: "en").items
                        .filter { $0.representedObject is SetupAttention }, [], "no line in the menu")
        XCTAssertEqual(model.consent(.agent(.claude), .update), ["~/.claude/settings.json · the usage line", wraps],
                       "only what the press changes")
        model.perform(.agent(.claude))
        XCTAssertEqual(model.row(.agent(.claude))?.status, .installed)
        XCTAssertEqual(model.consent(.agent(.claude), .remove),
                       ["~/.claude/settings.json · hooks removed and usage line removed, your previous statusLine back"])
    }

    /// The usage line goes out alone from the card's details; the card then
    /// offers it back.
    func testTheUsageLineCanBeRemovedAlone() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        model.perform(.agent(.claude))
        XCTAssertEqual(model.row(.agent(.claude))?.removesRelay, true)
        XCTAssertEqual(model.relayRemovalConsent(.claude),
                       ["~/.claude/settings.json · usage line removed, your previous statusLine back"])
        model.removeRelay(.claude)
        let file = Claude().hooksFile(home: home)
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .claude), .missing)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current)
        XCTAssertEqual(model.row(.agent(.claude))?.status, .outdated)
        XCTAssertEqual(model.row(.agent(.claude))?.removesRelay, false)
        XCTAssertEqual(model.attention, [])
    }

    /// A usage line edited by hand is not a part: the hooks go in, the
    /// line is left byte for byte, and the card and the menu say so.
    func testAHandEditedUsageLineIsLeftAlone() throws {
        let file = Claude().hooksFile(home: home)
        let edited = StatusLineRelay.command(wrapping: "cat", source: .claude).replacingOccurrences(of: "-m 2", with: "-m 9")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": edited]]).write(to: file)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        XCTAssertEqual(model.row(.agent(.claude))?.status, .missing)
        XCTAssertEqual(model.consent(.agent(.claude), .install), ["~/.claude/settings.json · hooks"],
                       "nothing said about a line that is not written")
        model.perform(.agent(.claude))
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String, edited)
        let row = try XCTUnwrap(model.row(.agent(.claude)))
        XCTAssertEqual(row.status, .installed)
        XCTAssertEqual(row.note, "Your usage line was edited by hand; Evlat leaves it as it is.")
        XCTAssertEqual(model.attention, [.usageModified(.claude)])
        XCTAssertEqual(model.text(.usageModified(.claude)), "Claude Code usage line edited by hand")
    }

    /// The Antigravity app or IDE alone has no status line: the usage line
    /// is not a part, and the hooks alone are the whole card. Its hooks
    /// folder is made by the install, so a missing one reads "not installed".
    func testWithoutTheAntigravityCLITheHooksAreTheCard() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity"),
                                                withIntermediateDirectories: true)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        let row = try XCTUnwrap(model.row(.agent(.antigravity)))
        XCTAssertEqual(row.status, .missing)
        XCTAssertEqual(row.parts.count, 1)
        XCTAssertEqual(model.consent(.agent(.antigravity), .install), ["~/.gemini/config/hooks.json · hooks"])
        model.perform(.agent(.antigravity))
        XCTAssertEqual(model.row(.agent(.antigravity))?.status, .installed)
        XCTAssertNil(model.manual(.agent(.antigravity))?.statusLine)
    }

    /// With the Antigravity CLI there, its usage line is a part in a file of
    /// its own: the CLI's settings, not the hooks file.
    func testTheAntigravityCLIsUsageLineIsAPartInItsOwnFile() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"),
                                                withIntermediateDirectories: true)
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        let row = try XCTUnwrap(model.row(.agent(.antigravity)))
        XCTAssertEqual(row.detail, "~/.gemini/config/hooks.json · ~/.gemini/antigravity-cli/settings.json")
        XCTAssertEqual(model.consent(.agent(.antigravity), .install),
                       ["~/.gemini/config/hooks.json · hooks", "~/.gemini/antigravity-cli/settings.json · the usage line",
                        wraps])
        model.perform(.agent(.antigravity))
        let file = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .antigravity), .current)
        XCTAssertEqual(model.row(.agent(.antigravity))?.status, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Claude().hooksFile(home: home).path),
                       "Claude's file is not touched")

        let empty = root.appendingPathComponent("empty-agy.json")
        try StatusLineRelay.install(at: empty, source: .antigravity)
        XCTAssertEqual(model.manual(.agent(.antigravity))?.statusLine, try String(contentsOf: empty))

        model.perform(.agent(.antigravity))
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .antigravity), .missing, "removed with the hooks")
        XCTAssertEqual(model.row(.agent(.antigravity))?.status, .missing)
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
            host.setAgent = { source, _ in calls.append("agent \(source)") }
            host.removeUsageRelay = { source in calls.append("relay \(source)") }
            host.setCommandLink = { _, _ in calls.append("link") }
        }
        XCTAssertEqual(model.rows.map(\.item), [.loginItem], "no file row without a home")
        model.queued = Set(SetupItem.allCases)
        for item in SetupItem.allCases where item != .loginItem { model.perform(item) }
        model.removeRelay(.claude)
        model.applyQueue()
        XCTAssertEqual(calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        // The controller's writers say the same on their own.
        controller.setAgent(.claude, installed: true)
        controller.setCommandLink(installed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    /// The block to paste is what the writers write into an empty file:
    /// the hooks and, where it is a part, the usage line.
    func testTheManualBlocksAreTheWritersBytes() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        for source in [Claude(), Codex()] as [any Agent] {
            let file = root.appendingPathComponent("empty-\(source.id.rawValue).json")
            try LocalHooks.install(at: file, for: source)
            XCTAssertEqual(model.manual(.agent(source.id))?.text, try String(contentsOf: file), "\(source.id)")
        }
        let file = root.appendingPathComponent("empty-statusline.json")
        try StatusLineRelay.install(at: file, source: .claude)
        XCTAssertEqual(model.manual(.agent(.claude))?.statusLine, try String(contentsOf: file))
        XCTAssertNil(model.manual(.agent(.codex))?.statusLine, "Codex has no status line")
        XCTAssertEqual(model.manual(.commandLink)?.text, CommandLink.manualLine(binary: try XCTUnwrap(controller.executable)))
        XCTAssertNil(model.manual(.loginItem))
    }

    func testOneManualBlockIsOpen() throws {
        let controller = try controller(home: home)
        defer { controller.panel?.close() }
        let model = model(controller)
        model.toggleManual(.agent(.claude))
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
        let settings = Claude().hooksFile(home: home)
        let old = "curl -s http://127.0.0.1:\(LocalAPI.defaultPort)/hook/claude old"
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)"}]}]},"statusLine":{"type":"command","command":"sh -c 'x' 127.0.0.1:\#(LocalAPI.defaultPort)/usage/claude"}}"#.utf8)
            .write(to: settings)
        // A refused write: `hooks.json` is a directory.
        try FileManager.default.createDirectory(at: Codex().hooksFile(home: home),
                                                withIntermediateDirectories: true)
        controller.setAgent(.codex, installed: true)
        let model = model(controller) { host in
            host.hotKeyRefused = { true }
            host.unreachableMachines = { ["devbox"] }
        }
        XCTAssertEqual(model.row(.agent(.claude))?.status, .outdated)
        XCTAssertEqual(model.row(.agent(.claude))?.parts.last?.status, .foreign, "changed by hand: not a part")
        XCTAssertEqual(model.row(.agent(.codex))?.failure, "Hooks: The settings file could not be read")
        XCTAssertEqual(model.attention, [.hooksOutdated(.claude), .usageModified(.claude), .refused(.agent(.codex)),
                                         .hotKeyUnregistered, .machineUnreachable("devbox")])
        XCTAssertEqual(model.attention.map(\.section), [.agents, .agents, .agents, .chat, .remote])
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
        // An agent's own way out is looked up, not listed: the one written.
        for lang in ["en", "tr"] {
            for key in SetupModel.keys + ["setup.manual.remove.antigravity"] {
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
        XCTAssertFalse(controller.shouldOpenSetup(environment: ["EVLAT_SOCKET": "/tmp/e.sock"]))
        controller.markSetupSeen(environment: ["EVLAT_SOCKET": "/tmp/e.sock"])
        XCTAssertNil(defaults.object(forKey: AppController.setupSeenKey), "an isolated process keeps nothing")
        controller.markSetupSeen(environment: plain)
        XCTAssertFalse(controller.shouldOpenSetup(environment: plain))
        defaults.removeObject(forKey: AppController.setupSeenKey)
        defaults.set("top", forKey: AppController.edgeKey)
        XCTAssertFalse(controller.shouldOpenSetup(environment: plain), "any stored edge: not new")
        defaults.removeObject(forKey: AppController.edgeKey)
        try LocalHooks.install(at: Claude().hooksFile(home: home), for: .claude)
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
