import XCTest
@testable import EvlatCore

/// `RemoteHost`: the read-only script a server runs to say which ssh
/// connection a session is under, and what the Mac reads of its answer. The
/// script runs here under `sh`, `dash` and `bash` against a `/proc` and a
/// home made in a temporary folder, shaped as the measured server's
/// (Ubuntu, OpenSSH 9.6p1: `claude → bash → sshd: root@pts/0 → listener`).
final class RemoteHostTests: XCTestCase {
    private static let shells = ["/bin/sh", "/bin/dash", "/bin/bash"]
    private static let session = "8087b2ed-d738-42da-abf1-8693d1094eda"
    private static let records = SessionRecords(directory: ".agent/sessions", idKey: "sessionId", pidKey: "pid",
                                                  startedAtKey: "startedAt")

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-host-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - The session id

    func testOnlyAUUIDIsASessionID() {
        XCTAssertTrue(RemoteHost.isSessionID(Self.session))
        XCTAssertTrue(RemoteHost.isSessionID(Self.session.uppercased()))
        for bad in ["", "abc", Self.session + "x", "'; rm -rf ~; '", "8087b2ed d738 42da abf1 8693d1094eda",
                    "{8087b2ed-d738-42da-abf1-8693d1094eda}"] {
            XCTAssertFalse(RemoteHost.isSessionID(bad), bad)
            XCTAssertNil(RemoteHost.script(sessionID: bad, records: Self.records, nonce: "n"), bad)
        }
    }

    func testTheSessionIDComesFromItsMachinesEntity() {
        XCTAssertEqual(RemoteHost.sessionID(entity: "remote:m1:\(Self.session)", machineID: "m1"), Self.session)
        XCTAssertNil(RemoteHost.sessionID(entity: "remote:m2:\(Self.session)", machineID: "m1"))
        XCTAssertNil(RemoteHost.sessionID(entity: Self.session, machineID: "m1"), "a local row")
        XCTAssertNil(RemoteHost.sessionID(entity: "remote:m1:not-a-uuid", machineID: "m1"))
    }

    /// The id goes in as it came — the records spell it in lower case,
    /// which `UUID.uuidString` would not — and as one quoted word.
    func testTheIDIsQuotedAsItCame() throws {
        let script = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n"))
        XCTAssertTrue(script.contains("id='\(Self.session)'\n"))
    }

    // MARK: - The call

    /// Over the master or not at all: a gone master must not turn into a
    /// login, so the fallback connection is made to fail before `--`.
    func testTheCallRidesOnlyTheMaster() {
        let arguments = RemoteHost.arguments(target: "devbox", controlPath: "/tmp/e/1")
        let base = RemoteSettings.arguments(target: "devbox", controlPath: "/tmp/e/1")
        let proxy = try! XCTUnwrap(arguments.firstIndex(of: "ProxyCommand=/usr/bin/false"))
        XCTAssertEqual(arguments[proxy - 1], "-o")
        XCTAssertLessThan(proxy, try! XCTUnwrap(arguments.firstIndex(of: "--")))
        XCTAssertEqual(arguments.filter { $0 != "-o" && $0 != "ProxyCommand=/usr/bin/false" },
                       base.filter { $0 != "-o" })
        XCTAssertEqual(arguments.suffix(3), ["--", "devbox", "sh -s"])
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
    }

    // MARK: - The answer

    func testTheAnswerIsReadBehindALoginsChatter() throws {
        let output = Data("Welcome to Ubuntu\nn1 ssh 19554 22 1761253365 2946736728 1790972720.90\n".utf8)
        let reply = RemoteHost.reply(exitCode: 0, output: output, nonce: "n1",
                                     arrivedAt: Date(timeIntervalSince1970: 1790972720.60))
        guard case .connection(let connection) = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(connection.clientPort, 19554)
        XCTAssertEqual(connection.serverPort, 22)
        XCTAssertEqual(connection.startedAt.timeIntervalSince1970, 1761253365 + 29467367.28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(connection.offset), 0.30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(connection.localStart).timeIntervalSince1970,
                       1761253365 + 29467367.28 - 0.30, accuracy: 0.001)
    }

