import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// The settings window's model: the side list's dots, the
/// modes only with a `claude`, the memory's inline confirmation, the menu's
/// entry and `EVLAT_SETTINGS`. Every writer is a recorder or a controller
/// with a suite of its own and no home: nothing of the user's is touched.
@MainActor
final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "evlat.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private final class Recorder {
        var claude: String? = "/usr/local/bin/claude"
        var memory: Int? = 2
        var cleared = 0
        var unreachable: [String] = []
        var hotKeyRefused = false
        var mode = ChatMode.auto
        /// Only for the command link's row: a temporary home and a binary.
        var home: URL?
        var binary: URL?
        var loginPath: String?
        var bodyMode = BodyPresence.Mode.always
        var bodyToggles = BodyPresence.Toggles()
        var displays: [BarDisplay] = []
        var display: (id: String, name: String)?
        var edge = BarPanel.Edge.right
        var language: String?
        var systemLanguage = "tr"
        /// Runs in the `claude` lookup, before its answer.
        var onLookup: () -> Void = {}
        /// The second chat backend's program, and the chosen backend.
        var codex: String? = nil
        var backend = AgentID.claude
        var versions: [AgentID: String] = [:]
    }

    private func model(_ recorder: Recorder) -> SettingsModel {
        let host = SettingsModel.Host(
            edge: { recorder.edge }, setEdge: { recorder.edge = $0 },
            displays: { recorder.displays }, display: { recorder.display },
            setDisplay: { id in recorder.display = id.map { id in (id, recorder.displays.first { $0.id == id }?.name ?? id) } },
            language: { recorder.language }, setLanguage: { recorder.language = $0 },
            systemLanguage: { recorder.systemLanguage },
            isHotKeyOn: { true }, setHotKey: { _ in },
            hotKey: { .standard },
            chatBackend: { Agents.chatBackends.first { $0.id == recorder.backend }! },
            setChatBackend: { recorder.backend = $0 },
            defaultMode: { recorder.mode }, setDefaultMode: { recorder.mode = $0 },
            locateBackend: { id, done in
                if id == .claude { recorder.onLookup() }
                done(id == .claude ? recorder.claude : recorder.codex)
            },
            chatVersion: { recorder.versions[$0] },
            memoryCount: { recorder.memory },
            showMemory: {},
            clearMemory: { recorder.cleared += 1; recorder.memory = 0 },
            bodyMode: { recorder.bodyMode }, setBodyMode: { recorder.bodyMode = $0 },
            bodyToggles: { recorder.bodyToggles }, setBodyToggles: { recorder.bodyToggles = $0 })
        let setup = SetupModel(host: SetupModel.Host(
            home: { recorder.home }, binary: { recorder.binary }, loginStatus: { nil },
            loginPath: { recorder.loginPath },
            hotKeyRefused: { recorder.hotKeyRefused }, unreachableMachines: { recorder.unreachable },
            setAgent: { _, _ in }, setCommandLink: { _, _ in }, setLoginItem: { _ in },
            agentFailure: { _ in nil }, commandLinkFailure: { nil },
            loginItemFailed: { false }), lang: "en")
        let remote = RemoteMachinesModel(host: RemoteMachinesModel.Host(
            machines: { [] }, state: { _ in nil }, sessionCounts: { [:] }, add: { _ in .failure(.empty) },
            remove: { _ in }, isStored: { true }, signalKey: { _ in nil }),
            installer: RemoteInstaller(sshPath: "/nonexistent"), lang: "en")
        return SettingsModel(host: host, setup: setup, remote: remote,
                             recorder: HotKeyRecorder(systemHotKeys: { SystemHotKeys(entries: [:]) }), lang: "en")
    }

    private static func screen(_ id: String, _ name: String, x: CGFloat) -> BarDisplay {
        let frame = NSRect(x: x, y: 0, width: 1920, height: 1080)
        return BarDisplay(id: id, name: name, frame: frame, visibleFrame: frame)
    }

    /// One screen is no choice: no row.
    func testTheScreenRowWaitsForASecondScreen() {
        let recorder = Recorder()
        recorder.displays = [Self.screen("A", "Built-in", x: 0)]
        let model = model(recorder)
        XCTAssertFalse(model.showsDisplay)
        recorder.displays.append(Self.screen("B", "DELL", x: 1920))
        XCTAssertTrue(model.showsDisplay)
        XCTAssertEqual(model.displayChoices.map(\.title), ["Main screen (menu bar)", "Built-in", "DELL"])
        XCTAssertEqual(model.displayChoices.map(\.id), [nil, "A", "B"])
        XCTAssertNil(model.display)
    }

    func testTheScreenRowGoesToTheWriter() {
        let recorder = Recorder()
        recorder.displays = [Self.screen("A", "Built-in", x: 0), Self.screen("B", "DELL", x: 1920)]
        let model = model(recorder)
        model.setDisplay("B")
        XCTAssertEqual(recorder.display?.id, "B")
        XCTAssertEqual(model.display, "B")
        model.setDisplay(nil)
        XCTAssertNil(recorder.display)
    }

    /// Unplugged, the pinned screen stays the selection, said so; the row
    /// stays even with one screen left, so it can be let go of.
    func testAnUnpluggedScreenStaysTheSelection() {
        let recorder = Recorder()
        recorder.displays = [Self.screen("A", "Built-in", x: 0)]
        recorder.display = ("B", "DELL")
        let model = model(recorder)
        XCTAssertTrue(model.showsDisplay)
        XCTAssertEqual(model.displayChoices.last, .init(id: "B", title: "DELL (not connected)"))
        XCTAssertEqual(model.display, "B")
    }

    /// The seam note follows the edge and the screen in force: the left
    /// screen's right edge is a seam, its left edge a wall; an unplugged
    /// pin is judged on the main screen the bar waits on.
    func testTheSeamNoteFollowsTheEdgeAndTheScreen() {
        let recorder = Recorder()
        recorder.displays = [Self.screen("L", "Left", x: 0), Self.screen("R", "Right", x: 1920)]
        let model = model(recorder)
        XCTAssertTrue(model.displayOnSeam, "main is the left screen, docked right")
        model.setEdge(.left)
        XCTAssertFalse(model.displayOnSeam)
        model.setDisplay("R")
        XCTAssertTrue(model.displayOnSeam, "the right screen's left edge")
        model.setEdge(.right)
        XCTAssertFalse(model.displayOnSeam)
        recorder.display = ("GONE", "Old")
        XCTAssertTrue(model.displayOnSeam, "waiting on the main one, docked right")
    }

    func testTheDotsFollowTheAttentionList() {
        let recorder = Recorder()
        let model = model(recorder)
        model.reload()
        XCTAssertEqual(model.dots, [])
        recorder.unreachable = ["devbox"]
        model.follow()
        XCTAssertEqual(model.dots, [.remote], "a machine going down is a dot, read at the next refresh")
        recorder.hotKeyRefused = true
        model.reload()
        XCTAssertEqual(model.dots, [.remote, .chat])
        recorder.unreachable = []
        recorder.hotKeyRefused = false
        model.follow()
        XCTAssertEqual(model.dots, [])
    }

    /// The login shell's `PATH` arrives with the `claude` lookup, after the
    /// first reading: the note is read again when it does.
    func testThePathNoteAppearsOnceTheLookupReadsThePath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.settings.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let recorder = Recorder()
        recorder.home = home
        recorder.binary = home.appendingPathComponent("Evlat")
        recorder.onLookup = { recorder.loginPath = "/usr/bin:/bin" }
        let model = model(recorder)
        model.reload()
        XCTAssertEqual(model.setup.row(.commandLink)?.note,
                       "~/.local/bin is not on your shell's PATH: add it to type evlat alone.")
    }

    func testTheModesAreOfferedOnlyWithAClaude() {
        let recorder = Recorder()
        let model = model(recorder)
        XCTAssertFalse(model.showsModes, "not looked for yet")
        model.reload()
        XCTAssertTrue(model.showsModes)
        model.setMode(.acceptEdits)
        XCTAssertEqual(recorder.mode, .acceptEdits)
        XCTAssertEqual(model.mode, .acceptEdits)
        recorder.claude = nil
        model.reload()
        XCTAssertEqual(model.backend, .missing)
        XCTAssertFalse(model.showsModes, "no claude, no mode to pick")
    }

    /// "Chat with": one program found is a plain row and nothing to pick;
    /// two found are a choice, and a backend not found cannot be picked.
    /// The chosen one's note and a version it was not checked against are
    /// said under it; only Claude's chats have the memory.
    func testTheChatsBackendIsPickedAmongTheFound() {
        let recorder = Recorder()
        let model = model(recorder)
        model.reload()
        XCTAssertEqual(model.backendChoices.map(\.id), [.claude, .codex])
        XCTAssertEqual(model.backendChoices.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(model.backendChoices.map(\.isFound), [true, false])
        XCTAssertEqual(model.backendChoices.map(\.experimental), [false, true])
        XCTAssertFalse(model.picksBackend, "one found is no choice")
        model.setBackend(.codex)
        XCTAssertEqual(recorder.backend, .claude, "a program not found is never picked")
        XCTAssertTrue(model.hasMemory)
        XCTAssertNil(model.backendNote)

        recorder.codex = "/opt/homebrew/bin/codex"
        model.reload()
        XCTAssertTrue(model.picksBackend)
        XCTAssertEqual(model.backendChoices.last?.path, "/opt/homebrew/bin/codex")
        model.setBackend(.codex)
        XCTAssertEqual(recorder.backend, .codex)
        XCTAssertEqual(model.selectedBackend, .codex)
        XCTAssertFalse(model.hasMemory, "the memory is Claude's")
        XCTAssertEqual(model.offeredModes.map(\.id), ["workspace", "readOnly"])
        XCTAssertEqual(model.backendNote, L10n.t("settings.chat.backend.codex.note", in: "en"))
        XCTAssertNil(model.versionWarning, "no turn has said a version")
        recorder.versions[.codex] = "0.156.1"
        XCTAssertNil(model.versionWarning, "the measured one says nothing")
        recorder.versions[.codex] = "0.158.0"
        defer {
            // The chosen program gone, the other still there: the radio
            // stays, the way back.
            recorder.codex = nil
            model.reload()
            XCTAssertTrue(model.picksBackend)
            model.setBackend(.claude)
            XCTAssertEqual(recorder.backend, .claude)
        }
        XCTAssertEqual(model.versionWarning,
                       "Codex 0.158.0 answered; Evlat was checked against 0.156.1. If the chat misbehaves, this may be why.")
    }

    func testClearingTheMemoryAsksFirst() {
        let recorder = Recorder()
        let model = model(recorder)
        model.confirmClear()
        XCTAssertEqual(recorder.cleared, 0, "one press removes nothing")
        model.askToClear()
        XCTAssertTrue(model.confirmingClear)
        XCTAssertTrue(model.cancelInside(), "Esc answers the question")
        XCTAssertFalse(model.confirmingClear)
        XCTAssertEqual(recorder.cleared, 0)
        model.askToClear()
        model.confirmClear()
        XCTAssertEqual(recorder.cleared, 1)
        XCTAssertEqual(model.memoryCount, 0)
        model.askToClear()
        XCTAssertFalse(model.confirmingClear, "nothing to clear, nothing asked")
        XCTAssertFalse(model.cancelInside(), "no question: Esc closes the window")
    }

    func testTheEnvironmentOpensASection() {
        XCTAssertEqual(AppController.forcedSettings(["EVLAT_SETTINGS": "remote"]), .remote)
        XCTAssertEqual(AppController.forcedSettings(["EVLAT_SETTINGS": " Command "]), .commandLine)
        XCTAssertEqual(AppController.forcedSettings(["EVLAT_SETTINGS": "commandLine"]), .commandLine)
        XCTAssertNil(AppController.forcedSettings(["EVLAT_SETTINGS": "nope"]))
        XCTAssertNil(AppController.forcedSettings([:]))
    }

    func testBothMenusOpenTheSettings() throws {
        let controller = AppController(defaults: defaults)
        controller.installPanel()
        controller.settingsActivation = { }
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        for diagnostics in [false, true] {
            let menu = controller.makeMenu(diagnostics: diagnostics, in: "en")
            let entry = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
            XCTAssertEqual(entry.keyEquivalent, ",")
            XCTAssertTrue(entry.target === controller)
            XCTAssertEqual(entry.action, #selector(AppController.openSettingsFromMenu(_:)))
        }
        controller.openSettings(section: .agents)
        let window = try XCTUnwrap(controller.settingsWindow?.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertEqual(controller.settings?.section, .agents)
        XCTAssertFalse(try XCTUnwrap(controller.panel).canBecomeKey, "the bar stays a non-activating panel")
    }

    func testEveryKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in SettingsModel.keys + ["menu.settings"] {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
        XCTAssertEqual(SettingsModel.tilde("/Users/me/.local/bin/claude", home: "/Users/me"), "~/.local/bin/claude")
        XCTAssertEqual(SettingsModel.tilde("/opt/claude", home: "/Users/me"), "/opt/claude")
    }
    // MARK: - Body

    /// The choice goes to the writer; the switches are offered only under
    /// Smart, and turning the waiting peek off says what is left of it.
    func testTheBodyRowGoesToTheWriterAndShowsTheSwitchesOnlyWhenSmart() {
        let recorder = Recorder()
        let model = model(recorder)
        XCTAssertEqual(model.bodyMode, .always)
        XCTAssertFalse(model.showsBodyToggles, "today's bar has nothing to switch")
        XCTAssertFalse(model.showsPeekWarning)
        model.setBodyMode(.smart)
        XCTAssertEqual(recorder.bodyMode, .smart)
        XCTAssertTrue(model.showsBodyToggles)
        XCTAssertFalse(model.showsPeekWarning, "every switch on: nothing to warn about")
        model.setBodyToggle(\.peekWaiting, on: false)
        XCTAssertEqual(recorder.bodyToggles, BodyPresence.Toggles(sliver: true, peekWaiting: false, peekDone: true))
        XCTAssertTrue(model.showsPeekWarning)
        XCTAssertEqual(model.peekWarningKey, "settings.general.body.peekWaiting.off", "the amber dot is still there")
        model.setBodyToggle(\.sliver, on: false)
        XCTAssertEqual(recorder.bodyToggles, BodyPresence.Toggles(sliver: false, peekWaiting: false, peekDone: true))
        XCTAssertTrue(model.showsPeekWarning)
        XCTAssertEqual(model.peekWarningKey, "settings.general.body.peekWaiting.off.bare",
                       "no sliver, no peek: the warning says nothing is left on the edge")
        model.setBodyMode(.hidden)
        XCTAssertFalse(model.showsBodyToggles, "hidden has neither sliver nor peek")
        XCTAssertFalse(model.showsPeekWarning)
    }

    /// The controller's writers store the choice and apply it at once.
    func testTheBodyWritersStoreAndApply() throws {
        let controller = AppController(defaults: defaults)
        let panel = controller.installPanel()
        defer { panel.close() }
        let host = controller.settingsHost
        host.setBodyMode(.smart)
        XCTAssertEqual(controller.bodyMode, .smart)
        XCTAssertEqual(host.bodyMode(), .smart)
        XCTAssertEqual(defaults.string(forKey: AppController.bodyModeKey), "smart")
        XCTAssertNotEqual(controller.barState.presence.level, .full, "applied to the bar at once")
        host.setBodyToggles(BodyPresence.Toggles(sliver: false, peekWaiting: true, peekDone: false))
        XCTAssertEqual(AppController.storedBodyToggles(defaults),
                       BodyPresence.Toggles(sliver: false, peekWaiting: true, peekDone: false))
        XCTAssertEqual(controller.barState.presence.level, .none, "the sliver switched off is gone")
    }

    /// Under `EVLAT_BODY` the writers apply but never store: the user's
    /// choice is not overwritten by a forced launch.
    func testAForcedBodyIsAppliedButNotStored() {
        let controller = AppController(defaults: defaults)
        let panel = controller.installPanel()
        defer { panel.close() }
        controller.bodyForced = true
        let host = controller.settingsHost
        host.setBodyMode(.hidden)
        host.setBodyToggles(BodyPresence.Toggles(sliver: true, peekWaiting: false, peekDone: true))
        XCTAssertEqual(controller.bodyMode, .hidden)
        XCTAssertEqual(controller.bodyToggles.peekWaiting, false)
        XCTAssertNil(defaults.object(forKey: AppController.bodyModeKey))
        XCTAssertNil(defaults.object(forKey: AppController.bodyPeekWaitingKey))
        XCTAssertNil(defaults.object(forKey: AppController.bodySliverKey))
    }

    /// "Language": the system's first, named for the table it resolves to
    /// now, then every table by its own name; the choice goes to the writer.
    func testTheLanguageRowOffersTheSystemsThenEveryTableByItsOwnName() {
        let recorder = Recorder()
        let model = model(recorder)
        let options = model.languageOptions
        XCTAssertEqual(options.first, SettingsModel.LanguageOption(id: nil, title: "System (Türkçe)"))
        XCTAssertEqual(options.dropFirst().compactMap(\.id).sorted(), L10n.catalog.available.sorted())
        XCTAssertTrue(options.contains(SettingsModel.LanguageOption(id: "uk", title: "Українська")))
        XCTAssertNil(model.language)
        model.setLanguage("de")
        XCTAssertEqual(recorder.language, "de")
        XCTAssertEqual(model.language, "de")
    }

    /// The window's words follow a new language, its composed rows too.
    func testANewLanguageReachesTheWindowsModels() {
        let model = model(Recorder())
        XCTAssertEqual(model.t("settings.general.language"), "Language")
        model.languageChanged(to: "tr")
        XCTAssertEqual(model.lang, "tr")
        XCTAssertEqual(model.setup.lang, "tr")
        XCTAssertEqual(model.remote.lang, "tr")
        XCTAssertEqual(model.t("settings.general.language"), "Dil")
    }

    /// The choice is stored where System Settings keeps an app's own
    /// language (`AppleLanguages` in its domain), drawn at once, and
    /// "System" takes it out again.
    func testTheLanguageIsStoredAsTheAppsOwnAndDrawnAtOnce() {
        let original = L10n.language
        defer { L10n.language = original }
        let controller = AppController(defaults: defaults)
        controller.languageDomain = suiteName
        let host = controller.settingsHost
        XCTAssertNil(host.language())
        host.setLanguage("de")
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?[LanguageChoice.key] as? [String], ["de"])
        XCTAssertEqual(host.language(), "de")
        XCTAssertEqual(L10n.language, "de")
        XCTAssertEqual(controller.barState.language, "de", "the bar's views are built again")
        XCTAssertEqual(controller.chatModel.language, "de", "the balloon's too")
        XCTAssertEqual(L10n.t("status.working"), L10n.t("status.working", in: "de"))
        host.setLanguage(nil)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[LanguageChoice.key])
        XCTAssertNil(host.language())
        XCTAssertEqual(L10n.language, controller.systemLanguage)
    }

    /// With no domain named — `swift run`, and every other test — the
    /// choice is kept in memory and nothing is written.
    func testWithNoDomainTheLanguageIsNotStored() {
        let original = L10n.language
        defer { L10n.language = original }
        let controller = AppController(defaults: defaults)
        controller.settingsHost.setLanguage("ja")
        XCTAssertEqual(controller.settingsHost.language(), "ja")
        XCTAssertEqual(L10n.language, "ja")
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[LanguageChoice.key])
    }
}
