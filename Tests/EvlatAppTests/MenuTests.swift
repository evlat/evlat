import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The stored edge and the two menus (`007/phase-2`): what is read and
/// written, what the menus hold, where a right click opens one, and that
/// choosing an edge activates nothing.
///
/// Every test that stores anything has its own suite, removed in `tearDown`:
/// the user's domain (`dev.kalaomer.evlat`) is never read or written here.
@MainActor
final class MenuTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    /// A temporary home for the hook entries: the user's `~/.claude` and
    /// `~/.codex` are never read or written here.
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

    private func controller(edge: BarPanel.Edge = .right, rows: Int = 0,
                            home: URL? = nil) -> AppController {
        let controller = AppController(defaults: defaults, home: home)
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
        XCTAssertEqual(titles(menu), ["Edge", "—", "Quit Evlat"])
        XCTAssertEqual(titles(try edgeMenu(menu)), ["Right", "Left"])
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.on, .off])
        XCTAssertFalse(titles(menu).contains { $0.localizedCaseInsensitiveContains("hook") },
                       "no home, no hook entry")
    }

    func testTheTrayMenuAddsForceState() throws {
        let controller = controller()
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: true, in: "en")
        XCTAssertEqual(titles(menu), ["Edge", "Force state", "—", "Quit Evlat"])
        let forced = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(titles(forced),
                       ["Follow sessions", "—", "Idle", "Working", "Waiting", "Done", "Error"],
                       "the phases in the status line's words, first letter raised")
    }

    func testTheMenusAreInTurkish() throws {
        let controller = controller(edge: .left)
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: true, in: "tr")
        XCTAssertEqual(titles(menu), ["Kenar", "Durumu zorla", "—", "Evlat'tan Çık"])
        XCTAssertEqual(titles(try edgeMenu(menu)), ["Sağ", "Sol"])
        XCTAssertEqual(try edgeMenu(menu).items.map(\.state), [.off, .on])
        let forced = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(forced.items.first?.title, "Oturumları izle")
        XCTAssertTrue(titles(forced).contains("Çalışıyor"), "first letter raised, accents kept")
        XCTAssertTrue(titles(forced).contains("Boşta"))
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
        XCTAssertEqual(menu.items.count, 4, "rebuilt, not appended to")
    }

    // MARK: - Hook entries

    private func agentDirectory(_ source: AgentSource) throws {
        try FileManager.default.createDirectory(at: source.configDirectory(home: home),
                                                withIntermediateDirectories: false)
    }

    private func settings(_ source: AgentSource) throws -> [String: Any] {
        let data = try Data(contentsOf: source.settingsFile(home: home))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The index of a source's entry, found by what it does rather than by
    /// its title, which is what is being checked.
    private func hookEntry(_ menu: NSMenu, _ source: AgentSource) throws -> Int {
        try XCTUnwrap(menu.items.firstIndex {
            ($0.representedObject as? AppController.HookEntry)?.source == source
        }, "no entry for \(source)")
    }

    func testThereIsAnEntryForEachAgentThatIsThere() throws {
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: false, in: "en")), ["Edge", "—", "Quit Evlat"],
                       "neither agent: no entry")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [],
                       "reading the menu creates no directory")

        try agentDirectory(.claude)
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: false, in: "en")),
                       ["Edge", "—", "Install Claude Code hooks", "Install the usage line", "—", "Quit Evlat"])
        try agentDirectory(.codex)
        XCTAssertEqual(titles(controller.makeMenu(diagnostics: true, in: "en")),
                       ["Edge", "Force state", "—", "Install Claude Code hooks", "Install the usage line",
                        "Install Codex hooks", "—", "Quit Evlat"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.claude.settingsFile(home: home).path),
                       "opening the menu writes nothing")
    }

    func testTheTitleFollowsTheState() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        func title(_ lang: String) throws -> String {
            let menu = controller.makeMenu(diagnostics: false, in: lang)
            return menu.items[try hookEntry(menu, .claude)].title
        }
        XCTAssertEqual(try title("en"), "Install Claude Code hooks", "missing")
        XCTAssertEqual(try title("tr"), "Claude Code hook'larını kur")

        let current = HookSettings.installing(into: [:], for: .claude)
        try JSONSerialization.data(withJSONObject: current).write(to: file)
        XCTAssertEqual(try title("en"), "Remove Claude Code hooks", "current")
        XCTAssertEqual(try title("tr"), "Claude Code hook'larını kaldır")

        let old = String(decoding: try JSONSerialization.data(withJSONObject: current), as: UTF8.self)
            .replacingOccurrences(of: "-m 2", with: "-m 1")
        try Data(old.utf8).write(to: file)
        XCTAssertEqual(try title("en"), "Update Claude Code hooks", "outdated")
        XCTAssertEqual(try title("tr"), "Claude Code hook'larını güncelle")
    }

    func testTheEntriesCarryTheirHints() throws {
        try agentDirectory(.claude)
        try agentDirectory(.codex)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        var menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(menu.items[try hookEntry(menu, .claude)].toolTip,
                       L10n.t("menu.hooks.hint.claude", in: "en"))
        XCTAssertEqual(menu.items[try hookEntry(menu, .codex)].toolTip,
                       L10n.t("menu.hooks.hint.codex", in: "en"))
        menu.performActionForItem(at: try hookEntry(menu, .claude))
        menu.performActionForItem(at: try hookEntry(menu, .codex))
        menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertNil(menu.items[try hookEntry(menu, .claude)].toolTip, "Claude's removal needs no hint")
        XCTAssertEqual(menu.items[try hookEntry(menu, .codex)].toolTip,
                       L10n.t("menu.hooks.hint.remove", in: "en"))
    }

    func testTheEntryInstallsThenRemoves() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        try Data(#"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}"#.utf8)
            .write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        var menu = controller.makeMenu(diagnostics: false, in: "en")
        menu.performActionForItem(at: try hookEntry(menu, .claude))
        let golden = LocalAPI.installedHookCommand(for: .claude)
        let hooks = try XCTUnwrap(try settings(.claude)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentSource.claude.hookEvents))
        for event in AgentSource.claude.hookEvents {
            let commands = (hooks[event] as? [[String: Any]] ?? [])
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
            XCTAssertTrue(commands.contains(golden), "\(event) carries the golden command")
        }
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .current)
        menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(menu.items[try hookEntry(menu, .claude)].title, "Remove Claude Code hooks")

        menu.performActionForItem(at: try hookEntry(menu, .claude))
        let after = try settings(.claude)
        XCTAssertEqual(after["model"] as? String, "opus")
        let left = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Array(left.keys), ["Stop"], "only Evlat's groups went")
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .missing)
        menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(menu.items[try hookEntry(menu, .claude)].title, "Install Claude Code hooks")
    }

    func testARefusedWriteLeavesOneDimLineUntilItSucceeds() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        let broken = Data("{ not json".utf8)
        try broken.write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        var menu = controller.makeMenu(diagnostics: false, in: "tr")
        let before = menu.items.count
        menu.performActionForItem(at: try hookEntry(menu, .claude))
        XCTAssertEqual(try Data(contentsOf: file), broken, "the file is left as it was")
        menu = controller.makeMenu(diagnostics: false, in: "tr")
        let entry = try hookEntry(menu, .claude)
        let line = menu.items[entry + 1]
        XCTAssertEqual(line.title, L10n.t("menu.hooks.error.malformed", in: "tr"))
        XCTAssertFalse(line.isEnabled, "dim")
        XCTAssertEqual(menu.items.count, before + 1, "one line")

        try Data("{}".utf8).write(to: file)
        menu.performActionForItem(at: entry)
        menu = controller.makeMenu(diagnostics: false, in: "tr")
        XCTAssertEqual(menu.items.count, before, "the line goes with the success")
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .current)
    }

    func testEveryFailureHasALine() {
        let failures: [HookSettings.Failure] = [.unreadable, .malformed, .noDirectory, .changedUnderneath, .unwritable]
        let keys = Set(failures.map(AppController.failureKey))
        XCTAssertEqual(keys.count, failures.count, "one line per failure")
        XCTAssertTrue(keys.isSubset(of: Set(AppController.menuKeys)))
    }

    /// Like the edge: the file is written, the open list closes, and Evlat
    /// is not activated.
    func testTheHookEntryTakesNoFocus() throws {
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

        let menu = controller.makeMenu(diagnostics: false, in: "en")
        menu.performActionForItem(at: try hookEntry(menu, .claude))
        XCTAssertEqual(try HookSettings.state(at: AgentSource.claude.settingsFile(home: home), for: .claude),
                       .current)
        XCTAssertFalse(controller.barState.isOpen, "the open list closes")
        XCTAssertFalse(controller.hover.isOpen)
        XCTAssertFalse(isFrontmost(), "a hook entry must not activate Evlat")
        XCTAssertFalse(panel.isKeyWindow)
    }

    // MARK: - The usage line entry

    private func usageEntry(_ menu: NSMenu) -> Int? {
        menu.items.firstIndex { $0.representedObject is AppController.UsageEntry }
    }

    func testTheUsageEntryIsOnlyForClaude() throws {
        try agentDirectory(.codex)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        XCTAssertNil(usageEntry(controller.makeMenu(diagnostics: false, in: "en")), "no ~/.claude, no entry")
        let homeless = self.controller()
        defer { homeless.panel?.close() }
        try agentDirectory(.claude)
        XCTAssertNil(usageEntry(homeless.makeMenu(diagnostics: false, in: "en")), "no home, no entry")
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(try XCTUnwrap(usageEntry(menu)), try hookEntry(menu, .claude) + 1,
                       "right under Claude's hook entry")
        XCTAssertEqual(menu.items[try XCTUnwrap(usageEntry(menu))].toolTip, L10n.t("menu.usage.hint", in: "en"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.claude.settingsFile(home: home).path),
                       "opening the menu writes nothing")
    }

    func testTheUsageEntryInstallsThenRemoves() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        let original = #"{"model": "opus", "statusLine": {"type": "command", "command": "bash ~/s.sh", "padding": 0}}"#
        try Data(original.utf8).write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }

        var menu = controller.makeMenu(diagnostics: false, in: "tr")
        XCTAssertEqual(menu.items[try XCTUnwrap(usageEntry(menu))].title, "Kullanım satırını kur")
        menu.performActionForItem(at: try XCTUnwrap(usageEntry(menu)))
        let line = try XCTUnwrap(try settings(.claude)["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, StatusLineRelay.command(wrapping: "bash ~/s.sh"))
        XCTAssertEqual(line["padding"] as? Int, 0)
        XCTAssertEqual(try StatusLineRelay.state(at: file), .current)

        menu = controller.makeMenu(diagnostics: false, in: "tr")
        XCTAssertEqual(menu.items[try XCTUnwrap(usageEntry(menu))].title, "Kullanım satırını kaldır")
        menu.performActionForItem(at: try XCTUnwrap(usageEntry(menu)))
        let back = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: try settings(.claude)).isEqual(to: try XCTUnwrap(back)))
        XCTAssertEqual(menu.items.count, controller.makeMenu(diagnostics: false, in: "tr").items.count,
                       "no failure line")
    }

    func testAHandEditedWrapperIsADimLine() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        let edited = StatusLineRelay.command(wrapping: "cat").replacingOccurrences(of: "-m 2", with: "-m 9")
        let bytes = try JSONSerialization.data(withJSONObject: ["statusLine": ["command": edited]])
        try bytes.write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let index = try hookEntry(menu, .claude) + 1
        XCTAssertEqual(menu.items[index].title, "Usage line edited by hand")
        XCTAssertFalse(menu.items[index].isEnabled)
        XCTAssertNil(menu.items[index].action)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testARefusedUsageWriteLeavesOneDimLine() throws {
        try agentDirectory(.claude)
        let file = AgentSource.claude.settingsFile(home: home)
        try Data(#"{"statusLine": "bash s.sh"}"#.utf8).write(to: file)
        let controller = controller(home: home)
        defer { controller.panel?.close() }
        var menu = controller.makeMenu(diagnostics: false, in: "en")
        let before = menu.items.count
        menu.performActionForItem(at: try XCTUnwrap(usageEntry(menu)))
        menu = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertEqual(menu.items.count, before + 1)
        let line = menu.items[try XCTUnwrap(usageEntry(menu)) + 1]
        XCTAssertEqual(line.title, L10n.t("menu.hooks.error.malformed", in: "en"))
        XCTAssertFalse(line.isEnabled)
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
        XCTAssertEqual(AppController.sessionsDirectory(["EVLAT_HOME": "/tmp/h"]).path, "/tmp/h/.claude/sessions")
        XCTAssertEqual(AppController.sessionsDirectory(["EVLAT_HOME": "/tmp/h", "EVLAT_SESSIONS": "/tmp/s"]).path,
                       "/tmp/s", "EVLAT_SESSIONS comes first")
        XCTAssertEqual(AppController.sessionsDirectory(["EVLAT_SESSIONS": ""]).standardizedFileURL.path,
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent(".claude/sessions").standardizedFileURL.path)
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
        let local = CGPoint(x: panel.edge.x(atInset: x, in: bounds), y: bounds.minY + y)
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
            XCTAssertEqual(menu.map(titles)?.count, 3, "\(edge): the mascot menu, without Force state")
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
            let local = CGPoint(x: view.bounds.maxX - AppController.barWidth / 2, y: view.bounds.minY + y)
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
        XCTAssertEqual(right.map { titles($0).count }, right.map { _ in 3 })
        let control = try asks(.leftMouseDown, .control, fromTop: middle)
        XCTAssertFalse(control.isEmpty, "a ctrl-click on the mascot")
        XCTAssertEqual(control.map { titles($0).count }, control.map { _ in 3 })
        XCTAssertEqual(try asks(.rightMouseDown, [], fromTop: AppController.slotTop(0) + 5), [],
                       "a ring opens nothing")
        XCTAssertFalse(NSRunningApplication.current.isActive)
        XCTAssertFalse(panel.isKeyWindow)
    }
}
