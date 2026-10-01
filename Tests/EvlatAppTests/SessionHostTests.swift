import XCTest
@testable import EvlatApp

/// Finding a session's terminal from its pid, without a permission. The walk
/// is pure over five lookups, so every chain measured on a real machine is a
/// table here.
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
                       running: [String: SessionHost.App] = [:],
                       environment: [Int32: [String]] = [:],
                       arguments: [Int32: [String]] = [:]) -> SessionHost.Probe {
        SessionHost.Probe(parent: { table[$0]?.parent },
                          regularApp: { table[$0]?.app },
                          executablePath: { table[$0]?.path },
                          bundle: { bundles[$0] },
                          running: { running[$0] },
                          environment: { environment[$0] ?? [] },
                          arguments: { arguments[$0] ?? [] },
                          processes: { Array(table.keys) })
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

    // MARK: - Tab links

    private static let metaltermTab = "METALTERM_TAB_URL=metalterm://tab/12cc2c67c4d3a305"
    private static let bateriTab = "BATERI_TAB_URL=bateri://tab/85353B2C-0564-41A3-9E4A-52DC53B00316"

    /// The tab comes from the agent's own environment, and only for the app
    /// the walk found: the shell's and the terminal's are not asked.
    func testTheAgentsTabLinkRidesOnItsApp() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 500, path: "/bin/zsh"),
            500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm),
        ]
        let host = SessionHost.resolve(pid: 900, probe(table, environment: [
            900: ["HOME=/Users/u", Self.metaltermTab],
            800: ["METALTERM_TAB_URL=metalterm://tab/ffffffffffffffff"],
        ]))
        guard case .app(let app) = host else { return XCTFail("\(host)") }
        XCTAssertEqual(app.tab, URL(string: "metalterm://tab/12cc2c67c4d3a305"))
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table)), .app(metalterm), "no variable, no tab")
    }

    /// An app with no tab link never has the agent's environment read.
    func testAnAppWithoutATabLinkDoesNotReadTheEnvironment() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 600, path: "/Users/u/.local/bin/claude"),
            600: Proc(parent: 1, path: "/Applications/Code.app/Contents/MacOS/Code", app: code),
        ]
        var read: [Int32] = []
        var lookups = probe(table)
        lookups.environment = { read.append($0); return [Self.metaltermTab] }
        XCTAssertEqual(SessionHost.resolve(pid: 900, lookups), .app(code))
        XCTAssertEqual(read, [])
    }

    func testTabLinksAreCheckedNotTrusted() {
        let metal = "dev.metalterm.Metalterm", bateri = "io.github.bateri.bateri"
        XCTAssertEqual(TabLink.url(bundleID: metal, environment: [Self.metaltermTab]),
                       URL(string: "metalterm://tab/12cc2c67c4d3a305"))
        XCTAssertEqual(TabLink.url(bundleID: bateri, environment: [Self.bateriTab]),
                       URL(string: "bateri://tab/85353B2C-0564-41A3-9E4A-52DC53B00316"))
        XCTAssertEqual(TabLink.url(bundleID: "dev.bateri.bateri", environment: [Self.bateriTab]),
                       URL(string: "bateri://tab/85353B2C-0564-41A3-9E4A-52DC53B00316"),
                       "the id Bateri ships under today")
        let refused = [
            "METALTERM_TAB_URL=metalterm://tab/restart",
            "METALTERM_TAB_URL=metalterm://tab/",
            "METALTERM_TAB_URL=metalterm://tab/12cc/../restart",
            "METALTERM_TAB_URL=metalterm://tab/12cc2c67c4d3a305?x=1",
            "METALTERM_TAB_URL=metalterm://tab/12cc2c67c4d3a305#x",
            "METALTERM_TAB_URL=metalterm://block/12cc2c67c4d3a305",
            "METALTERM_TAB_URL=bateri://tab/12cc2c67c4d3a305",
            "METALTERM_TAB_URL=metalterm://tab/\u{FF11}\u{FF12}",
            "METALTERM_TAB_URL=metalterm://tab/" + String(repeating: "a", count: 65),
            "METALTERM_TAB_URLX=metalterm://tab/12cc2c67c4d3a305",
            Self.bateriTab,
        ]
        for line in refused {
            XCTAssertNil(TabLink.url(bundleID: metal, environment: [line]), line)
        }
        XCTAssertNil(TabLink.url(bundleID: "com.microsoft.VSCode", environment: [Self.metaltermTab]))
        XCTAssertEqual(TabLink.url(bundleID: metal, environment: [
            Self.metaltermTab, "METALTERM_TAB_URL=metalterm://tab/ffffffffffffffff",
        ]), URL(string: "metalterm://tab/12cc2c67c4d3a305"), "the first, as getenv reads it")
    }

    func testAWarpSessionOpensByItsFocusLink() {
        let warp = "dev.warp.Warp-Stable"
        XCTAssertEqual(TabLink.url(bundleID: warp, environment: [
            "WARP_FOCUS_URL=warp://session/64c22618f0fb408d8aaa5cf750cd3845",
        ]), URL(string: "warp://session/64c22618f0fb408d8aaa5cf750cd3845"))
        for value in ["warp://session/", "warp://linear", "warp://session/64c2/x", "warp://action/64c2"] {
            XCTAssertNil(TabLink.url(bundleID: warp, environment: ["WARP_FOCUS_URL=\(value)"]), value)
        }
    }

    /// iTerm's link takes the whole `ITERM_SESSION_ID`: it splits it at the
    /// `:` itself, and the UUID alone was seen to find no session.
    func testAnITermSessionRevealsByItsWholeID() {
        let iterm = "com.googlecode.iterm2"
        let id = "w0t0p0:C898A315-42EC-4D5E-93D7-7D34D4AD1C6C"
        XCTAssertEqual(TabLink.url(bundleID: iterm, environment: ["ITERM_SESSION_ID=\(id)"]),
                       URL(string: "iterm2:reveal?sessionid=\(id)"))
        let refused = [
            "C898A315-42EC-4D5E-93D7-7D34D4AD1C6C",
            "w0t0p0:",
            ":C898A315",
            "w0t0p0:C898&c=ls",
            "w0t0p0:C898#x",
            "w0/t0:C898",
            "w0t0p0:C898:x",
        ]
        for value in refused {
            XCTAssertNil(TabLink.url(bundleID: iterm, environment: ["ITERM_SESSION_ID=\(value)"]), value)
        }
    }

    /// iTerm's sessions hang off a server copied out of its bundle and
    /// parented to launchd: the server's own path names iTerm.
    func testAnITermSessionIsFoundThroughItsServer() {
        let iterm = SessionHost.App(bundleID: "com.googlecode.iterm2", name: "iTerm2", pid: 400)
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 700, path: "/bin/zsh"),
            700: Proc(parent: 600, path: "/usr/bin/login"),
            600: Proc(parent: 1, path: "/Users/u/Library/Application Support/iTerm2/iTermServer-3.4.23"),
        ]
        let id = "ITERM_SESSION_ID=w0t0p0:C898A315-42EC-4D5E-93D7-7D34D4AD1C6C"
        var expected = iterm
        expected.tab = URL(string: "iterm2:reveal?sessionid=w0t0p0:C898A315-42EC-4D5E-93D7-7D34D4AD1C6C")
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table, running: ["com.googlecode.iterm2": iterm],
                                                           environment: [900: [id]])), .app(expected))
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table)), .closed(name: "iTerm2"))
        for path in ["/tmp/iTerm2/iTermServer-1", "/Users/u/Library/Application Support/iTerm2/other",
                     "/Users/u/Library/Application Support/iTerm2/x/iTermServer-1"] {
            XCTAssertNil(SessionHost.helperBundle(path), path)
        }
    }

    /// Claude's desktop app gives the session's id, not a link: the link is
    /// built here, and only from an id of the shape the app accepts.
    func testAClaudeDesktopSessionOpensByItsID() {
        let claude = "com.anthropic.claudefordesktop"
        let id = "local_36be0359-4c18-44c6-889d-380645800298"
        XCTAssertEqual(TabLink.url(bundleID: claude, environment: ["CLAUDE_CODE_HOST_SESSION_ID=\(id)"]),
                       URL(string: "claude://code/continue?session=\(id)"))
        let refused = [
            "local_",
            "36be0359-4c18-44c6-889d-380645800298",
            "session_abc",
            "local_abc&session=last",
            "local_abc#x",
            "local_abc/../x",
            "local_ab c",
            "local_\u{00E7}",
            "local_" + String(repeating: "a", count: 65),
        ]
        for value in refused {
            XCTAssertNil(TabLink.url(bundleID: claude, environment: ["CLAUDE_CODE_HOST_SESSION_ID=\(value)"]),
                         value)
        }
        XCTAssertNil(TabLink.url(bundleID: "dev.metalterm.Metalterm",
                                 environment: ["CLAUDE_CODE_HOST_SESSION_ID=\(id)"]),
                     "a terminal started from a desktop session is not that session")
    }

    /// `KERN_PROCARGS2`: argc, the path, padding, the arguments, then the
    /// environment up to an empty string. Arguments are never taken for it.
    func testTheEnvironmentIsReadPastTheArguments() {
        func buffer(argc: UInt32, _ parts: [String], padding: Int = 3, tail: [UInt8] = [0, 0]) -> [UInt8] {
            var bytes = withUnsafeBytes(of: argc.littleEndian, Array.init)
            bytes += Array(parts[0].utf8) + [UInt8](repeating: 0, count: padding)
            for part in parts.dropFirst() { bytes += Array(part.utf8) + [0] }
            return bytes + tail
        }
        let full = buffer(argc: 2, ["/bin/claude", "claude", "A=argument", "HOME=/u", Self.metaltermTab])
        XCTAssertEqual(SessionHost.environment(procArgs: full), ["HOME=/u", Self.metaltermTab])
        XCTAssertEqual(SessionHost.environment(procArgs: buffer(argc: 5, ["/bin/claude", "claude"])), [])
        XCTAssertEqual(SessionHost.environment(procArgs: Array(full.prefix(30))), [])
        XCTAssertEqual(SessionHost.environment(procArgs: buffer(argc: 0, ["/p", "X=1"], tail: [])), ["X=1"],
                       "a buffer cut without its final NUL still gives what it holds")
        XCTAssertEqual(SessionHost.environment(procArgs: [1, 0]), [])
        XCTAssertEqual(SessionHost.environment(procArgs: []), [])
    }

    /// The real read: this process's environment, as `exec` gave it.
    func testTheRealEnvironmentIsThisProcesss() {
        let me = ProcessInfo.processInfo.processIdentifier
        let read = SessionHost.environment(me)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        XCTAssertTrue(read.contains("PATH=\(path)"), "\(read.count) variables")
        XCTAssertEqual(SessionHost.environment(Int32.max), [])
    }
}

