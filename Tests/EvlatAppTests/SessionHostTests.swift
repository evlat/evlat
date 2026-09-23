import XCTest
@testable import EvlatApp

/// Finding a session's terminal from its pid, without a permission. The walk
/// is pure over five lookups, so every chain measured on a real machine
/// (`005` context.md → Kanıt) is a table here.
final class SessionHostTests: XCTestCase {
    /// A fake process table: pid → (parent, executable path, the app if the
    /// process is a `.regular` one).
    private struct Proc {
        let parent: Int32
        let path: String?
        var app: SessionHost.App? = nil
    }

    private let metalterm = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
    private let code = SessionHost.App(bundleID: "com.microsoft.VSCode", name: "Code", pid: 600)
    private let orca = SessionHost.App(bundleID: "com.stablyai.orca", name: "Orca", pid: 700)

    private static let orcaHelper =
        "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper"

    private func probe(_ table: [Int32: Proc],
                       bundles: [String: (bundleID: String, name: String)] = [:],
                       running: [String: SessionHost.App] = [:]) -> SessionHost.Probe {
        SessionHost.Probe(parent: { table[$0]?.parent },
                          regularApp: { table[$0]?.app },
                          executablePath: { table[$0]?.path },
                          bundle: { bundles[$0] },
                          running: { running[$0] })
    }

