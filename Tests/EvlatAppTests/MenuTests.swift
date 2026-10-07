import XCTest
import AppKit
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The stored edge and the two menus: what is read and
/// written, what the menus hold, where a right click opens one, and that
/// choosing an edge activates nothing.
///
/// Every test that stores anything has its own suite, removed in `tearDown`:
/// the user's domain (`dev.kalaomer.evlat`) is never read or written here.
@MainActor
final class MenuTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    /// A temporary home for the attention lines and the writers: the user's
    /// `~/.claude` and `~/.codex` are never read or written here.
    private var home: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "evlat.tests.menu.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.menu.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    /// Screens this Mac may not have: the menus' titles must not depend on
    /// how many monitors the machine running the tests has.
    nonisolated static let builtIn = BarDisplay(id: "BUILT-IN", name: "Built-in Retina Display",
                                    frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 949))
    nonisolated static let dell = BarDisplay(id: "DELL", name: "DELL U2720Q",
                                 frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
                                 visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1440))

    private func controller(edge: BarPanel.Edge = .right, rows: Int = 0,
                            home: URL? = nil, displays: [BarDisplay] = [builtIn]) -> AppController {
        let controller = AppController(defaults: defaults, home: home)
        controller.displays = { displays }
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel(edge: edge)
        provider.signals = (0..<rows).map { index in
            Signal(provider: "stub", entity: "e\(index)", phase: .idle, label: "s\(index)",
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        }
        controller.refresh()
        return controller
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func edgeMenu(_ menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.items.first?.submenu, "the first entry is the edge")
    }

    // MARK: - The stored edge

    func testTheStoredEdgeIsRightOrLeftAndNothingElse() {
        XCTAssertNil(AppController.storedEdge(defaults), "nothing stored")
        XCTAssertNil(AppController.storedEdge(nil), "no storage at all")
        defaults.set("left", forKey: AppController.edgeKey)
        XCTAssertEqual(AppController.storedEdge(defaults), .left)
        defaults.set("right", forKey: AppController.edgeKey)
        XCTAssertEqual(AppController.storedEdge(defaults), .right)
        for unknown in ["top", "Left", "", "sol"] {
            defaults.set(unknown, forKey: AppController.edgeKey)
            XCTAssertNil(AppController.storedEdge(defaults), unknown)
        }
        defaults.set(1, forKey: AppController.edgeKey)
        XCTAssertNil(AppController.storedEdge(defaults), "not a string")
    }

    func testReadingTheEdgeWritesNothing() {
        XCTAssertNil(AppController.storedEdge(defaults))
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[AppController.edgeKey])
        defaults.set("top", forKey: AppController.edgeKey)
        _ = AppController.storedEdge(defaults)
        XCTAssertEqual(defaults.string(forKey: AppController.edgeKey), "top",
                       "an unknown value is not written over")
    }

    /// v1 shares the domain; its keys are plain camelCase.
    func testTheKeyDoesNotLookLikeOneOfV1s() {
        XCTAssertEqual(AppController.edgeKey, "bar.edge")
    }

    // MARK: - The menus

    func testTheMascotMenuHoldsTheEdgeAndQuit() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(titles(menu), ["Edge", "Shortcut: ⇧⌘Space", "—", "Settings…", "Setup…", "Quit Evlat"])
        XCTAssertEqual(titles(try edgeMenu(menu)), ["Right", "Left"])
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.on, .off])
    }

    /// The chat switched off: the shortcut's line leaves both menus.
    func testSwitchedOffTheChatHasNoShortcutLine() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        controller.setChatEnabled(false)
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: false, in: "en")),
                       ["Edge", "—", "Settings…", "Setup…", "Quit Evlat"])
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: true, in: "en")),
                       ["Edge", "Force state", "—", "Settings…", "Setup…", "Quit Evlat"])
        controller.setChatEnabled(true)
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: false, in: "en")),
                       ["Edge", "Shortcut: ⇧⌘Space", "—", "Settings…", "Setup…", "Quit Evlat"])
    }

    func testTheTrayMenuAddsForceState() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: true, in: "en")
        XCTAssertEqual(titles(menu), ["Edge", "Shortcut: ⇧⌘Space", "Force state", "—",
                                      "Settings…", "Setup…", "Quit Evlat"])
        let forced = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(titles(forced),
                       ["Follow sessions", "—", "Idle", "Working", "Waiting", "Done", "Error"],
                       "the phases in the status line's words, first letter raised")
    }

    func testTheMenusAreInTurkish() throws {
        let controller = controller(edge: .left)
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: true, in: "tr")
        XCTAssertEqual(titles(menu), ["Kenar", "Kısayol: ⇧⌘Space", "Durumu zorla", "—",
                                      "Ayarlar…", "Kurulum…", "Evlat'tan Çık"])
        XCTAssertEqual(titles(try edgeMenu(menu)), ["Sağ", "Sol"])
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.off, .on])
        let forced = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(forced.items.first?.title, "Oturumları izle")
        XCTAssertTrue(titles(forced).contains("Çalışıyor"), "first letter raised, accents kept")
        XCTAssertTrue(titles(forced).contains("Boşta"))
    }

    /// On a Turkish Q keyboard AppKit's automatic localization rewrote the
    /// item's key to "ö" while the menu was open (the US comma's physical
    /// key) and the menu showed ⌘Ö; "," has its own key there.
    func testSettingsIsCommandCommaOnEveryKeyboard() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        for diagnostics in [false, true] {
            let menu = controller.makeMenu(diagnostics: diagnostics, in: "tr")
            let settings = try XCTUnwrap(menu.items.first { $0.title == "Ayarlar…" })
            XCTAssertEqual(settings.keyEquivalent, ",")
            XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
            XCTAssertFalse(settings.allowsAutomaticKeyEquivalentLocalization,
                           "localized, ⌘, becomes ⌘Ö on Turkish Q")
        }
    }

    func testEveryMenuKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in AppController.menuKeys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    /// The tray menu is rebuilt as it opens, so its mark follows the edge.
    func testTheTrayMenusMarkFollowsTheEdge() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        let menu = controller.trayMenu()
        XCTAssertTrue(menu.delegate === controller)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.on, .off])
        controller.dock(.left)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.off, .on])
        XCTAssertEqual(menu.items.count, 7, "rebuilt, not appended to")
    }

    // MARK: - Attention lines

    private func agentDirectory(_ source: some Agent) throws {
        try FileManager.default.createDirectory(at: source.hooksFile(home: home).deletingLastPathComponent(),
                                                withIntermediateDirectories: false)
    }

    private func settings(_ source: some Agent) throws -> [String: Any] {
        let data = try Data(contentsOf: source.hooksFile(home: home))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The attention lines, found by what they carry rather than by their
    /// titles, which are what is being checked.
    private func attentionLines(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject is SetupAttention }
    }

    /// Today's command with another timeout: a hook Evlat wrote once but
    /// would not write today.
    private func writeOutdatedHooks() throws {
        let current = HookSettings.installing(into: [:], for: .claude)
        let old = String(decoding: try JSONSerialization.data(withJSONObject: current), as: UTF8.self)
            .replacingOccurrences(of: "-m 2", with: "-m 1")
        try Data(old.utf8).write(to: Claude().hooksFile(home: home))
    }

    /// Setting up is the settings window's: with both agents there and
    /// nothing installed the menu offers nothing, and reading it writes
    /// nothing.
    func testNothingIsSetUpFromTheMenu() throws {
        try agentDirectory(.claude)
        try agentDirectory(.codex)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: true, in: "en")),
                       ["Edge", "Shortcut: ⇧⌘Space", "Force state", "—", "Settings…", "Setup…", "Quit Evlat"],
                       "missing hooks want no attention: no line")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Claude().hooksFile(home: home).path),
                       "opening the menu writes nothing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(),
                       [".claude", ".codex"], "and creates nothing")
    }

    /// An old hook is a dim line above *Settings…* — dim, but it can be
    /// clicked, and the click opens the settings at its section.
    func testAnOutdatedHookIsADimLineThatOpensItsSection() throws {
        try agentDirectory(.claude)
        try writeOutdatedHooks()
        let before = try Data(contentsOf: Claude().hooksFile(home: home))
        let controller = controller(home: home)
        controller.settingsActivation = { }
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(titles(menu), ["Edge", "Shortcut: ⇧⌘Space", "—", "Claude Code hooks are old", "—",
                                      "Settings…", "Setup…", "Quit Evlat"])
        let line = try XCTUnwrap(attentionLines(menu).first)
        XCTAssertTrue(line.isEnabled, "dim, not disabled: it can be clicked")
        XCTAssertTrue(line.target === controller)
        XCTAssertEqual(line.action, #selector(AppController.openAttention(_:)))
        let color = line.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .secondaryLabelColor, "drawn dim")
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "tr")).map(\.title),
                       ["Claude Code hook'ları eski"])

        menu.performActionForItem(at: menu.index(of: line))
        XCTAssertEqual(controller.settingsWindow?.isVisible, true)
        XCTAssertEqual(controller.settings?.section, .agents)
        XCTAssertEqual(try Data(contentsOf: Claude().hooksFile(home: home)), before,
                       "the click only opens: nothing is written")
    }

    /// Hooks from before the socket are silent, and their line says so —
    /// in the bar's words, in every language.
    func testSilentHooksSayWhatTheyCost() throws {
        try agentDirectory(.claude)
        let tcp = "curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true"
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["type": "command", "command": tcp]]]]]])
            .write(to: Claude().hooksFile(home: home))
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "en")).map(\.title),
                       ["Claude Code hooks are old: Evlat can't hear its sessions until you update them"])
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "tr")).map(\.title),
                       ["Claude Code hook'ları eski: güncelleyene dek Evlat oturumlarını duymaz"])
    }

    /// A refused write is a line until a write succeeds.
    func testARefusedWriteLeavesOneLineUntilItSucceeds() throws {
        try agentDirectory(.claude)
        let file = Claude().hooksFile(home: home)
        let broken = Data("{ not json".utf8)
        try broken.write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        controller.setAgent(.claude, installed: true)
        XCTAssertEqual(try Data(contentsOf: file), broken, "the file is left as it was")
        XCTAssertEqual(controller.agentFailure(.claude), AgentIntegration.Failure(part: .hooks, reason: .malformed))
        let lines = attentionLines(controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(lines.map { $0.representedObject as? SetupAttention }, [.refused(.agent(.claude))])
        XCTAssertEqual(lines.first?.title, "Claude Code: the last change was refused")

        try Data("{}".utf8).write(to: file)
        controller.setAgent(.claude, installed: true)
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "en")), [],
                       "the line goes with the success")
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .current)
    }

    func testEveryFailureHasALine() {
        let failures: [HookSettings.Failure] = [.unreadable, .malformed, .noDirectory, .changedUnderneath, .unwritable]
        let keys = Set(failures.map(AppController.failureKey))
        XCTAssertEqual(keys.count, failures.count, "one line per failure")
        XCTAssertTrue(keys.isSubset(of: Set(SetupModel.keys)), "the settings rows ask for them")
    }

    func testAHandEditedWrapperIsALine() throws {
        try agentDirectory(.claude)
        let file = Claude().hooksFile(home: home)
        let edited = StatusLineRelay.command(wrapping: "cat", source: .claude).replacingOccurrences(of: "-m 2", with: "-m 9")
        let bytes = try JSONSerialization.data(withJSONObject: ["statusLine": ["command": edited]])
        try bytes.write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        let lines = attentionLines(controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(lines.map(\.title), ["Claude Code usage line edited by hand"])
        XCTAssertEqual((lines.first?.representedObject as? SetupAttention)?.section, .agents)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    // MARK: - The writers the menu no longer calls

    func testTheHookWriterInstallsThenRemoves() throws {
        try agentDirectory(.claude)
        let file = Claude().hooksFile(home: home)
        try Data(#"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}"#.utf8)
            .write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        controller.setAgent(.claude, installed: true)
        let golden = LocalAPI.installedHookCommand(for: .claude)
        let hooks = try XCTUnwrap(try settings(.claude)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(Claude().hooks.events))
        for event in Claude().hooks.events {
            let commands = (hooks[event] as? [[String: Any]] ?? [])
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
            XCTAssertTrue(commands.contains(golden), "\(event) carries the golden command")
        }
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .current)

        controller.setAgent(.claude, installed: false)
        let after = try settings(.claude)
        XCTAssertEqual(after["model"] as? String, "opus")
        let left = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Array(left.keys), ["Stop"], "only Evlat's groups went")
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .missing)
        XCTAssertNil(after["statusLine"], "the usage line went with them")
    }

    /// Like the edge: the file is written, the open list closes, and Evlat
    /// is not activated.
    func testTheHookWriterTakesNoFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        try agentDirectory(.claude)
        let controller = controller(rows: 4, home: home)
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        panel.show()
        XCTAssertFalse(isFrontmost(), "precondition: the test runner is not frontmost")
        controller.hover.onChange = { [unowned controller] open in
            open ? controller.openBar() : controller.closeBar()
        }
        controller.hover.openNow()

        controller.setAgent(.claude, installed: true)
        XCTAssertEqual(try HookSettings.state(at: Claude().hooksFile(home: home), for: .claude),
                       .current)
        XCTAssertFalse(controller.barState.isOpen, "the open list closes")
        XCTAssertFalse(controller.hover.isOpen)
        XCTAssertFalse(isFrontmost(), "a hook write must not activate Evlat")
        XCTAssertFalse(panel.isKeyWindow)
    }

    /// The usage line goes in with the hooks and can go out alone, the
    /// user's status line back as it was.
    func testTheUsageLineComesWithTheHooksAndGoesAlone() throws {
        try agentDirectory(.claude)
        let file = Claude().hooksFile(home: home)
        let original = #"{"model": "opus", "statusLine": {"type": "command", "command": "bash ~/s.sh", "padding": 0}}"#
        try Data(original.utf8).write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        controller.setAgent(.claude, installed: true)
        let line = try XCTUnwrap(try settings(.claude)["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, StatusLineRelay.command(wrapping: "bash ~/s.sh", source: .claude))
        XCTAssertEqual(line["padding"] as? Int, 0)
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .claude), .current)

        controller.removeUsageRelay(.claude)
        let back = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let now = try settings(.claude)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(now["statusLine"] as? [String: Any]))
            .isEqual(to: try XCTUnwrap(back["statusLine"] as? [String: Any])))
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current, "the hooks stay")
        XCTAssertNil(controller.agentFailure(.claude))
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "en")), [], "no failure line")
    }

    /// A `statusLine` the relay will not wrap is the user's own line: not a
    /// part, so no refusal — the hooks go in and the line says it is left.
    func testAStatusLineNotOursIsALineNotARefusal() throws {
        try agentDirectory(.claude)
        try Data(#"{"statusLine": "bash s.sh"}"#.utf8).write(to: Claude().hooksFile(home: home))
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        controller.setAgent(.claude, installed: true)
        XCTAssertNil(controller.agentFailure(.claude))
        XCTAssertEqual(try LocalHooks.state(at: Claude().hooksFile(home: home), for: .claude), .current,
                       "the hooks went in")
        XCTAssertEqual(attentionLines(controller.makeMenu(diagnostics: false, in: "en"))
                        .map { $0.representedObject as? SetupAttention }, [.usageModified(.claude)])
    }

    // MARK: - The home

    func testTheHomeIsTheEnvironmentsOrTheUsers() {
        let user = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        XCTAssertEqual(AppController.resolvedHome(["EVLAT_HOME": "/tmp/evlat-home"]).path, "/tmp/evlat-home")
        XCTAssertEqual(AppController.resolvedHome(["EVLAT_HOME": "~/x"]).path,
                       user.appendingPathComponent("x").path, "the tilde is expanded")
        XCTAssertEqual(AppController.resolvedHome(["EVLAT_HOME": ""]).standardizedFileURL.path, user.path,
                       "blank is ignored")
        XCTAssertEqual(AppController.resolvedHome(["EVLAT_HOME": "  "]).standardizedFileURL.path, user.path)
        XCTAssertEqual(AppController.resolvedHome([:]).standardizedFileURL.path, user.path)
    }

    func testTheSessionsFollowTheHomeUnlessNamed() {
        XCTAssertEqual(Self.recordsDirectory(["EVLAT_HOME": "/tmp/h"]), "/tmp/h/.claude/sessions")
        XCTAssertEqual(Self.recordsDirectory(["EVLAT_HOME": "/tmp/h", "EVLAT_SESSIONS": "/tmp/s"]),
                       "/tmp/s", "EVLAT_SESSIONS comes first")
        XCTAssertEqual(Self.recordsDirectory(["EVLAT_SESSIONS": ""]).map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent(".claude/sessions").standardizedFileURL.path)
    }

    /// The folder `--list` says the session records are read from.
    nonisolated static func recordsDirectory(_ environment: [String: String]) -> String? {
        let marker = "  ·  directory: "
        return AppController.listedProviders(environment).flatMap(\.diagnostics)
            .first { $0.contains(marker) }?.components(separatedBy: marker).last
    }

    // MARK: - Choosing an edge

    /// Whether this process is the active application, as the system sees
    /// it; the run loop is turned first (see `PanelConfigTests.isFrontmost`).
    private func isFrontmost() -> Bool {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return NSRunningApplication.current.isActive || NSApplication.shared.isActive
    }

    /// The edge entry stores the choice and docks there at once — and
    /// activates nothing. Under the test runner's default `.prohibited`
    /// `activate` does nothing, so the app's own policy is set first.
    func testChoosingAnEdgeStoresItDocksAndTakesNoFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = controller(rows: 4)
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        panel.show()
        XCTAssertFalse(isFrontmost(), "precondition: the test runner is not frontmost")
        let main = try XCTUnwrap(NSScreen.screens.first)
        controller.hover.onChange = { [unowned controller] open in
            open ? controller.openBar() : controller.closeBar()
        }
        controller.hover.openNow()

        let edges = try edgeMenu(controller.makeMenu(diagnostics: false, in: "en"))
        edges.performActionForItem(at: 1)
        XCTAssertEqual(defaults.string(forKey: AppController.edgeKey), "left")
        XCTAssertEqual(AppController.storedEdge(defaults), .left)
        XCTAssertEqual(panel.edge, .left)
        XCTAssertEqual(controller.barState.edge, .left)
        XCTAssertFalse(controller.barState.isOpen, "the open list closes")
        XCTAssertFalse(controller.hover.isOpen)
        XCTAssertEqual(panel.frame.minX, main.visibleFrame.minX, accuracy: 0.5)
        XCTAssertFalse(isFrontmost(), "choosing an edge must not activate Evlat")
        XCTAssertFalse(panel.isKeyWindow)

        try edgeMenu(controller.makeMenu(diagnostics: false, in: "en")).performActionForItem(at: 0)
        XCTAssertEqual(defaults.string(forKey: AppController.edgeKey), "right")
        XCTAssertEqual(panel.frame.maxX, main.visibleFrame.maxX, accuracy: 0.5)
        XCTAssertFalse(isFrontmost())
    }

    /// A controller built without storage still moves the bar; it only has
    /// nowhere to keep the choice.
    func testWithoutStorageTheEdgeIsStillApplied() throws {
        let controller = AppController()
        controller.installPanel()
        defer { controller.panel?.close() }
        try edgeMenu(controller.makeMenu(diagnostics: false, in: "en")).performActionForItem(at: 1)
        XCTAssertEqual(controller.panel?.edge, .left, "applied without storage too")
    }

    // MARK: - The screen

    private func displayMenu(_ menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.items.first { $0.title == "Screen" }?.submenu, "a Screen entry")
    }

    /// One screen is no choice: the menu stays as it was.
    func testOneScreenHasNoScreenEntry() {
        let controller = controller()
        defer { controller.panel?.close() }
        XCTAssertFalse(titles(controller.makeMenu(diagnostics: false, in: "en")).contains("Screen"))
    }

    func testTwoScreensAddAScreenEntryAfterTheEdge() throws {
        let controller = controller(displays: [Self.builtIn, Self.dell])
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(titles(menu), ["Edge", "Screen", "Shortcut: ⇧⌘Space", "—",
                                      "Settings…", "Setup…", "Quit Evlat"])
        let screens = try displayMenu(menu)
        XCTAssertEqual(titles(screens), ["Main screen", "—", "Built-in Retina Display", "DELL U2720Q"])
        XCTAssertEqual(screens.items.map(\.state), [.on, .off, .off, .off], "nothing stored is the main screen")
        let tr = controller.makeMenu(diagnostics: false, in: "tr")
        XCTAssertEqual(tr.items[1].title, "Ekran")
        XCTAssertEqual(tr.items[1].submenu?.items.first?.title, "Ana ekran")
    }

    /// The entry stores the screen's id and name, pins the panel and
    /// activates nothing; the main screen stores nothing again.
    func testChoosingAScreenStoresItPinsAndTakesNoFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = controller(displays: [Self.builtIn, Self.dell])
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        panel.show()
        XCTAssertFalse(isFrontmost(), "precondition: the test runner is not frontmost")

        try displayMenu(controller.makeMenu(diagnostics: false, in: "en")).performActionForItem(at: 3)
        XCTAssertEqual(defaults.string(forKey: AppController.displayKey), "DELL")
        XCTAssertEqual(defaults.string(forKey: AppController.displayNameKey), "DELL U2720Q")
        XCTAssertEqual(panel.display, "DELL")
        XCTAssertEqual(try displayMenu(controller.makeMenu(diagnostics: false, in: "en")).items.map(\.state),
                       [.off, .off, .off, .on])
        XCTAssertFalse(isFrontmost(), "choosing a screen must not activate Evlat")
        XCTAssertFalse(panel.isKeyWindow)

        try displayMenu(controller.makeMenu(diagnostics: false, in: "en")).performActionForItem(at: 0)
        XCTAssertNil(defaults.object(forKey: AppController.displayKey))
        XCTAssertNil(defaults.object(forKey: AppController.displayNameKey))
        XCTAssertNil(panel.display)
    }

    /// Unplugged, the pinned screen is still the choice: listed by the name
    /// it was chosen under, marked, and kept in storage — even with one
    /// screen left, so the user can let go of it.
    func testAnUnpluggedScreenStaysPinnedAndListed() throws {
        defaults.set("DELL", forKey: AppController.displayKey)
        defaults.set("DELL U2720Q", forKey: AppController.displayNameKey)
        let controller = AppController(defaults: defaults)
        controller.displays = { [Self.builtIn] }
        controller.installPanel(display: defaults.string(forKey: AppController.displayKey))
        defer { controller.panel?.close() }
        let screens = try displayMenu(controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(titles(screens), ["Main screen", "—", "Built-in Retina Display",
                                         "DELL U2720Q (not connected)"])
        XCTAssertEqual(screens.items.map(\.state), [.off, .off, .off, .on])
        XCTAssertEqual(defaults.string(forKey: AppController.displayKey), "DELL", "reading forgets nothing")
    }

    // MARK: - Right click

    func testTheMascotIsHitFromEitherEdge() {
        let middle = AppController.mascotTopInset + AppController.mascotSize / 2
        XCTAssertTrue(AppController.isOverMascot(fromEdge: AppController.barWidth / 2, fromTop: middle))
        XCTAssertTrue(AppController.isOverMascot(fromEdge: 1, fromTop: AppController.mascotTopInset))
        XCTAssertFalse(AppController.isOverMascot(fromEdge: AppController.barWidth + 1, fromTop: middle),
                       "past the closed bar")
        XCTAssertFalse(AppController.isOverMascot(fromEdge: -1, fromTop: middle))
        XCTAssertFalse(AppController.isOverMascot(fromEdge: 10, fromTop: AppController.slotTop(0)),
                       "the first ring is not the mascot")
        XCTAssertFalse(AppController.isOverMascot(fromEdge: 10, fromTop: 2), "the flare above it")
    }

    private func rightClick(_ panel: BarPanel, fromEdge x: CGFloat, fromTop y: CGFloat,
                            control: Bool = false) throws -> NSMenu? {
        let view = try XCTUnwrap(panel.contentView)
        let bounds = view.bounds
        let local = CGPoint(x: panel.edge.x(atInset: x, in: bounds), y: bounds.minY + AppController.headroom + y)
        let inWindow = view.convert(local, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: control ? .leftMouseDown : .rightMouseDown, location: inWindow,
            modifierFlags: control ? .control : [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        return view.menu(for: event)
    }

    func testARightClickOnTheMascotOpensTheMenu() throws {
        for edge: BarPanel.Edge in [.right, .left] {
            let controller = controller(edge: edge, rows: 4)
            let panel = try XCTUnwrap(controller.panel)
            defer { panel.close() }
            let middle = AppController.mascotTopInset + AppController.mascotSize / 2
            let menu = try rightClick(panel, fromEdge: AppController.barWidth / 2, fromTop: middle)
            XCTAssertEqual(menu.map(titles)?.count, 6, "\(edge): the mascot menu, without Force state")
            XCTAssertNotNil(try rightClick(panel, fromEdge: AppController.barWidth / 2, fromTop: middle,
                                           control: true), "\(edge): ctrl-click too")
            XCTAssertNil(try rightClick(panel, fromEdge: AppController.barWidth / 2,
                                        fromTop: AppController.slotTop(0) + 5), "\(edge): a ring")
            XCTAssertNil(try rightClick(panel, fromEdge: AppController.barWidth * 2, fromTop: middle),
                         "\(edge): beside the bar")
            controller.openBar()
            XCTAssertNil(try rightClick(panel, fromEdge: 20, fromTop: AppController.slotTop(1) + 5),
                         "\(edge): the open list")
            XCTAssertNotNil(try rightClick(panel, fromEdge: AppController.barWidth / 2, fromTop: middle),
                            "\(edge): the mascot of an open bar")
        }
    }

    /// The whole AppKit route, not only `menu(for:)`: a right click and a
    /// ctrl-click handed to the panel reach the mascot's menu (the hosting
    /// view does not swallow them), a click beside it asks for none, and the
    /// app is not activated.
    ///
    /// The menu is built but not handed back: whatever `menu(for:)` returns
    /// AppKit pops up on the user's screen, and a test must show nothing.
    /// That `menu(for:)`'s menu is the one opened is AppKit's part
    /// (`NSView.rightMouseDown`); which menu it returns, and where, is
    /// `testARightClickOnTheMascotOpensTheMenu`'s. Whether a user's real click
    /// activates is still looked at by eye — no real event loop runs here.
    func testTheClickReachesTheMenuThroughAppKit() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = controller(rows: 2)
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        panel.show()
        let build = try XCTUnwrap(panel.onMenu)
        var asked: [NSMenu] = []
        panel.onMenu = { point in
            if let menu = build(point) { asked.append(menu) }
            return nil
        }
        let view = try XCTUnwrap(panel.contentView)
        func send(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, fromTop y: CGFloat) throws {
            let local = CGPoint(x: view.bounds.maxX - AppController.barWidth / 2, y: view.bounds.minY + AppController.headroom + y)
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: view.convert(local, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        // A click AppKit's route answers with no menu may be asked about
        // twice (a ctrl-click is), so each click is judged on its own.
        func asks(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, fromTop y: CGFloat) throws -> [NSMenu] {
            asked = []
            try send(type, flags, fromTop: y)
            return asked
        }
        let middle = AppController.mascotTopInset + AppController.mascotSize / 2
        let right = try asks(.rightMouseDown, [], fromTop: middle)
        XCTAssertFalse(right.isEmpty, "a right click on the mascot")
        XCTAssertEqual(right.map { titles($0).count }, right.map { _ in 6 })
        let control = try asks(.leftMouseDown, .control, fromTop: middle)
        XCTAssertFalse(control.isEmpty, "a ctrl-click on the mascot")
        XCTAssertEqual(control.map { titles($0).count }, control.map { _ in 6 })
        XCTAssertEqual(try asks(.rightMouseDown, [], fromTop: AppController.slotTop(0) + 5), [],
                       "a ring opens nothing")
        XCTAssertFalse(NSRunningApplication.current.isActive)
        XCTAssertFalse(panel.isKeyWindow)
    }
}
