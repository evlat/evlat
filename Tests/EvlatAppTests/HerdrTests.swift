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

    static let apiSocket = "/Users/u/.config/herdr/herdr.sock"

    /// The server's own API socket among its unix sockets, as
    /// `PROC_PIDFDSOCKETINFO` reads it: bound, connected to nothing.
    static let apiSockets: [Int32: [SessionHost.UnixSocket]] =
        [700: [SessionHost.UnixSocket(pcb: 0xe3bf, peer: 0, path: apiSocket)]]

    func testAHerdrPaneIsHostedWhereItsClientRuns() {
        let fake = HerdrFake(panes: [("w4:p1", 810, []), ("w4:p2", 800, [900])])
        let host = SessionHost.resolve(pid: 900, probe(herdrInCmux,
                                                       environment: [900: Self.staleTab, 650: Self.clientTab],
                                                       arguments: [700: [Self.herdr, "server"], 650: ["herdr"]],
                                                       sockets: Self.apiSockets, herdr: fake.call))
        var expected = cmux
        expected.tab = URL(string: "cmux://workspace/018D3A58-43C5-4E55-A360-EB03CCDED11B/surface/5B3AB033-593B-4832-8B68-87D1AFEDD607")
        expected.herdr = .pane(HerdrPane(socket: Self.apiSocket, pane: "w4:p2"))
        XCTAssertEqual(host, .app(expected), "the client's tab, not the one the pane inherited, and the agent's pane")
        XCTAssertEqual(fake.sockets, Set([Self.apiSocket]), "asked of the server's own socket")
    }

    /// The pane is the one whose shell is the walk's last process before the
    /// server: nothing of the agent's environment is read, so an Apple-signed
    /// `ssh` in a pane, whose environment reads empty, is found as well.
    func testAnAppleSignedSshInAPaneIsFound() {
        var table = herdrInCmux
        table[950] = Proc(parent: 800, path: "/usr/bin/ssh")
        let fake = HerdrFake(panes: [("w4:p2", 800, [950])])
        let host = SessionHost.resolve(pid: 950, probe(table, arguments: [700: [Self.herdr, "server"], 650: ["herdr"]],
                                                       sockets: Self.apiSockets, herdr: fake.call))
        guard case .app(let app) = host else { return XCTFail("\(host)") }
        XCTAssertEqual(app.herdr, .pane(HerdrPane(socket: Self.apiSocket, pane: "w4:p2")))
    }

    /// An agent started by the server itself, with no shell between: the
    /// agent is its pane's root.
    func testAnAgentThatIsItsPanesRootIsFound() {
        var table = herdrInCmux
        table[900] = Proc(parent: 700, path: "/Users/u/.local/bin/claude")
        let fake = HerdrFake(panes: [("w4:p2", 900, [900])])
        let host = SessionHost.resolve(pid: 900, probe(table, arguments: [700: [Self.herdr, "server"], 650: ["herdr"]],
                                                       sockets: Self.apiSockets, herdr: fake.call))
        guard case .app(let app) = host else { return XCTFail("\(host)") }
        XCTAssertEqual(app.herdr, .pane(HerdrPane(socket: Self.apiSocket, pane: "w4:p2")))
    }

    /// No socket named `herdr.sock` among the server's (a socket moved by
    /// `HERDR_SOCKET_PATH`, or sockets that cannot be read): herdr is not
    /// asked, and the app still comes.
    func testAServerWithNoApiSocketIsNotAsked() {
        let fake = HerdrFake(panes: [("w4:p2", 800, [])])
        let unnamed: [Int32: [SessionHost.UnixSocket]] = [700: [SessionHost.UnixSocket(pcb: 1, peer: 0,
                                                                                    path: "/tmp/custom.sock")]]
        for sockets in [nil, unnamed] {
            let host = SessionHost.resolve(pid: 900, probe(herdrInCmux, arguments: [700: [Self.herdr, "server"],
                                                                                    650: ["herdr"]],
                                                           sockets: sockets, herdr: fake.call))
            guard case .app(let app) = host else { return XCTFail("\(host)") }
            XCTAssertEqual(app.herdr, .noSocket)
        }
        XCTAssertEqual(fake.requests, [])
    }

    // MARK: Pane from process (`Herdr.pane`)

    func testAShellPidMatchWinsOverAForegroundOne() {
        let fake = HerdrFake(panes: [("w1:p1", 10, [800]), ("w1:p2", 800, [801])])
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .pane(HerdrPane(socket: "/s", pane: "w1:p2")))
    }

    func testAForegroundPidMatchIsFoundWhenNoShellIs() {
        let fake = HerdrFake(panes: [("w1:p1", 10, [11]), ("w1:p2", 20, [21, 800])])
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .pane(HerdrPane(socket: "/s", pane: "w1:p2")))
        XCTAssertEqual(fake.requests.count, 3, "every pane asked before a foreground match is taken")
        // A pane started through a wrapper: the root is neither its shell
        // nor in its foreground, the agent is.
        let wrapped = HerdrFake(panes: [("w1:p1", 10, [11]), ("w1:p2", 20, [900])])
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", wrapped.call),
                       .pane(HerdrPane(socket: "/s", pane: "w1:p2")))
    }

    func testNoPaneOfTheProcessIsNoMatch() {
        let fake = HerdrFake(panes: [("w1:p1", 10, [11]), ("w1:p2", nil, [])])
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .noMatch)
        XCTAssertEqual(HerdrFake(panes: []).call("/s", HerdrAPI.listPanes), .line(#"{"id":"evlat","result":{"type":"pane_list","panes":[]}}"#))
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", HerdrFake(panes: []).call), .noMatch)
    }

    /// Past the deadline the transport answers `timeout` and nothing more is
    /// asked: the walk does not go on through the panes left.
    func testATimeoutStopsTheRemainingRequests() {
        let fake = HerdrFake(panes: [("w1:p1", 10, []), ("w1:p2", 20, []), ("w1:p3", 800, [])])
        fake.answered = 2
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .timeout)
        XCTAssertEqual(fake.requests, [HerdrAPI.listPanes, HerdrAPI.processInfo(pane: "w1:p1"),
                                       HerdrAPI.processInfo(pane: "w1:p2")])
        let silent = HerdrFake(panes: [("w1:p1", 800, [])])
        silent.answered = 0
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", silent.call), .timeout)
        XCTAssertEqual(silent.requests.count, 1)
    }

    /// A pane closed between the list and its question, or refused for any
    /// reason of its own, is skipped.
    func testAPaneClosedMeanwhileIsSkipped() {
        for code in ["pane_not_found", "something_new"] {
            let fake = HerdrFake(panes: [("w1:p1", 10, []), ("w1:p2", 800, [])])
            fake.overrides[HerdrAPI.processInfo(pane: "w1:p1")] = #"{"id":"evlat","error":{"code":"\#(code)","message":"x"}}"#
            XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call),
                           .pane(HerdrPane(socket: "/s", pane: "w1:p2")), code)
        }
    }

    /// A server that does not know the method (`pane.process_info` came in
    /// herdr 0.7.0), or answers in a shape not measured, is `unsupported`.
    func testAMethodTheServerDoesNotKnowIsUnsupported() {
        let unknown = #"{"id":"evlat","error":{"code":"invalid_request","message":"invalid request: unknown variant `pane.process_info`, expected one of `ping`"}}"#
        let fake = HerdrFake(panes: [("w1:p1", 800, [])])
        fake.overrides[HerdrAPI.processInfo(pane: "w1:p1")] = unknown
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .unsupported)
        let list = HerdrFake(panes: [])
        list.overrides[HerdrAPI.listPanes] = unknown
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", list.call), .unsupported)
        let garbled = HerdrFake(panes: [])
        garbled.overrides[HerdrAPI.listPanes] = #"{"id":"evlat","result":{"type":"pong"}}"#
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", garbled.call), .unsupported)
        let refused = HerdrFake(panes: [])
        refused.unreachable = true
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", refused.call), .noSocket, "nobody at the socket")
    }

    /// A pane id from the reply goes into the next request's JSON only once
    /// checked: one that is not an id is never asked about.
    func testAPaneIdThatIsNotOneIsNotAsked() {
        let fake = HerdrFake(panes: [(#"w1"p1"#, 800, []), ("w1:p2", 800, [])])
        XCTAssertEqual(Herdr.pane(root: 800, agent: 900, socket: "/s", fake.call), .pane(HerdrPane(socket: "/s", pane: "w1:p2")))
        XCTAssertFalse(fake.requests.contains { $0.contains(#"w1"p1"#) })
        for bad in ["", "-w1", "w1 p1", "w1;rm", "w1/p1", #"w1"p1"#, #"w1\p1"#, String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrPane.isPaneID(bad), bad)
        }
        XCTAssertTrue(HerdrPane.isPaneID("w12:p3"))
    }

    // MARK: The protocol (herdr 0.9.3, protocol 22)

    /// The three requests, byte for byte: one JSON line each, one per
    /// connection. The transport adds the newline.
    func testTheRequestsAreUnchanged() {
        XCTAssertEqual(HerdrAPI.listPanes, #"{"id":"evlat","method":"pane.list","params":{}}"#)
        XCTAssertEqual(HerdrAPI.processInfo(pane: "w5:p1"),
                       #"{"id":"evlat","method":"pane.process_info","params":{"pane_id":"w5:p1"}}"#)
        XCTAssertEqual(HerdrAPI.focus(pane: "w5:p1"), #"{"id":"evlat","method":"pane.focus","params":{"pane_id":"w5:p1"}}"#)
    }

    func testAnErrorReplyIsReadByItsCode() {
        for code in ["pane_not_found", "agent_not_found", "invalid_request"] {
            let line = #"{"id":"evlat","error":{"code":"\#(code)","message":"x"}}"#
            guard case .error(let read) = HerdrAPI.reply(line) else { return XCTFail(line) }
            XCTAssertEqual(read, code)
        }
        for line in ["", "not json", #"{"id":"evlat"}"#, #"{"id":"evlat","result":{}}"#, "[1]"] {
            guard case .unreadable = HerdrAPI.reply(line) else { return XCTFail(line) }
        }
    }

    /// Real 0.9.3 replies, the home folder renamed: every field Evlat does not
    /// read is left alone.
    func testARealReplyIsReadWhateverItsOtherFields() throws {
        let list = #"{"id":"evlat","result":{"type":"pane_list","panes":[{"pane_id":"w5:p1","terminal_id":"term_65cc773ff4b721","workspace_id":"w5","tab_id":"w5:t1","focused":true,"cwd":"/Users/u","foreground_cwd":"/Users/u","agent":"claude","terminal_title":"✳ Claude Code","terminal_title_stripped":"Claude Code","agent_status":"idle","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"683fc09d-aaf4-4567-9e2e-05cf5fcee97b"},"scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":54},"revision":9},{"pane_id":"w5:p4","terminal_id":"term_65cc818b3ad254","workspace_id":"w5","tab_id":"w5:t4","focused":false,"cwd":"/Users/u","foreground_cwd":"/Users/u","terminal_title":"u@MacBookPro:~","terminal_title_stripped":"u@MacBookPro:~","agent_status":"unknown","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":54},"revision":5}]}}"#
        let info = #"{"id":"evlat","result":{"type":"pane_process_info","process_info":{"pane_id":"w5:p1","shell_pid":37882,"foreground_process_group_id":36114,"foreground_processes":[{"pid":36255,"name":"node","argv0":"node","argv":["node","/Users/u/.npm/_npx/4b4c857f6efdfb61/node_modules/.bin/desktop-commander"],"cmdline":"node /Users/u/.npm/_npx/4b4c857f6efdfb61/node_modules/.bin/desktop-commander","cwd":"/Users/u"},{"pid":36152,"name":"node","argv0":"desktop-commander@latest","cwd":"/Users/u"},{"pid":36114,"name":"2.1.286","argv0":"claude","argv":["claude"],"cmdline":"claude","cwd":"/Users/u"}],"tty":null}}}"#
        XCTAssertEqual(HerdrAPI.paneIDs(HerdrAPI.reply(list)), ["w5:p1", "w5:p4"])
        let pids = try XCTUnwrap(HerdrAPI.processIDs(HerdrAPI.reply(info)))
        XCTAssertEqual(pids.shell, 37882)
        XCTAssertEqual(pids.foreground, [36255, 36152, 36114])
        XCTAssertNil(HerdrAPI.paneIDs(HerdrAPI.reply(info)), "another reply's type is not a list")
        XCTAssertNil(HerdrAPI.processIDs(HerdrAPI.reply(list)))
    }

    // MARK: Selecting the pane

    func testFocusAsksForThePaneAndReadsItsAnswer() {
        let fake = HerdrFake(panes: [("w5:p1", 1, [])])
        XCTAssertTrue(HerdrPane(socket: "/s", pane: "w5:p1", call: fake.call).focus())
        XCTAssertEqual(fake.requests, [HerdrAPI.focus(pane: "w5:p1")])
        XCTAssertFalse(HerdrPane(socket: "/s", pane: "w9:p9", call: fake.call).focus(), "pane_not_found")
        let late = HerdrFake(panes: [("w5:p1", 1, [])])
        late.answered = 0
        XCTAssertFalse(HerdrPane(socket: "/s", pane: "w5:p1", call: late.call).focus())
    }

    /// The pane found by a resolve is selected through the same call, and so
    /// under the same deadline: the click's.
    func testThePaneFoundKeepsItsResolvesCall() {
        let fake = HerdrFake(panes: [("w4:p2", 800, [])])
        let host = SessionHost.resolve(pid: 900, probe(herdrInCmux, arguments: [700: [Self.herdr, "server"],
                                                                                650: ["herdr"]],
                                                       sockets: Self.apiSockets, herdr: fake.call))
        guard case .app(let app) = host, case .pane(let pane) = app.herdr else { return XCTFail("\(host)") }
        XCTAssertTrue(pane.focus())
        XCTAssertEqual(fake.requests.last, HerdrAPI.focus(pane: "w4:p2"))
    }

    /// The pane first, then the window; a pane that cannot be selected still
    /// brings the app forward.
    func testActivateSelectsThePaneBeforeBringingTheAppForward() {
        var app = cmux
        app.herdr = .pane(HerdrPane(socket: "/s", pane: "w4:p2"))
        for focused in [true, false] {
            var order: [String] = []
            let done = SessionHost.activate(app, focus: { order.append("focus \($0.pane)"); return focused },
                                            bringForward: { order.append("forward \($0.name)"); return true })
            XCTAssertTrue(done)
            XCTAssertEqual(order, ["focus w4:p2", "forward cmux"])
        }
        var order: [String] = []
        app.herdr = .timeout
        XCTAssertTrue(SessionHost.activate(app, focus: { _ in order.append("focus"); return true },
                                           bringForward: { _ in order.append("forward"); return true }))
        XCTAssertEqual(order, ["forward"], "no pane, nothing to select")
    }

    /// `--list` says what herdr answered; the pane id is no secret, the pid
    /// stays out.
    func testTheListSaysWhatHerdrAnswered() {
        var app = cmux
        XCTAssertEqual(SessionHost.app(app).diagnostic, "cmux (com.cmuxterm.app)")
        let words: [(HerdrLookup, String)] = [(.pane(HerdrPane(socket: "/s", pane: "w4:p2")), "herdr pane w4:p2"),
                                              (.noSocket, "herdr: no socket"), (.timeout, "herdr: timeout"),
                                              (.unsupported, "herdr: unsupported"), (.noMatch, "herdr: no pane")]
        for (lookup, word) in words {
            app.herdr = lookup
            XCTAssertEqual(SessionHost.app(app).diagnostic, "cmux (com.cmuxterm.app)  ·  \(word)")
        }
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
        // The server's sockets are not read here: herdr is not asked.
        var (inCmux, inMetalterm) = (cmux, metalterm)
        (inCmux.herdr, inMetalterm.herdr) = (.noSocket, .noSocket)
        let named = probe(table, environment: [700: ["HERDR_SESSION=work"]], arguments: arguments)
        XCTAssertEqual(SessionHost.resolve(pid: 900, named), .app(inCmux))
        let unnamed = probe(table, arguments: arguments)
        XCTAssertEqual(SessionHost.resolve(pid: 900, unnamed), .app(inMetalterm), "the default session's client")
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
              terminals: terminals, started: started,
              herdr: HerdrFake(panes: [("w5:p4", 37225, [37225]), ("w5:p1", 37882, [36114])]).call)
    }

    /// The closed tab's client holds the highest pid and its walk still
    /// reaches Bateri; it has no terminal, so it is not taken.
    func testAClientWithNoTerminalIsNotTaken() {
        let host = SessionHost.resolve(pid: 92981, herdrInBateriProbe())
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.newerTab)")
        guard case .app(let app) = host else { return XCTFail("\(host)") }
        XCTAssertEqual(app.herdr, .pane(HerdrPane(socket: "/Users/u/.config/herdr/herdr.sock", pane: "w5:p1")),
                       "the pane whose shell is the agent's parent")
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

/// A herdr server's API as `Herdr.pane` sees it: one request line in, one
/// reply line out, shaped as herdr 0.9.3 answers (only the fields read).
final class HerdrFake {
    typealias Pane = (id: String, shell: Int32?, foreground: [Int32])
    let panes: [Pane]
    private(set) var requests: [String] = []
    private(set) var sockets: Set<String> = []
    /// How many requests are answered before the deadline; the rest time out.
    var answered = Int.max
    /// A reply that stands for the one built, by request line.
    var overrides: [String: String] = [:]
    /// Nobody listens at the socket.
    var unreachable = false

    init(panes: [Pane]) { self.panes = panes }

    func call(_ socket: String, _ request: String) -> HerdrSocket.Outcome {
        requests.append(request)
        sockets.insert(socket)
        if unreachable { return .unreachable }
        guard requests.count <= answered else { return .timeout }
        if let reply = overrides[request] { return .line(reply) }
        let object = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any]
        let method = object?["method"] as? String
        let id = (object?["params"] as? [String: Any])?["pane_id"] as? String
        let notFound = #"{"id":"evlat","error":{"code":"pane_not_found","message":"pane not found"}}"#
        switch method {
        case "pane.list":
            let list = panes.map { #"{"pane_id":\#(Self.string($0.id)),"focused":false,"revision":1}"# }
            return .line(#"{"id":"evlat","result":{"type":"pane_list","panes":[\#(list.joined(separator: ","))]}}"#)
        case "pane.process_info":
            guard let pane = panes.first(where: { $0.id == id }) else { return .line(notFound) }
            let shell = pane.shell.map(String.init) ?? "null"
            let foreground = pane.foreground.map { #"{"pid":\#($0),"name":"x"}"# }.joined(separator: ",")
            return .line(#"{"id":"evlat","result":{"type":"pane_process_info","process_info":{"pane_id":\#(Self.string(pane.id)),"shell_pid":\#(shell),"foreground_processes":[\#(foreground)],"tty":null}}}"#)
        case "pane.focus":
            guard let pane = panes.first(where: { $0.id == id }) else { return .line(notFound) }
            return .line(#"{"id":"evlat","result":{"type":"pane_info","pane":{"pane_id":\#(Self.string(pane.id)),"focused":true}}}"#)
        default:
            return .line(#"{"id":"evlat","error":{"code":"invalid_request","message":"unknown variant"}}"#)
        }
    }

    private static func string(_ value: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data(),
               as: UTF8.self)
    }
}
