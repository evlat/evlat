import XCTest
@testable import EvlatApp

/// Finding a session's terminal from its pid, without a permission. The walk
/// is pure over the lookups in `SessionHost.Probe`, so every chain measured
/// on a real machine is a table here; herdr's and tmux's are in their own
/// files.
final class SessionHostTests: XCTestCase {
    /// A fake process table: pid → (parent, executable path, the app if the
    /// process is a `.regular` one).
    struct Proc {
        let parent: Int32
        let path: String?
        var app: SessionHost.App? = nil
    }

    let metalterm = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
    let code = SessionHost.App(bundleID: "com.microsoft.VSCode", name: "Code", pid: 600)
    let orca = SessionHost.App(bundleID: "com.stablyai.orca", name: "Orca", pid: 700)

    static let orcaHelper =
        "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper"

    func probe(_ table: [Int32: Proc],
                       bundles: [String: (bundleID: String, name: String)] = [:],
                       running: [String: SessionHost.App] = [:],
                       environment: [Int32: [String]] = [:],
                       arguments: [Int32: [String]] = [:],
                       sockets: [Int32: [SessionHost.UnixSocket]]? = nil,
                       terminals: [Int32: Bool] = [:],
                       started: [Int32: TimeInterval] = [:],
                       tcp: [Int32: [SessionHost.TCPSocket]] = [:],
                       ttys: [Int32: Int32] = [:],
                       masters: [Int32: [Int32]] = [:],
                       tmux: @escaping (TmuxQuery) -> TmuxReply? = { _ in nil },
                       herdr: @escaping HerdrSocket.Call = { _, _ in .unreachable }) -> SessionHost.Probe {
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
                          tmux: tmux,
                          herdr: herdr,
                          tcpSockets: { tcp[$0] ?? [] },
                          terminalDevice: { ttys[$0] },
                          ptyMasters: { masters[$0] })
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

    static let metaltermTab = "METALTERM_TAB_URL=metalterm://tab/12cc2c67c4d3a305"
    static let bateriTab = "BATERI_TAB_URL=bateri://tab/85353B2C-0564-41A3-9E4A-52DC53B00316"

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

// MARK: - Fixtures shared by the multiplexers' tables

extension SessionHostTests {
    // Bateri, as measured on this Mac (2026-10-01).
    static let bateriPath = "/Applications/bateri.app/Contents/MacOS/bateri"
    var bateri: SessionHost.App { SessionHost.App(bundleID: "dev.bateri.bateri", name: "bateri", pid: 580) }
    static let clientSocket = "/Users/u/.config/herdr/herdr-client.sock"
    static func bateriTab(_ id: String) -> [String] { ["BATERI_TAB_URL=bateri://tab/\(id)"] }
    static let closedTab = "8934C33B-1546-4850-B5B3-65153FEB1FC5"
    static let olderTab = "9F6818EC-BBCE-41B8-8818-571597ADAEE2"
    static let newerTab = "B18327D0-24AD-4D4B-AE74-8DBED7B17EEB"

    func tab(of host: SessionHost) -> String? {
        guard case .app(let app) = host else { return nil }
        return app.tab?.absoluteString
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
        XCTAssertNotNil(SessionHost.startedAt(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(SessionHost.terminalDevice(1), "launchd has no terminal")
        XCTAssertNil(SessionHost.terminalDevice(Int32.max))
    }

    /// A pty opened here: its master is among this process's, by the
    /// number its terminal's device carries.
    func testTheRealPtyMastersAreRead() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(master, 0)
        defer { close(master) }
        XCTAssertEqual(grantpt(master), 0)
        XCTAssertEqual(unlockpt(master), 0)
        let name = try XCTUnwrap(ptsname(master).map { String(cString: $0) })
        var info = stat()
        XCTAssertEqual(stat(name, &info), 0, name)
        let me = ProcessInfo.processInfo.processIdentifier
        let masters = try XCTUnwrap(SessionHost.ptyMasters(me))
        XCTAssertTrue(SessionHost.holdsMaster(of: Int32(bitPattern: UInt32(truncatingIfNeeded: info.st_rdev)),
                                              masters: masters), "\(name) in \(masters)")
        XCTAssertNil(SessionHost.ptyMasters(Int32.max))
    }

    /// One action reads a process's masters once, an unreadable one too:
    /// several candidates falling back scan the processes once.
    func testThePtyMastersAreReadOncePerAction() {
        var reads: [Int32] = []
        let masters = SessionHost.kept { pid in reads.append(pid); return pid == 1 ? nil : [pid] }
        XCTAssertEqual(masters(2), [2])
        XCTAssertNil(masters(1))
        XCTAssertEqual(masters(2), [2])
        XCTAssertNil(masters(1))
        XCTAssertEqual(reads, [2, 1])
    }
}

// MARK: - A relaunched terminal's orphaned tab

/// Bateri 0.4.0 relaunched with its tabs open (macOS 26.4.1, 2026-10-04):
/// the old tab's `login` was left to launchd, and the walk up the parents
/// reached no app. Its pty master is still held by the new `bateri` and its
/// child `bateri hold`: `/dev/ttys018` is device 16,18, the master 15,18.
extension SessionHostTests {
    static let ttys018: Int32 = 0x1000_0012
    var relaunched: SessionHost.App { SessionHost.App(bundleID: "dev.bateri.bateri", name: "bateri", pid: 16041) }