extension SessionHostTests {
    /// cmux's tab is two ids; the link is its navigation route, and a
    /// value that is not a UUID or a missing half is no link.
    func testCmuxTabIsItsWorkspaceAndSurface() {
        let workspace = "CMUX_WORKSPACE_ID=018D3A58-43C5-4E55-A360-EB03CCDED11B"
        let surface = "CMUX_SURFACE_ID=5B3AB033-593B-4832-8B68-87D1AFEDD607"
        XCTAssertEqual(TabLink.url(bundleID: "com.cmuxterm.app", environment: ["TERM=x", surface, workspace]),
                       URL(string: "cmux://workspace/018D3A58-43C5-4E55-A360-EB03CCDED11B/surface/5B3AB033-593B-4832-8B68-87D1AFEDD607"))
        XCTAssertNil(TabLink.url(bundleID: "com.cmuxterm.app", environment: [workspace]), "half a tab is none")
        XCTAssertNil(TabLink.url(bundleID: "com.cmuxterm.app",
                                 environment: [workspace, "CMUX_SURFACE_ID=../restart"]))
    }
}

extension SessionHostTests {
    private static let herdr = "/Users/u/.local/bin/herdr"
    private static let staleTab = ["CMUX_WORKSPACE_ID=11111111-1111-4111-8111-111111111111",
                                   "CMUX_SURFACE_ID=22222222-2222-4222-8222-222222222222"]
    private static let clientTab = ["CMUX_WORKSPACE_ID=018D3A58-43C5-4E55-A360-EB03CCDED11B",
                                    "CMUX_SURFACE_ID=5B3AB033-593B-4832-8B68-87D1AFEDD607"]