    func testAnythingElseIsNotKnown() {
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RemoteHost.reply(exitCode: 0, output: Data("n none\n".utf8), nonce: "n", arrivedAt: at),
                       .noConnection)
        for text in ["", "n\n", "x ssh 1 22 1 1 1\n", "n ssh 0 22 1 1 1\n", "n ssh 70000 22 1 1 1\n",
                     "n ssh 1 22 0 1 1\n", "n ssh a 22 1 1 1\n", "n ssh 1 22 1 -1 1\n", "n ssh 1 22 1 1\n",
                     "n nonesuch\n", "n none extra\n", "pre n ssh 1 22 1 1 1\n"] {
            XCTAssertNil(RemoteHost.reply(exitCode: 0, output: Data(text.utf8), nonce: "n", arrivedAt: at), text)
        }
        XCTAssertNil(RemoteHost.reply(exitCode: 255, output: Data("n none\n".utf8), nonce: "n", arrivedAt: at),
                     "a failed call says nothing, whatever it printed")
    }

    /// `date` without `%N` prints a letter: the start is still read, the
    /// offset is not.
    func testAClockWithoutNanosecondsGivesNoOffset() {
        let reply = RemoteHost.reply(exitCode: 0, output: Data("n ssh 1 22 100 50 1790972720.N\n".utf8), nonce: "n",
                                     arrivedAt: Date())
        guard case .connection(let connection) = reply else { return XCTFail() }
        XCTAssertNil(connection.offset)
        XCTAssertNil(connection.localStart)
        XCTAssertEqual(connection.startedAt.timeIntervalSince1970, 100.5, accuracy: 0.001)
    }

    /// A forwarded variable rides beside the connection; one whose line
    /// does not parse is left out and the connection stands.
    func testForwardedVariablesAreReadBesideTheConnection() throws {
        let at = Date(timeIntervalSince1970: 0)
        let long = String(repeating: "x", count: RemoteHost.maxForwardedValue + 1)
        let text = """
            n env LC_A_TAB a://tab/1 two words
            n env lc_bad x
            n env LC_EMPTY\u{20}
            n env LC_LONG \(long)
            n env LC_CTRL a\u{1}b
            n env LC_B 2
            n ssh 1 22 100 50 1.5

            """
        let reply = RemoteHost.reply(exitCode: 0, output: Data(text.utf8), nonce: "n", arrivedAt: at)
        guard case .connection(let connection) = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(connection.forwarded, ["LC_A_TAB=a://tab/1 two words", "LC_B=2"])
        XCTAssertEqual(RemoteHost.reply(exitCode: 0, output: Data("n env LC_A 1\nn none\n".utf8), nonce: "n",
                                        arrivedAt: at), .noConnection)
        XCTAssertNil(RemoteHost.reply(exitCode: 0, output: Data("n env LC_A 1\n".utf8), nonce: "n", arrivedAt: at),
                     "a value alone is no connection")
        XCTAssertNil(RemoteHost.reply(exitCode: 0, output: Data("n ssh 1 22 1 1 1\nn none\n".utf8), nonce: "n",
                                      arrivedAt: at), "two answers are none")
    }

    /// Only an `LC_` word reaches the script, and only so many.
    func testOnlyForwardedNamesReachTheScript() throws {
        let bad = ["LANG", "PATH", "LC_", "lc_tab", "LC_tab", "LC_A;rm -rf ~", "LC_A B", "LC_A'", "LC_$(id)",
                   "LC_" + String(repeating: "A", count: 65), "XLC_A"]
        for name in bad { XCTAssertFalse(RemoteHost.isForwardedName(name), name) }
        for name in ["LC_A", "LC_BATERI_TAB_URL", "LC_9_", "LC_" + String(repeating: "A", count: 64)] {
            XCTAssertTrue(RemoteHost.isForwardedName(name), name)
        }
        let many = (0..<20).map { "LC_N\($0)" }
        let script = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n",
                                                     forwarded: bad + many))
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("fw=") })
        XCTAssertEqual(String(line), "fw='\(many.prefix(RemoteHost.maxForwarded).joined(separator: " "))'")
        let none = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n"))
        XCTAssertTrue(none.contains("fw=''\n"))
    }

    // MARK: - The script, in three shells

    /// The measured chain: the agent under a shell under the connection's
    /// `sshd`, under the listener (parent 1).
    func testTheConnectionsPortsAndStartAreSaid() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 12345),
                         (700, "bash", 600, 12350), (800, "claude", 700, 12400)],
                 agent: 800, environment: ["TERM=xterm", "SSH_CONNECTION=31.223.75.17 19554 116.202.9.44 22"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 19554 22 1000 12345 2000.25", shell)
        }
    }

    /// From OpenSSH 9.8 the connection's process is `sshd-session`; a user
    /// other than root has a `[priv]` one under the listener first. Either
    /// way it is the one whose parent is the listener.
    func testTheListenersChildIsTheConnection() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd-session", 500, 222),
                         (650, "sshd-session", 600, 230), (700, "bash", 650, 240), (800, "claude", 700, 250)],
                 agent: 800, environment: ["SSH_CONNECTION=10.0.0.1 50000 10.0.0.2 2222"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 50000 2222 1000 222 2000.25", shell)
        }
    }

    /// A name with spaces and a parenthesis is read up to the last `)`.
    func testAProcessNameIsReadWhole() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 7),
                         (800, "my (odd) agent", 600, 9)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        XCTAssertEqual(try run("/bin/sh"), "n ssh 1 22 1000 7 2000.25")
    }

    func testNoSshdAboveIsSaidOutright() throws {
        try tree(chain: [(1, "systemd", 0, 1), (300, "login", 1, 5), (700, "bash", 300, 6), (800, "claude", 700, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n none", shell)
        }
    }

    /// `sshd -i` started by systemd for each connection: its parent is no
    /// listener, so no connection is claimed.
    func testAnSshdWithoutAListenerIsNoConnection() throws {
        try tree(chain: [(1, "systemd", 0, 1), (600, "sshd", 1, 5), (800, "claude", 600, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        XCTAssertEqual(try run("/bin/sh"), "n none")
    }

    func testNotLinuxNoRecordOrNoProcessSaysNothing() throws {
        let chain: [(Int, String, Int, Int)] = [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5),
                                                (800, "claude", 600, 7)]
        let environment = ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"]

        try tree(chain: chain, agent: 800, environment: environment, linux: false)
        XCTAssertEqual(try run("/bin/sh"), "", "no /proc/self")

        try tree(chain: chain, agent: 800, environment: environment, recordedID: UUID().uuidString.lowercased())
        XCTAssertEqual(try run("/bin/sh"), "", "another session's record")

        try tree(chain: chain, agent: 800, environment: environment, recordedPid: 999)
        XCTAssertEqual(try run("/bin/sh"), "", "a record whose process is gone")
    }

    /// A record whose pid now names a process started an hour off its own —
    /// a crash left it, the pid was reused — is not the session's; one within
    /// `Platform.sameProcess`'s 120 s is. Start ticks 12400 with `btime 1000`
    /// is 1124 s.
    func testARecycledPidIsNotTheSessionsProcess() throws {
        let chain: [(Int, String, Int, Int)] = [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5),
                                                (800, "claude", 600, 12400)]
        let environment = ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"]

        try tree(chain: chain, agent: 800, environment: environment, recordedStart: 1_124_000 + 3_600_000)
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "", "a stale record, \(shell)")
        }

        try tree(chain: chain, agent: 800, environment: environment, recordedStart: 1_124_000 + 90_000)
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 1 22 1000 5 2000.25", "within the tolerance, \(shell)")
        }
    }

    /// A stale record of the same session is passed over for the live one:
    /// a resumed session can leave two.
    func testAStaleRecordGivesWayToTheLiveOne() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5),
                         (700, "bash", 1, 9), (800, "claude", 600, 12400)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"], recordedStart: 1_124_000)
        let stale = home.appendingPathComponent(Self.records.directory).appendingPathComponent("700.json")
        try #"{"pid":700,"sessionId":"\#(Self.session)","startedAt":5000}"#
            .write(to: stale, atomically: true, encoding: .utf8)
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 1 22 1000 5 2000.25", shell)
        }
    }

    /// Nothing is written: the tree and the home are byte for byte the same
    /// after a run.
    /// The agent's forwarded values are said before its connection, in the
    /// order asked; a name it lacks is not; a long value is cut past what
    /// the Mac takes, a spaced one kept whole.
    func testTheAgentsForwardedValuesAreSaid() throws {
        let long = String(repeating: "y", count: 600)
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 12345),
                         (700, "bash", 600, 12350), (800, "claude", 700, 12400)],
                 agent: 800, environment: ["LC_TAB=t://tab/1", "LC_SPACED=a b", "LANG=C.UTF-8", "LC_LONG=\(long)",
                                           "SSH_CONNECTION=31.223.75.17 19554 116.202.9.44 22"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell, forwarded: ["LC_SPACED", "LC_ABSENT", "LC_TAB", "LC_LONG", "LANG"]), """
                n env LC_SPACED a b
                n env LC_TAB t://tab/1
                n env LC_LONG \(long.prefix(RemoteHost.maxForwardedValue + 1))
                n ssh 19554 22 1000 12345 2000.25
                """, shell)
        }
    }

    func testTheScriptWritesNothing() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5), (800, "claude", 600, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        let before = try listing()
        for shell in Self.shells { _ = try run(shell) }
        XCTAssertEqual(try listing(), before)
    }

    // MARK: - In a pane: the attached client's connection

    /// The pane's environment holds the first client's `SSH_CONNECTION`
    /// (`9999`), long gone; the connection said is the client's.
    func testTmuxSaysTheMostActiveClientOfThePanesSession() throws {
        try muxTree(tmuxOutput: "$0\n602 100 $0\n612 200 $0\n622 900 $1\n")
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 2222 22 1000 610 2000.25", shell)
        }
    }

    /// Another session's client is never taken, however active; a client
    /// without a terminal is no tab; equal activity goes to the higher pid,
    /// as on this Mac.
    func testTmuxSkipsOtherSessionsAndClientsWithoutATerminal() throws {
        try muxTree(tmuxOutput: "$0\n602 100 $0\n632 500 $0\n622 900 $1\n")
        XCTAssertEqual(try run("/bin/sh"), "n ssh 1111 22 1000 600 2000.25", "632 has no terminal")
        try muxTree(tmuxOutput: "$0\n602 300 $0\n612 300 $0\n")
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 2222 22 1000 610 2000.25", shell)
        }
    }

    /// Nobody attached is said outright, so the Mac's "the one ssh there
    /// is" never stands in for it.
    func testTmuxWithNoClientIsNoConnection() throws {
        for output in ["$0\n", "$0\n622 900 $1\n"] {
            try muxTree(tmuxOutput: output)
            for shell in Self.shells {
                XCTAssertEqual(try run(shell), "n none", "\(shell) \(output)")
            }
        }
    }

    /// Values that do not check out, a server that is not the agent's or
    /// not tmux, or tmux failing: nothing — never the pane's stale
    /// connection.
    func testTmuxThatCannotBeAskedSaysNothing() throws {
        let cases: [(String, (inout [String]) -> Void, String?)] = [
            ("relative socket", { $0[0] = "TMUX=tmp/tmux-0/default,700,0" }, nil),
            ("no server pid", { $0[0] = "TMUX=/tmp/tmux-0/default,0" }, nil),
            ("not the agent's server", { $0[0] = "TMUX=/tmp/tmux-0/default,612,0" }, nil),
            ("pane not %n", { $0[1] = "TMUX_PANE=%3;x" }, nil),
            ("no pane", { $0[1] = "OTHER=1" }, nil),
            ("tmux fails", { _ in }, "garbage"),
        ]
        for (label, change, output) in cases {
            var environment = Self.tmuxPane
            change(&environment)
            try muxTree(tmuxOutput: output ?? "$0\n612 200 $0\n", agentEnvironment: environment,
                        tmuxFails: output != nil)
            for shell in Self.shells {
                XCTAssertEqual(try run(shell), "", "\(shell) \(label)")
            }
        }
        try muxTree(tmuxOutput: "$0\n612 200 $0\n", exeName: "bash")
        XCTAssertEqual(try run("/bin/sh"), "", "the server's executable is not tmux")
    }

    /// herdr: connected to the server's `herdr-client.sock`, with a
    /// terminal, newest start. The ghost of a closed tab (no terminal) and
    /// a CLI call on the API socket are newer and not taken. `ss` prints an
    /// inode above 2^31 as negative; read back, it is the client's.
    func testHerdrSaysTheNewestConnectedClientWithATerminal() throws {
        try herdrTree()
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 2222 22 1000 610 2000.25", shell)
        }
    }

    func testHerdrWithNoClientIsNoConnection() throws {
        try herdrTree(connected: [])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n none", "\(shell) nobody connected")
        }
        try herdrTree(connected: [632])
        XCTAssertEqual(try run("/bin/sh"), "n none", "only the ghost")
    }

    /// Without `ss` the peers are unknown: nothing, not "nobody".
    func testHerdrWithoutPeersSaysNothing() throws {
        try herdrTree(ss: false)
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "", shell)
        }
        try herdrTree(serverArguments: ["herdr"])
        XCTAssertEqual(try run("/bin/sh"), "", "no `herdr server` above the agent")
    }

    /// In a pane the values are the attached client's: the pane's own are
    /// the first client's, which may be another tab.
    func testAPanesForwardedValuesAreItsClients() throws {
        try muxTree(tmuxOutput: "$0\n602 100 $0\n612 200 $0\n",
                    agentEnvironment: Self.tmuxPane + ["LC_TAB=t://tab/stale"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell, forwarded: ["LC_TAB"]), "n env LC_TAB t://tab/612\nn ssh 2222 22 1000 610 2000.25",
                           shell)
        }
        try herdrTree()
        for shell in Self.shells {
            XCTAssertEqual(try run(shell, forwarded: ["LC_TAB"]), "n env LC_TAB t://tab/612\nn ssh 2222 22 1000 610 2000.25",
                           shell)
        }
        try muxTree(tmuxOutput: "$0\n", agentEnvironment: Self.tmuxPane + ["LC_TAB=t://tab/stale"])
        XCTAssertEqual(try run("/bin/sh", forwarded: ["LC_TAB"]), "n none", "no client, no value")
    }

    func testAPaneWritesNothing() throws {
        try muxTree(tmuxOutput: "$0\n612 200 $0\n")
        var before = try listing()
        for shell in Self.shells { _ = try run(shell) }
        XCTAssertEqual(try listing(), before)
        try herdrTree()
        before = try listing()
        for shell in Self.shells { _ = try run(shell) }
        XCTAssertEqual(try listing(), before)
    }

    // MARK: - Pane trees

    private static let tmuxPane = ["TMUX=/tmp/tmux-0/default,700,0", "TMUX_PANE=%3",
                                   "SSH_CONNECTION=9.9.9.9 9999 2.2.2.2 22"]

    /// Two ssh connections, each a shell running a client: 602 (port 1111,
    /// connection started 600) and 612 (port 2222, started 610). 622 runs
    /// on the console, 632 lost its terminal. The server 700 (parent 1)
    /// runs a shell running the agent 800.
    private func clients(client: String) -> [Proc] {
        [Proc(1, "systemd", 0, 1), Proc(500, "sshd", 1, 300),
         Proc(600, "sshd", 500, 600), Proc(601, "bash", 600, 601),
         Proc(602, client, 601, 5000, environment: ["SSH_CONNECTION=1.1.1.1 1111 2.2.2.2 22"]),
         Proc(610, "sshd", 500, 610), Proc(611, "bash", 610, 611),
         Proc(612, client, 611, 6000, environment: ["SSH_CONNECTION=1.1.1.1 2222 2.2.2.2 22", "LC_TAB=t://tab/612"]),
         Proc(621, "login", 1, 620),
         Proc(622, client, 621, 7000, environment: ["TERM=linux"]),
         Proc(632, client, 1, 8000, tty: 0, environment: ["SSH_CONNECTION=1.1.1.1 3333 2.2.2.2 22"])]
    }

    private func muxTree(tmuxOutput: String, agentEnvironment: [String] = RemoteHostTests.tmuxPane,
                         tmuxFails: Bool = false, exeName: String = "tmux") throws {
        let tmux = root.appendingPathComponent("opt/\(exeName)")
        var procs = clients(client: "tmux: client")
        procs += [Proc(700, "tmux: server", 1, 100, tty: 0, exe: tmux.path), Proc(701, "bash", 700, 101),
                  Proc(800, "claude", 701, 102, environment: agentEnvironment)]
        try build(procs, agent: 800)
        // tmux is reached only through the server's `exe`: it is on no `PATH`.
        let expected = "-S /tmp/tmux-0/default display-message -p -t %3 #{session_id} ; "
            + "list-clients -F #{client_pid} #{client_activity} #{session_id}"
        try executable(tmux, """
            #!/bin/sh
            [ "$*" = '\(expected)' ] || exit 1
            printf '%s' '\(tmuxOutput)'
            exit \(tmuxFails ? 1 : 0)
            """)
    }

    private func herdrTree(connected: [Int] = [602, 612, 632], ss: Bool = true,
                           serverArguments: [String] = ["/usr/local/bin/herdr", "server"]) throws {
        // The server's ends of `herdr-client.sock`, and their peers in the
        // clients; 612's pair is above 2^31. 4010 is the API socket's
        // connection from the CLI call 642.
        let ends: [Int: (server: UInt64, client: UInt64)] = [602: (4001, 5001), 612: (4284371582, 4284213423),
                                                             632: (4003, 5003)]
        var procs = clients(client: "herdr")
        for index in procs.indices {
            if let pair = ends[procs[index].pid], connected.contains(procs[index].pid) {
                procs[index].sockets = [7, pair.client]
            }
        }
        procs += [Proc(642, "herdr", 611, 9000, sockets: [5010]),
                  Proc(700, "herdr", 1, 100, tty: 0, cmdline: serverArguments,
                       sockets: [4000, 4010] + connected.compactMap { ends[$0]?.server }),
                  Proc(701, "bash", 700, 101),
                  Proc(800, "claude", 701, 102, environment: ["HERDR_ENV=1", "HERDR_PANE_ID=w1:p2",
                                                              "HERDR_SOCKET_PATH=/root/.config/herdr/herdr.sock",
                                                              "SSH_CONNECTION=9.9.9.9 9999 2.2.2.2 22"])]
        try build(procs, agent: 800)
        let folder = "/root/.config/herdr/"
        var unix = ["Num       RefCount Protocol Flags    Type St Inode Path",
                    "ff00: 00000002 00000000 00010000 0001 01 4000 \(folder)herdr-client.sock",
                    "ff01: 00000002 00000000 00010000 0001 01 3999 \(folder)herdr.sock",
                    "ff02: 00000003 00000000 00000000 0001 03 4010 \(folder)herdr.sock",
                    "ff03: 00000003 00000000 00000000 0001 03 5010",
                    "ff04: 00000003 00000000 00000000 0001 03 9 /run/dbus/system_bus_socket"]
        var lines = ["Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process",
                     "u_str ESTAB 0 0 \(folder)herdr.sock 4010 * 5010",
                     "u_str ESTAB 0 0 * 5010 * 4010",
                     "u_str ESTAB 0 0 /run/dbus/system_bus_socket 9 * 10"]
        for pid in connected {
            let pair = try XCTUnwrap(ends[pid])
            unix.append("ff1\(pid): 00000003 00000000 00000000 0001 03 \(pair.server) \(folder)herdr-client.sock")
            unix.append("ff2\(pid): 00000003 00000000 00000000 0001 03 \(pair.client)")
            lines.append("u_str ESTAB 0 0 \(folder)herdr-client.sock \(Self.ssInode(pair.server)) * \(Self.ssInode(pair.client))")
            lines.append("u_str ESTAB 0 0 * \(Self.ssInode(pair.client)) * \(Self.ssInode(pair.server))")
        }
        try FileManager.default.createDirectory(at: proc.appendingPathComponent("net"), withIntermediateDirectories: true)
        try (unix.joined(separator: "\n") + "\n").write(to: proc.appendingPathComponent("net/unix"),
                                                        atomically: true, encoding: .utf8)
        if ss {
            try executable(bin.appendingPathComponent("ss"), """
                #!/bin/sh
                [ "$*" = '-xn' ] || exit 1
                cat <<'END'
                \(lines.joined(separator: "\n"))
                END
                """)
        }
    }

    /// How iproute2 6.1's `ss` prints an inode: as a signed 32-bit number.
    private static func ssInode(_ inode: UInt64) -> String {
        String(Int32(truncatingIfNeeded: inode))
    }

    private func executable(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Helpers

    private var proc: URL { root.appendingPathComponent("proc") }
    private var home: URL { root.appendingPathComponent("home") }
    private var bin: URL { root.appendingPathComponent("bin") }

    /// One process of a fake `/proc`: `stat` always; `environ`, `cmdline`,
    /// an `exe` link and `fd` links to sockets when given. `tty` is
    /// `stat`'s seventh field, a terminal unless 0.
    private struct Proc {
        let pid: Int
        let name: String
        let parent: Int
        let start: Int
        var tty = 34816
        var environment: [String]? = nil
        var cmdline: [String]? = nil
        var exe: String? = nil
        var sockets: [UInt64] = []

        init(_ pid: Int, _ name: String, _ parent: Int, _ start: Int, tty: Int = 34816,
             environment: [String]? = nil, cmdline: [String]? = nil, exe: String? = nil, sockets: [UInt64] = []) {
            self.pid = pid
            self.name = name
            self.parent = parent
            self.start = start
            self.tty = tty
            self.environment = environment
            self.cmdline = cmdline
            self.exe = exe
            self.sockets = sockets
        }
    }

    /// A `/proc` with `chain` (pid, name, parent, start ticks), `btime 1000`,
    /// the agent's environment, and its record under the home.
    private func tree(chain: [(pid: Int, name: String, parent: Int, start: Int)], agent: Int,
                      environment: [String], linux: Bool = true,
                      recordedID: String = RemoteHostTests.session, recordedPid: Int? = nil,
                      recordedStart: Int? = nil) throws {
        let procs = chain.map { Proc($0.pid, $0.name, $0.parent, $0.start,
                                     environment: $0.pid == agent ? environment : nil) }
        try build(procs, agent: agent, linux: linux, recordedID: recordedID, recordedPid: recordedPid,
                  recordedStart: recordedStart)
    }

    /// `procs` as a `/proc`, `btime 1000`, and the agent's record under the
    /// home. `date` is a fake on `PATH` that prints `2000.25`: this Mac's
    /// has no `%N`.
    private func build(_ procs: [Proc], agent: Int, linux: Bool = true,
                       recordedID: String = RemoteHostTests.session, recordedPid: Int? = nil,
                       recordedStart: Int? = nil) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: proc, withIntermediateDirectories: true)
        if linux { try fm.createDirectory(at: proc.appendingPathComponent("self"), withIntermediateDirectories: true) }
        try "cpu  1 2 3\nbtime 1000\nprocesses 9\n".write(to: proc.appendingPathComponent("stat"),
                                                          atomically: true, encoding: .utf8)
        for entry in procs {
            let folder = proc.appendingPathComponent(String(entry.pid))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Fields 3…: state, ppid, pgrp, session, tty, then up to 22
            // (starttime) and a few more.
            var middle = Array(repeating: "0", count: 17)
            middle[2] = String(entry.tty)
            let stat = "\(entry.pid) (\(entry.name)) S \(entry.parent) \(middle.joined(separator: " ")) \(entry.start) 4096 300 0\n"
            try stat.write(to: folder.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
            if let environment = entry.environment {
                let bytes = environment.map { $0 + "\0" }.joined()
                try bytes.write(to: folder.appendingPathComponent("environ"), atomically: true, encoding: .utf8)
            }
            if let cmdline = entry.cmdline {
                try cmdline.map { $0 + "\0" }.joined().write(to: folder.appendingPathComponent("cmdline"),
                                                             atomically: true, encoding: .utf8)
            }
            if let exe = entry.exe {
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("exe").path, withDestinationPath: exe)
            }
            if !entry.sockets.isEmpty {
                let fds = folder.appendingPathComponent("fd")
                try fm.createDirectory(at: fds, withIntermediateDirectories: true)
                for (fd, inode) in entry.sockets.enumerated() {
                    try fm.createSymbolicLink(atPath: fds.appendingPathComponent(String(fd + 3)).path,
                                              withDestinationPath: "socket:[\(inode)]")
                }
            }
        }
        let records = home.appendingPathComponent(Self.records.directory)
        try fm.createDirectory(at: records, withIntermediateDirectories: true)
        let pid = recordedPid ?? agent
        let start = recordedStart.map { #","startedAt":\#($0)"# } ?? ""
        try #"{"pid":\#(pid),"sessionId":"\#(recordedID)"\#(start),"cwd":"/root","pidDomain":"linux"}"#
            .write(to: records.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"pid":1,"sessionId":"00000000-0000-0000-0000-000000000000"}"#
            .write(to: records.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let date = bin.appendingPathComponent("date")
        try "#!/bin/sh\necho 2000.25\n".write(to: date, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: date.path)
    }

    private func run(_ shell: String, forwarded: [String] = []) throws -> String {
        let script = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n",
                                                     forwarded: forwarded, proc: proc.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-s"]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, shell)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func listing() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { files[url.path] = data } else { files[url.path] = Data() }
        }
        return files
    }
}