    /// `claude → -zsh → login (ttys018) → launchd`, and the relaunched
    /// Bateri, its `hold`, and another Bateri copy with a tab of its own.
    var orphanedTab: [Int32: Proc] {
        [
            39495: Proc(parent: 38874, path: "/Users/u/.local/bin/claude"),
            38874: Proc(parent: 38873, path: "/bin/zsh"),
            38873: Proc(parent: 1, path: "/usr/bin/login"),
            16041: Proc(parent: 1, path: Self.bateriPath, app: relaunched),
            16054: Proc(parent: 16041, path: Self.bateriPath),
            32994: Proc(parent: 1, path: "/Users/u/src/bateri/build/bateri.app/Contents/MacOS/bateri",
                        app: SessionHost.App(bundleID: "dev.bateri.bateri", name: "bateri", pid: 32994)),
        ]
    }

    /// The tab's processes on ttys018; the masters as `lsof /dev/ptmx` read them.
    var orphanedTTYs: [Int32: Int32] { [39495: Self.ttys018, 38874: Self.ttys018, 38873: Self.ttys018] }
    var orphanedMasters: [Int32: [Int32]] {
        [16041: [0, 37, 18, 22, 1, 10], 16054: [18, 22, 1, 10, 0, 37], 32994: [19]]
    }

    func testARelaunchedTerminalsOrphanedTabIsFoundByItsPtyMaster() {
        let probe = probe(orphanedTab, environment: [39495: Self.bateriTab(Self.newerTab)],
                          ttys: orphanedTTYs, masters: orphanedMasters)
        var expected = relaunched
        expected.tab = URL(string: "bateri://tab/\(Self.newerTab)")
        XCTAssertEqual(SessionHost.resolve(pid: 39495, probe), .app(expected),
                       "both owners reach the one Bateri; the tab is the agent's")
        XCTAssertEqual(SessionHost.resolve(pid: 39495, self.probe(orphanedTab)), .notFound,
                       "with no terminal read, the walk is today's")
    }

    /// The tab link is the agent's, as on any walk: an owner's own (the
    /// tab Bateri was started from) never stands for it.
    func testTheOwnersTabLinkIsNotTheSessions() {
        let owners: [Int32: [String]] = [16041: Self.bateriTab(Self.olderTab), 16054: Self.bateriTab(Self.olderTab)]
        var environment = owners
        environment[39495] = Self.bateriTab(Self.newerTab)
        let probe = probe(orphanedTab, environment: environment, ttys: orphanedTTYs, masters: orphanedMasters)
        XCTAssertEqual(tab(of: SessionHost.resolve(pid: 39495, probe)), "bateri://tab/\(Self.newerTab)")
        let silent = self.probe(orphanedTab, environment: owners, ttys: orphanedTTYs, masters: orphanedMasters)
        XCTAssertEqual(SessionHost.resolve(pid: 39495, silent), .app(relaunched), "no tab of the agent's, none")
    }

    /// Owners that reach two apps say nothing of which one the tab is in.
    func testOwnersInTwoAppsAreNotFound() {
        var table = orphanedTab
        table[500] = Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)
        var masters = orphanedMasters
        masters[500] = [18]
        XCTAssertEqual(SessionHost.resolve(pid: 39495, probe(table, ttys: orphanedTTYs, masters: masters)), .notFound)
    }

    /// Two copies of one bundle (an installed Bateri and a development one)
    /// are two apps: the pid is part of the answer.
    func testTwoProcessesOfOneBundleAreNotFound() {
        var masters = orphanedMasters
        masters[32994] = [19, 18]
        XCTAssertEqual(SessionHost.resolve(pid: 39495, probe(orphanedTab, ttys: orphanedTTYs, masters: masters)),
                       .notFound)
    }