    private var cmux: SessionHost.App { SessionHost.App(bundleID: "com.cmuxterm.app", name: "cmux", pid: 400) }

    /// As measured with herdr 0.9.1: claude → -zsh → `herdr server`, parented
    /// to launchd, and the `herdr` client in a cmux tab elsewhere. The pane
    /// still carries the tab the server was first started from.
    private var herdrInCmux: [Int32: Proc] {
        [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 700, path: "/bin/zsh"),
            700: Proc(parent: 1, path: Self.herdr),
            650: Proc(parent: 640, path: Self.herdr),
            640: Proc(parent: 630, path: "/bin/zsh"),
            630: Proc(parent: 400, path: "/usr/bin/login"),
            400: Proc(parent: 1, path: "/Applications/cmux.app/Contents/MacOS/cmux", app: cmux),
        ]
    }

    func testAHerdrPaneIsHostedWhereItsClientRuns() {
        let pane = ["HERDR_PANE_ID=w4:p2", "HERDR_SOCKET_PATH=/Users/u/.config/herdr/herdr.sock"]
        let host = SessionHost.resolve(pid: 900, probe(herdrInCmux,
                                                       environment: [900: Self.staleTab + pane, 650: Self.clientTab],
                                                       arguments: [700: [Self.herdr, "server"], 650: ["herdr"]]))
        var expected = cmux
        expected.tab = URL(string: "cmux://workspace/018D3A58-43C5-4E55-A360-EB03CCDED11B/surface/5B3AB033-593B-4832-8B68-87D1AFEDD607")
        expected.herdr = HerdrPane(executable: Self.herdr, pane: "w4:p2",
                                   socket: "/Users/u/.config/herdr/herdr.sock")
        XCTAssertEqual(host, .app(expected), "the client's tab, not the one the pane inherited, and the agent's pane")
    }

    /// The pane is selected by the server's own executable, with fixed
    /// arguments and only the socket in its environment.
    func testAHerdrPaneIsFocusedByItsId() throws {
        let pane = try XCTUnwrap(HerdrPane.of(herdr: Self.herdr,
                                              environment: ["TERM=x", "HERDR_PANE_ID=w4:p2",
                                                            "HERDR_SOCKET_PATH=/s/herdr.sock"]))
        XCTAssertEqual(pane.arguments, ["agent", "focus", "w4:p2"])
        XCTAssertEqual(pane.environment, ["HERDR_SOCKET_PATH": "/s/herdr.sock"])
        XCTAssertEqual(HerdrPane.of(herdr: Self.herdr, environment: ["HERDR_PANE_ID=w1:p1"])?.environment, [:],
                       "no socket: herdr's default")
        XCTAssertNil(HerdrPane.of(herdr: Self.herdr, environment: []), "not in a pane")
        XCTAssertNil(HerdrPane.of(herdr: "herdr", environment: ["HERDR_PANE_ID=w1:p1"]), "a path, not a name")
        XCTAssertNil(HerdrPane.of(herdr: Self.herdr, environment: ["HERDR_SOCKET_PATH=relative",
                                                                    "HERDR_PANE_ID=w1:p1"])?.socket)
        for bad in ["", "--help", "-w1", "w1 p1", "w1;rm", "w1/p1", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrPane.isPaneID(bad), bad)
        }
        XCTAssertTrue(HerdrPane.isPaneID("w12:p3"))
    }

    func testAHerdrServerWithNoClientIsNotFound() {
        var table = herdrInCmux
        table[650] = nil
        let host = SessionHost.resolve(pid: 900, probe(table, arguments: [700: [Self.herdr, "server"]]))
        XCTAssertEqual(host, .notFound)
    }

    /// `herdr pane list` run in a cmux tab is the CLI, not a client.
    func testHerdrsOwnSubcommandsAreNotClients() {
        let host = SessionHost.resolve(pid: 900, probe(herdrInCmux,
                                                       arguments: [700: [Self.herdr, "server"],
                                                                   650: ["herdr", "pane", "list"]]))
        XCTAssertEqual(host, .notFound)
    }

    /// Only a `herdr` that is a server is passed through: a client in the
    /// chain is just a process.
    func testOnlyAHerdrServerIsFollowed() {
        let host = SessionHost.resolve(pid: 900, probe(herdrInCmux,
                                                       arguments: [700: [Self.herdr], 650: ["herdr"]]))
        XCTAssertEqual(host, .notFound)
    }

    /// Two sessions: a named server's own client is taken, never another
    /// session's — whose client here is the newer pid and in another app.
    func testAHerdrClientOfAnotherSessionIsNotTaken() {
        var table = herdrInCmux
        table[660] = Proc(parent: 500, path: Self.herdr)
        table[500] = Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)
        let arguments: [Int32: [String]] = [700: [Self.herdr, "server"],
                                            650: ["herdr", "--session", "work"],
                                            660: ["herdr"]]
        let named = probe(table, environment: [700: ["HERDR_SESSION=work"]], arguments: arguments)
        XCTAssertEqual(SessionHost.resolve(pid: 900, named), .app(cmux))
        let unnamed = probe(table, arguments: arguments)
        XCTAssertEqual(SessionHost.resolve(pid: 900, unnamed), .app(metalterm), "the default session's client")
    }

    func testAHerdrClientsSessionIsReadFromItsArguments() {
        XCTAssertEqual(SessionHost.herdrClientSession(arguments: ["herdr"]), .some(nil))
        XCTAssertEqual(SessionHost.herdrClientSession(arguments: ["herdr", "--session", "w"]), .some("w"))
        XCTAssertEqual(SessionHost.herdrClientSession(arguments: ["herdr", "--session=w"]), .some("w"))
        XCTAssertEqual(SessionHost.herdrClientSession(arguments: ["herdr", "session", "attach", "w"]), .some("w"))
        XCTAssertNil(SessionHost.herdrClientSession(arguments: ["herdr", "pane", "list"]))
        XCTAssertNil(SessionHost.herdrClientSession(arguments: ["herdr", "server"]))
        XCTAssertNil(SessionHost.herdrClientSession(arguments: ["herdr", "--session="]))
        XCTAssertEqual(SessionHost.herdrSession(environment: ["HERDR_SESSION=w"]), "w")
        XCTAssertEqual(SessionHost.herdrSession(environment: ["HERDR_SESSION="]), "default")
        XCTAssertEqual(SessionHost.herdrSession(environment: []), "default")
    }

    /// The real reads: this process's arguments, and its pid among all.
    func testTheRealArgumentsAndProcessesIncludeThisOne() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(SessionHost.arguments(me).count, CommandLine.arguments.count)
        XCTAssertTrue(SessionHost.allPIDs().contains(me))
        XCTAssertEqual(SessionHost.arguments(Int32.max), [])
    }
}
