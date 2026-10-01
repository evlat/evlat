import XCTest
@testable import EvlatApp

/// A herdr pane is hosted where one of its server's clients runs (`Herdr`).
extension SessionHostTests {
    static let herdr = "/Users/u/.local/bin/herdr"
    static let staleTab = ["CMUX_WORKSPACE_ID=11111111-1111-4111-8111-111111111111",
                                   "CMUX_SURFACE_ID=22222222-2222-4222-8222-222222222222"]
    static let clientTab = ["CMUX_WORKSPACE_ID=018D3A58-43C5-4E55-A360-EB03CCDED11B",
                                    "CMUX_SURFACE_ID=5B3AB033-593B-4832-8B68-87D1AFEDD607"]

    var cmux: SessionHost.App { SessionHost.App(bundleID: "com.cmuxterm.app", name: "cmux", pid: 400) }

    /// As measured with herdr 0.9.1: claude → -zsh → `herdr server`, parented
    /// to launchd, and the `herdr` client in a cmux tab elsewhere. The pane
    /// still carries the tab the server was first started from.
    var herdrInCmux: [Int32: Proc] {
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
        XCTAssertNil(HerdrPane.of(herdr: Self.herdr, environment: ["HERDR_PANE_ID=w1:p1"]),
                     "no socket: herdr's default session, whose `w1:p1` is another pane")
        XCTAssertNil(HerdrPane.of(herdr: Self.herdr, environment: []), "not in a pane")
        XCTAssertNil(HerdrPane.of(herdr: "herdr", environment: ["HERDR_PANE_ID=w1:p1"]), "a path, not a name")
        XCTAssertNil(HerdrPane.of(herdr: Self.herdr, environment: ["HERDR_SOCKET_PATH=relative",
                                                                    "HERDR_PANE_ID=w1:p1"]))
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
        XCTAssertEqual(Herdr.clientSession(arguments: ["herdr"]), .some(nil))
        XCTAssertEqual(Herdr.clientSession(arguments: ["herdr", "--session", "w"]), .some("w"))
        XCTAssertEqual(Herdr.clientSession(arguments: ["herdr", "--session=w"]), .some("w"))
        XCTAssertEqual(Herdr.clientSession(arguments: ["herdr", "session", "attach", "w"]), .some("w"))
        XCTAssertNil(Herdr.clientSession(arguments: ["herdr", "pane", "list"]))
        XCTAssertNil(Herdr.clientSession(arguments: ["herdr", "server"]))
        XCTAssertNil(Herdr.clientSession(arguments: ["herdr", "--session="]))
        XCTAssertEqual(Herdr.session(environment: ["HERDR_SESSION=w"]), "w")
        XCTAssertEqual(Herdr.session(environment: ["HERDR_SESSION="]), "default")
        XCTAssertEqual(Herdr.session(environment: []), "default")
    }

    /// The real reads: this process's arguments, and its pid among all.
    /// An empty argument is an argument: it does not end the reading.
    func testAnEmptyArgumentKeepsTheRestAndTheEnvironment() {
        var buffer: [UInt8] = [3, 0, 0, 0]
        for string in ["/bin/claude", "", "", "claude", "", "--flag", "TMUX_PANE=%1", "", "junk"] {
            buffer += Array(string.utf8) + [0]
        }
        XCTAssertEqual(SessionHost.arguments(procArgs: buffer), ["claude", "", "--flag"])
        XCTAssertEqual(SessionHost.environment(procArgs: buffer), ["TMUX_PANE=%1"])
    }

    func testTheRealArgumentsAndProcessesIncludeThisOne() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(SessionHost.arguments(me).count, CommandLine.arguments.count)
        XCTAssertTrue(SessionHost.allPIDs().contains(me))
        XCTAssertEqual(SessionHost.arguments(Int32.max), [])
    }

    // MARK: Which client (herdr 0.9.3, measured on this Mac with Bateri)

    /// As seen: the server is still the child of the client that started it,
    /// whose tab has closed; two live clients in two other tabs. Pids as
    /// measured — the closed tab's client holds the highest, and the newest
    /// client a lower one than the older live one would suggest.
    var herdrInBateri: [Int32: Proc] {
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

    var herdrInBateriArguments: [Int32: [String]] {
        [37881: [Self.herdr, "server"], 37880: ["herdr"], 37020: ["herdr"], 22670: ["herdr"]]
    }

    var herdrInBateriEnvironment: [Int32: [String]] {
        [92981: Self.bateriTab(Self.closedTab) + ["HERDR_ENV=1", "HERDR_PANE_ID=w5:p1",
                                                     "HERDR_SOCKET_PATH=/Users/u/.config/herdr/herdr.sock", "TERM_PROGRAM=herdr"],
         37880: Self.bateriTab(Self.closedTab),
         37020: Self.bateriTab(Self.newerTab),
         22670: Self.bateriTab(Self.olderTab)]
    }

    /// The server's accepted client sockets and each client's end, as
    /// `PROC_PIDFDSOCKETINFO` read them; the server's API socket and an
    /// internal pair are among its sockets too.
    var herdrInBateriSockets: [Int32: [SessionHost.UnixSocket]] {
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

    func herdrInBateriProbe(table: [Int32: Proc]? = nil,
                                    sockets: [Int32: [SessionHost.UnixSocket]]? = nil,
                                    terminals: [Int32: Bool] = [37880: false, 37020: true, 22670: true],
                                    started: [Int32: TimeInterval] = [37880: 1_000, 22670: 3_100, 37020: 3_700])
        -> SessionHost.Probe {
        probe(table ?? herdrInBateri, environment: herdrInBateriEnvironment,
              arguments: herdrInBateriArguments, sockets: sockets ?? herdrInBateriSockets,
              terminals: terminals, started: started)
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

    /// The walk decides, not the variables: an agent in a terminal that was
    /// itself started from a tmux pane inherits `TMUX` but passes no server.
    func testInheritedPaneVariablesAloneKeepTheTab() {
        let table: [Int32: Proc] = [
            900: Proc(parent: 800, path: "/Users/u/.local/bin/claude"),
            800: Proc(parent: 580, path: "/bin/zsh"),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
        let host = SessionHost.resolve(pid: 900, probe(table, environment: [900: Self.bateriTab(Self.newerTab)
                                                                                + Self.tmuxEnvironment
                                                                                + ["HERDR_ENV=1"]]))
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.newerTab)")
    }

    /// Connected to the client socket is enough: arguments herdr may add
    /// later do not hide a client.
    func testAConnectedClientIsAClientWhateverItsArguments() {
        var arguments = herdrInBateriArguments
        arguments[37020] = ["herdr", "--some-new-flag"]
        let probe = probe(herdrInBateri, environment: herdrInBateriEnvironment, arguments: arguments,
                          sockets: herdrInBateriSockets, terminals: [37880: false, 37020: true, 22670: true],
                          started: [37880: 1_000, 22670: 3_100, 37020: 3_700])
        XCTAssertEqual(tab(of: SessionHost.resolve(pid: 92981, probe)), "bateri://tab/\(Self.newerTab)")
    }

    /// A server whose sockets read but none is named `herdr-client.sock`
    /// (another version's name) rules nobody out by them.
    func testNoClientSocketByThatNameFallsBackToTheArguments() {
        let sockets: [Int32: [SessionHost.UnixSocket]] = [37881: [SessionHost.UnixSocket(pcb: 0xe3bf, peer: 0)]]
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe(sockets: sockets))
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.newerTab)")
    }
}