    /// No controlling terminal, no master to look for: nobody is asked.
    func testAProcessWithNoTerminalAsksNoOwner() {
        var asked = 0
        var lookups = probe(orphanedTab, masters: orphanedMasters)
        lookups.processes = { asked += 1; return [16041, 16054] }
        lookups.ptyMasters = { _ in asked += 1; return [18] }
        XCTAssertEqual(SessionHost.resolve(pid: 39495, lookups), .notFound)
        XCTAssertEqual(asked, 0)
    }

    /// A process whose descriptors cannot be read is no owner, and rules
    /// nobody out: the owners read still decide.
    func testAnUnreadableProcessRulesNobodyOut() {
        var table = orphanedTab
        table[500] = Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)
        let probe = probe(table, ttys: orphanedTTYs, masters: orphanedMasters)
        XCTAssertNil(probe.ptyMasters(500))
        XCTAssertEqual(SessionHost.resolve(pid: 39495, probe), .app(relaunched))
        XCTAssertEqual(SessionHost.resolve(pid: 39495, self.probe(table, ttys: orphanedTTYs)), .notFound,
                       "no process read at all: no owner")
    }

    /// An owner's own walk does not look for owners again: a `screen`
    /// holding the master, itself on a tab Metalterm holds, is not followed
    /// on to Metalterm.
    func testAnOwnersWalkDoesNotFallBackAgain() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 1, path: "/bin/zsh"),
            700: Proc(parent: 1, path: "/usr/bin/screen"),
            500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm),
        ]
        let probe = probe(table, ttys: [900: 0x1000_0005, 800: 0x1000_0005, 700: 0x1000_0006],
                          masters: [700: [5], 500: [6]])
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe), .notFound)
    }

    /// A tty and a master share their minor number (`sys/types.h`'s
    /// `minor()`: the low 24 bits); the major differs, 16 against 15.
    func testATerminalMatchesItsMasterByNumber() {
        let rows: [(device: Int32, masters: [Int32], owns: Bool)] = [
            (Self.ttys018, [0, 37, 18], true),
            (Self.ttys018, [19], false),
            (Self.ttys018, [], false),
            (0x1000_0000, [0], true),
            (0x1000_0100, [256], true),
            (0x1000_0100, [0], false),
        ]
        for row in rows {
            XCTAssertEqual(SessionHost.holdsMaster(of: row.device, masters: row.masters), row.owns,
                           "\(String(row.device, radix: 16)) \(row.masters)")
        }
        XCTAssertEqual(SessionHost.ptyNumber(0x0F00_0012), 18, "the master 15,18")
        XCTAssertEqual(SessionHost.ptyNumber(Self.ttys018), 18)
    }

    // MARK: Chains that reach their host today

    /// A chain that reaches an app does not look for owners at all.
    func testAnAppFoundAsksNoOwner() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 500, path: "/bin/zsh"),
            500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
        var asked = 0
        var lookups = probe(table, ttys: [900: Self.ttys018, 800: Self.ttys018], masters: [580: [18]])
        lookups.processes = { asked += 1; return Array(table.keys) }
        XCTAssertEqual(SessionHost.resolve(pid: 900, lookups), .app(metalterm))
        XCTAssertEqual(asked, 0)
    }

    /// Orca's helper holds the master and names the app: unchanged
    /// (ttys012 → Orca Helper, measured), and so is the closed case.
    func testOrcasHelperIsUnchangedWithItsTerminalKnown() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 750, path: "/bin/zsh"),
            750: Proc(parent: 1, path: Self.orcaHelper),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
        let ttys: [Int32: Int32] = [900: 0x1000_000c, 800: 0x1000_000c]
        let bundles: [String: (bundleID: String, name: String)] = [
            "/Applications/Orca.app": ("com.stablyai.orca", "Orca"),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table, bundles: bundles, running: ["com.stablyai.orca": orca],
                                                           ttys: ttys, masters: [750: [12]])), .app(orca))
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table, bundles: bundles, ttys: ttys,
                                                           masters: [580: [12]])),
                       .closed(name: "Orca"), "a closed app is today's answer, not a reason to look further")
    }

    /// `screen` holds its windows' masters and reaches no app: no host, as today.
    func testScreenIsUnchangedWithItsTerminalKnown() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 1, path: "/usr/bin/screen"),
        ]
        XCTAssertEqual(SessionHost.resolve(pid: 900, probe(table, ttys: [900: 0x1000_0009], masters: [800: [9]])),
                       .notFound)
    }
}
