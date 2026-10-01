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
                       arguments: [Int32: [String]] = [:],
                       sockets: [Int32: [SessionHost.UnixSocket]]? = nil,
                       terminals: [Int32: Bool] = [:],
                       started: [Int32: TimeInterval] = [:],
                       tmux: @escaping (TmuxQuery) -> TmuxReply? = { _ in nil }) -> SessionHost.Probe {
        SessionHost.Probe(parent: { table[$0]?.parent },
                          regularApp: { table[$0]?.app },
                          executablePath: { table[$0]?.path },
                          bundle: { bundles[$0] },
                          running: { running[$0] },
                          environment: { environment[$0] ?? [] },
                          arguments: { arguments[$0] ?? [] },
                          processes: { Array(table.keys) },
                          unixSockets: { pid in sockets.map { $0[pid] ?? [] } },
                          hasTerminal: { terminals[$0] },
                          startedAt: { started[$0].map(Date.init(timeIntervalSince1970:)) },
                          tmux: tmux)
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

    // MARK: Which client (herdr 0.9.3, measured on this Mac with Bateri)

    private static let bateriPath = "/Applications/bateri.app/Contents/MacOS/bateri"
    private var bateri: SessionHost.App { SessionHost.App(bundleID: "dev.bateri.bateri", name: "bateri", pid: 580) }
    private static let clientSocket = "/Users/u/.config/herdr/herdr-client.sock"
    private static func bateriTab(_ id: String) -> [String] { ["BATERI_TAB_URL=bateri://tab/\(id)"] }
    private static let closedTab = "8934C33B-1546-4850-B5B3-65153FEB1FC5"
    private static let olderTab = "9F6818EC-BBCE-41B8-8818-571597ADAEE2"
    private static let newerTab = "B18327D0-24AD-4D4B-AE74-8DBED7B17EEB"

    /// As seen: the server is still the child of the client that started it,
    /// whose tab has closed; two live clients in two other tabs. Pids as
    /// measured — the closed tab's client holds the highest, and the newest
    /// client a lower one than the older live one would suggest.
    private var herdrInBateri: [Int32: Proc] {
        [
            92981: Proc(parent: 37882, path: "/Users/u/.local/bin/claude"),
            37882: Proc(parent: 37881, path: "/bin/zsh"),
            37881: Proc(parent: 37880, path: Self.herdr),
            37880: Proc(parent: 35046, path: Self.herdr),      // the closed tab's
            35046: Proc(parent: 35045, path: "/bin/zsh"),
            35045: Proc(parent: 580, path: "/usr/bin/login"),
            37020: Proc(parent: 36660, path: Self.herdr),      // 17:18
            36660: Proc(parent: 580, path: "/bin/zsh"),
            22670: Proc(parent: 22237, path: Self.herdr),      // 17:08
            22237: Proc(parent: 580, path: "/bin/zsh"),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
    }

    private var herdrInBateriArguments: [Int32: [String]] {
        [37881: [Self.herdr, "server"], 37880: ["herdr"], 37020: ["herdr"], 22670: ["herdr"]]
    }

    private var herdrInBateriEnvironment: [Int32: [String]] {
        [92981: Self.bateriTab(Self.closedTab) + ["HERDR_ENV=1", "HERDR_PANE_ID=w5:p1", "TERM_PROGRAM=herdr"],
         37880: Self.bateriTab(Self.closedTab),
         37020: Self.bateriTab(Self.newerTab),
         22670: Self.bateriTab(Self.olderTab)]
    }

    /// The server's accepted client sockets and each client's end, as
    /// `PROC_PIDFDSOCKETINFO` read them; the server's API socket and an
    /// internal pair are among its sockets too.
    private var herdrInBateriSockets: [Int32: [SessionHost.UnixSocket]] {
        [37881: [SessionHost.UnixSocket(pcb: 0xe3bf, peer: 0, path: "/Users/u/.config/herdr/herdr.sock"),
                 SessionHost.UnixSocket(pcb: 0x7f30, peer: 0x4052),
                 SessionHost.UnixSocket(pcb: 0x6f4b, peer: 0, path: Self.clientSocket),
                 SessionHost.UnixSocket(pcb: 0xc9fe, peer: 0x112f, path: Self.clientSocket),
                 SessionHost.UnixSocket(pcb: 0x3b46, peer: 0xd82d, path: Self.clientSocket),
                 SessionHost.UnixSocket(pcb: 0x0d63, peer: 0xc1ae, path: Self.clientSocket)],
         37880: [SessionHost.UnixSocket(pcb: 0xd82d, peer: 0x3b46)],
         37020: [SessionHost.UnixSocket(pcb: 0xc1ae, peer: 0x0d63)],
         22670: [SessionHost.UnixSocket(pcb: 0x112f, peer: 0xc9fe)]]
    }

    private func herdrInBateriProbe(table: [Int32: Proc]? = nil,
                                    sockets: [Int32: [SessionHost.UnixSocket]]? = nil,
                                    terminals: [Int32: Bool] = [37880: false, 37020: true, 22670: true],
                                    started: [Int32: TimeInterval] = [37880: 1_000, 22670: 3_100, 37020: 3_700])
        -> SessionHost.Probe {
        probe(table ?? herdrInBateri, environment: herdrInBateriEnvironment,
              arguments: herdrInBateriArguments, sockets: sockets ?? herdrInBateriSockets,
              terminals: terminals, started: started)
    }

    private func tab(of host: SessionHost) -> String? {
        guard case .app(let app) = host else { return nil }
        return app.tab?.absoluteString
    }

    /// The closed tab's client holds the highest pid and its walk still
    /// reaches Bateri; it has no terminal, so it is not taken.
    func testAClientWithNoTerminalIsNotTaken() {
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe())
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.newerTab)")
        guard case .app(let app) = host else { return XCTFail("\(host)") }
        XCTAssertEqual(app.herdr?.pane, "w5:p1")
    }

    /// Of two live clients the one started last wins, not the higher pid.
    func testTheNewestClientWinsOverTheHigherPid() {
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe(started: [37880: 1_000, 22670: 3_700,
                                                                                  37020: 3_100]))
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.olderTab)")
    }

    /// A `herdr` that is not connected to the client socket is no client,
    /// even when its arguments look like one: here the newest live one only
    /// talks to the API socket.
    func testAHerdrNotConnectedToTheClientSocketIsNotAClient() {
        var sockets = herdrInBateriSockets
        sockets[37020] = [SessionHost.UnixSocket(pcb: 0xc1ae, peer: 0xe3bf)]
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe(sockets: sockets))
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.olderTab)")
    }

    /// No live client: the walk goes on through the closed tab's client and
    /// reaches Bateri, but the pane's inherited tab is not opened and herdr
    /// is not asked for a pane.
    func testAPaneWithNoClientFoundOpensNoTab() {
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe(terminals: [37880: false, 37020: false,
                                                                                    22670: false]))
        XCTAssertEqual(host, .app(bateri), "the app only: no tab, no herdr pane")
    }

    func testAMultiplexedEnvironmentIsRecognised() {
        XCTAssertTrue(SessionHost.isMultiplexed(["HERDR_ENV=1"]))
        XCTAssertTrue(SessionHost.isMultiplexed(["TERM_PROGRAM=herdr"]))
        XCTAssertTrue(SessionHost.isMultiplexed(["TMUX=/tmp/tmux-501/default,123,0"]))
        XCTAssertFalse(SessionHost.isMultiplexed(["TMUX="]))
        XCTAssertFalse(SessionHost.isMultiplexed(["TERM_PROGRAM=bateri", "HERDR_ENV=0"]))
    }

    // MARK: tmux

    private static let tmuxPath = "/opt/homebrew/bin/tmux"
    private static let tmuxEnvironment = ["TMUX=/private/tmp/tmux-501/default,4000,0", "TMUX_PANE=%3"]

    /// claude in a tmux pane; the server is parented to launchd, two clients
    /// in two Bateri tabs and a third attached to another session.
    private var tmuxInBateri: [Int32: Proc] {
        [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 4000, path: "/bin/zsh"),
            4000: Proc(parent: 1, path: Self.tmuxPath),
            4100: Proc(parent: 4101, path: Self.tmuxPath),
            4101: Proc(parent: 580, path: "/bin/zsh"),
            4200: Proc(parent: 4201, path: Self.tmuxPath),
            4201: Proc(parent: 580, path: "/bin/zsh"),
            4300: Proc(parent: 4301, path: Self.tmuxPath),
            4301: Proc(parent: 580, path: "/bin/zsh"),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
    }

    private func tmuxProbe(_ reply: TmuxReply?, asked: ((TmuxQuery) -> Void)? = nil) -> SessionHost.Probe {
        probe(tmuxInBateri,
              environment: [900: Self.bateriTab(Self.closedTab) + Self.tmuxEnvironment,
                            4100: Self.bateriTab(Self.olderTab), 4200: Self.bateriTab(Self.newerTab),
                            4300: Self.bateriTab("C0FFEE00-0000-4000-8000-000000000000")],
              tmux: { query in asked?(query); return reply })
    }

    /// The pane's session's client that did something last; another
    /// session's, though more recent, is not it.
    func testATmuxPaneIsHostedWhereItsMostRecentClientRuns() {
        var query: TmuxQuery?
        let reply = TmuxReply(session: "$1", clients: [.init(pid: 4100, activity: 1_700, session: "$1"),
                                                        .init(pid: 4200, activity: 1_900, session: "$1"),
                                                        .init(pid: 4300, activity: 2_000, session: "$2")])
        let host = SessionHost.resolve(pid: 900, tmuxProbe(reply, asked: { query = $0 }))
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.newerTab)")
        XCTAssertEqual(query, TmuxQuery(executable: Self.tmuxPath, socket: "/private/tmp/tmux-501/default",
                                        server: 4000, pane: "%3"))
    }

    /// tmux did not answer: the server's chain reaches no app, and even one
    /// that did would not open the pane's inherited tab.
    func testATmuxPaneWithNoAnswerOpensNoTab() {
        XCTAssertEqual(SessionHost.resolve(pid: 900, tmuxProbe(nil)), .notFound)
        var table = tmuxInBateri
        table[4000] = Proc(parent: 4101, path: Self.tmuxPath)
        let host = SessionHost.resolve(pid: 900, probe(table, environment: [900: Self.bateriTab(Self.closedTab)
                                                                                + Self.tmuxEnvironment]))
        XCTAssertEqual(host, .app(bateri))
    }

    func testATmuxQueryIsCheckedBeforeItIsAsked() {
        let good = TmuxQuery.of(executable: Self.tmuxPath, environment: Self.tmuxEnvironment)
        XCTAssertEqual(good?.arguments, ["-S", "/private/tmp/tmux-501/default", "display-message", "-p", "-t",
                                         "%3", "#{session_id}", ";", "list-clients", "-F",
                                         "#{client_pid} #{client_activity} #{session_id}"])
        XCTAssertEqual(TmuxQuery.of(executable: Self.tmuxPath,
                                    environment: ["TMUX=/tmp/a,b/default,77,1", "TMUX_PANE=%0"])?.socket,
                       "/tmp/a,b/default", "a comma in the socket's path")
        for pane in ["3", "%", "%3;x", "%-1", "%3 ", "-t"] {
            XCTAssertNil(TmuxQuery.of(executable: Self.tmuxPath, environment: ["TMUX=/s,77,0", "TMUX_PANE=\(pane)"]),
                         pane)
        }
        for tmux in ["relative,77,0", "/s,x,0", "/s,1,0", "/s,77", ""] {
            XCTAssertNil(TmuxQuery.of(executable: Self.tmuxPath, environment: ["TMUX=\(tmux)", "TMUX_PANE=%1"]),
                         tmux)
        }
        XCTAssertNil(TmuxQuery.of(executable: "tmux", environment: Self.tmuxEnvironment), "a path, not a name")
    }

    func testATmuxReplyIsParsed() {
        XCTAssertEqual(TmuxReply.parse("$1\n4100 1700 $1\n4200 1900 $2\nnot a client\n"),
                       TmuxReply(session: "$1", clients: [.init(pid: 4100, activity: 1_700, session: "$1"),
                                                          .init(pid: 4200, activity: 1_900, session: "$2")]))
        XCTAssertEqual(TmuxReply.parse("$4\n")?.clients, [])
        XCTAssertNil(TmuxReply.parse(""))
        XCTAssertNil(TmuxReply.parse("no server running on /tmp/x\n"))
    }

    // MARK: The real reads

    /// A socket pair in this process: each end's peer is the other's block.
    func testTheRealUnixSocketsPairUp() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let me = ProcessInfo.processInfo.processIdentifier
        let sockets = try XCTUnwrap(SessionHost.unixSockets(me))
        let paired = sockets.filter { a in sockets.contains { $0.pcb == a.peer && $0.peer == a.pcb } }
        XCTAssertGreaterThanOrEqual(paired.count, 2)
        XCTAssertNil(SessionHost.unixSockets(Int32.max))
    }

    func testTheRealTerminalAndStartTimeAreRead() {
        XCTAssertEqual(SessionHost.hasTerminal(1), false, "launchd has no terminal")
        XCTAssertNil(SessionHost.hasTerminal(Int32.max))
        XCTAssertNotNil(AppController.processStartedAt(ProcessInfo.processInfo.processIdentifier))
    }
}
