import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

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
        var mode = PermissionMode.auto
        /// Only for the command link's row: a temporary home and a binary.
        var home: URL?
        var binary: URL?
        var loginPath: String?
        /// Runs in the `claude` lookup, before its answer.
        var onLookup: () -> Void = {}
    }

    private func model(_ recorder: Recorder) -> SettingsModel {
        let host = SettingsModel.Host(
            edge: { .right }, setEdge: { _ in }, isHotKeyOn: { true }, setHotKey: { _ in },
            hotKey: { .standard }, defaultMode: { recorder.mode }, setDefaultMode: { recorder.mode = $0 },
            locateClaude: { recorder.onLookup(); $0(recorder.claude) },
            memoryCount: { recorder.memory },
            showMemory: {},
            clearMemory: { recorder.cleared += 1; recorder.memory = 0 })
        let setup = SetupModel(host: SetupModel.Host(
            home: { recorder.home }, binary: { recorder.binary }, loginStatus: { nil },
            loginPath: { recorder.loginPath },
            hotKeyRefused: { recorder.hotKeyRefused }, unreachableMachines: { recorder.unreachable },
            setHooks: { _, _ in }, setUsageRelay: { _ in }, setCommandLink: { _, _ in }, setLoginItem: { _ in },
            hookFailure: { _ in nil }, usageFailure: { nil }, commandLinkFailure: { nil },
            loginItemFailed: { false }), lang: "en")
        let remote = RemoteMachinesModel(host: RemoteMachinesModel.Host(
            machines: { [] }, state: { _ in nil }, sessionCounts: { [:] }, add: { _ in .failure(.empty) },
            remove: { _ in }, isStored: { true }, signalKey: { _ in nil }),
            installer: RemoteInstaller(sshPath: "/nonexistent"), lang: "en")
        return SettingsModel(host: host, setup: setup, remote: remote,
                             recorder: HotKeyRecorder(systemHotKeys: { SystemHotKeys(entries: [:]) }), lang: "en")
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
        XCTAssertEqual(model.claude, .missing)
        XCTAssertFalse(model.showsModes, "no claude, no mode to pick")
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
        controller.openSettings(section: .sessions)
        let window = try XCTUnwrap(controller.settingsWindow?.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertEqual(controller.settings?.section, .sessions)
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
}