    func testADirectTerminal() {
        // claude → -zsh → login → Metalterm
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 700, path: "/bin/zsh"),
            700: Proc(parent: 500, path: "/usr/bin/login"),
            500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table)), .app(metalterm))
    }

    /// Electron helpers are `.accessory`: the lookup does not return them, so
    /// the walk goes on to the editor itself.
    func testAnElectronHelperIsPassedForItsRegularParent() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 650, path: "/Users/u/.local/bin/claude"),
            650: Proc(parent: 600,
                      path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            600: Proc(parent: 1, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", app: code),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table)), .app(code))
    }

    /// Orca's pty server is a helper parented to launchd: the walk never
    /// reaches the app, and the helper's path names the outer bundle.
    func testALaunchdHelperFallsBackToItsOuterBundle() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 750, path: "/bin/zsh"),
            750: Proc(parent: 1, path: Self.orcaHelper),
        ]
        let host = SessionHost.resolve(pid: 900, probe(table,
                                                       bundles: ["/Applications/Orca.app": ("com.stablyai.orca", "Orca")],
                                                       running: ["com.stablyai.orca": orca]))
        XCTAssertEqual(host, .app(orca))
    }

    func testTheFallbacksAppNotRunningIsClosed() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 750, path: "/Users/u/.local/bin/claude"),
            750: Proc(parent: 1, path: Self.orcaHelper),
        ]
        let host = SessionHost.resolve(pid: 900, probe(table,
                                                       bundles: ["/Applications/Orca.app": ("com.stablyai.orca", "Orca")]))
        XCTAssertEqual(host, .closed(name: "Orca"), "never opened, only named")
    }

    /// Claude Code ships inside a bundle of its own. That is the agent, not
    /// its terminal: it is neither the fallback's answer nor a "closed" app.
    func testTheAgentsOwnBundleIsNotItsTerminal() {
        let agent = "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"
        let bundles: [String: (bundleID: String, name: String)] = [
            "/Users/u/.local/share/claude/ClaudeCode.app": ("com.anthropic.claude-code", "Claude Code"),
            "/Applications/Orca.app": ("com.stablyai.orca", "Orca"),
        ]
        let viaOrca: [Int32: Proc] = [
            900: Proc(parent: 800, path: agent),
            800: Proc(parent: 750, path: "/bin/zsh"),
            750: Proc(parent: 1, path: Self.orcaHelper),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(viaOrca, bundles: bundles)), .closed(name: "Orca"))
        let alone: [Int32: Proc] = [900: Proc(parent: 1, path: agent)]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(alone, bundles: bundles)), .notFound)
    }

    /// Of two bundles up the chain, the farther one hosts the terminal.
    func testTheFarthestBundleIsAskedFirst() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 750, path: "/Applications/Tool.app/Contents/MacOS/tool"),
            750: Proc(parent: 1, path: Self.orcaHelper),
        ]
        let bundles: [String: (bundleID: String, name: String)] = [
            "/Applications/Tool.app": ("x.tool", "Tool"),
            "/Applications/Orca.app": ("com.stablyai.orca", "Orca"),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table, bundles: bundles)), .closed(name: "Orca"))
    }

    /// `screen` or ssh: the chain reaches launchd through no app and no bundle.
    func testAChainWithNoAppIsNotFound() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 1, path: "/usr/bin/screen"),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table)), .notFound)
    }

    func testNoPidOrAMissingProcessIsNotFound() {
        XCTAssertEqual(SessionHost.resolve(pid: nil, probe([:])), .notFound)
        XCTAssertEqual(SessionHost.resolve(pid: 4242, probe([:])), .notFound)
        XCTAssertEqual(SessionHost.resolve(pid: 1, probe([:])), .notFound, "launchd is never a session")
    }

    func testAProcessThatIsItsOwnParentEnds() {
        var asked = 0
        let probe = SessionHost.Probe(parent: { asked += 1; return $0 },
                                      regularApp: { _ in nil },
                                      executablePath: { _ in nil },
                                      bundle: { _ in nil }, running: { _ in nil })
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe), .notFound)
        XCTAssertEqual(asked, 1)
    }

    func testTheWalkStopsAtTheStepLimit() {
        var asked = 0
        // An endless chain upward: 900 → 901 → 902 → …
        let probe = SessionHost.Probe(parent: { asked += 1; return $0 + 1 },
                                      regularApp: { _ in nil },
                                      executablePath: { _ in nil },
                                      bundle: { _ in nil }, running: { _ in nil })
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe), .notFound)
        XCTAssertEqual(asked, SessionHost.maxSteps)
    }

    func testTheOutermostBundleIsPicked() {
        XCTAssertEqual(SessionHost.outermostApp(in: Self.orcaHelper), "/Applications/Orca.app")
        XCTAssertEqual(SessionHost.outermostApp(in: "/Users/u/Applications/My Term.app/Contents/MacOS/t"),
                       "/Users/u/Applications/My Term.app")
        XCTAssertNil(SessionHost.outermostApp(in: "/usr/bin/login"))
        XCTAssertNil(SessionHost.outermostApp(in: "/opt/tools/.app-cache/bin/x"),
                     "a component that only starts with .app is not a bundle")
    }

    /// A bundle with no window (`LSUIElement`) is skipped, not called closed.
    func testAWindowlessBundleIsNobodysTerminal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, _ plist: [String: Any]) throws -> String {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return root.appendingPathComponent("\(name).app").path
        }
        let agent = try make("Agent", ["CFBundleIdentifier": "x.agent", "CFBundleName": "Agent",
                                       "LSUIElement": true])
        let term = try make("Term", ["CFBundleIdentifier": "x.term", "CFBundleName": "Term"])
        XCTAssertNil(SessionHost.bundle(agent))
        let found = try XCTUnwrap(SessionHost.bundle(term))
        XCTAssertEqual(found.bundleID, "x.term")
        XCTAssertEqual(found.name, "Term")
    }

    /// The real lookups, read without a permission: this process's parent and
    /// its own executable, and nothing for a pid no process has.
    func testTheRealLookupsReadThisProcess() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let live = SessionHost.live
        XCTAssertNotNil(live.parent(me))
        // The test runner re-executes itself, so `Bundle.main` names another
        // copy: the path is checked for being a real executable instead.
        let path = try XCTUnwrap(live.executablePath(me))
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        XCTAssertNil(live.parent(Int32.max))
        XCTAssertNil(live.executablePath(Int32.max))
        XCTAssertEqual(SessionHost.launchPath(me).map { ($0 as NSString).lastPathComponent },
                       (path as NSString).lastPathComponent,
                       "the fallback reads the same executable from the argument area")
        XCTAssertNil(live.regularApp(Int32.max))
    }
}
