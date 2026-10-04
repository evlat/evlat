import XCTest
import EvlatCore
@testable import EvlatApp

/// A remote session's terminal on this Mac (`Ssh`): the user's `ssh` to the
/// same end as Evlat's tunnel, picked by port, by being alone, or by start.
/// The table is the one measured (2026-10-02): the tunnel at
/// `192.168.1.217:60070 → 116.202.9.44:22`, a Bateri tab's `ssh` at `:63114`,
/// and a home NAT that showed the server ports 19656 and 19554.
extension SessionHostTests {
    static let sshPath = "/usr/bin/ssh"
    static let evlat: Int32 = 50
    static let tunnel: Int32 = 51
    static let server = SessionHost.Endpoint(address: "116.202.9.44", port: 22)
    static let tabStart: TimeInterval = 1_790_972_720.543

    static func socket(_ port: Int, to end: SessionHost.Endpoint = server) -> [SessionHost.TCPSocket] {
        [SessionHost.TCPSocket(local: SessionHost.Endpoint(address: "192.168.1.217", port: port), remote: end)]
    }

    /// Evlat, its tunnel and an installer call; a Bateri tab's `ssh`; an
    /// `ssh` to another server.
    var sshInBateri: [Int32: Proc] {
        [
            50: Proc(parent: 1, path: "/Applications/Evlat.app/Contents/MacOS/Evlat"),
            51: Proc(parent: 50, path: Self.sshPath),
            52: Proc(parent: 50, path: Self.sshPath),
            1001: Proc(parent: 1000, path: Self.sshPath),
            1000: Proc(parent: 580, path: "/bin/zsh"),
            1201: Proc(parent: 1200, path: Self.sshPath),
            1200: Proc(parent: 580, path: "/bin/zsh"),
            580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
        ]
    }

    var sshSockets: [Int32: [SessionHost.TCPSocket]] {
        [51: Self.socket(60070), 52: Self.socket(60111), 1001: Self.socket(63114),
         1201: Self.socket(50000, to: SessionHost.Endpoint(address: "10.0.0.5", port: 22))]
    }

    func connection(port: Int = 19554, start: TimeInterval = SessionHostTests.tabStart + 0.11,
                    offset: TimeInterval? = 0.24, forwarded: [String] = [],
                    herdrPane: RemoteHost.Pane? = nil) -> RemoteHost.Reply {
        // The server's clock runs `offset` ahead: its start reads that much later.
        .connection(RemoteHost.Connection(clientPort: port, serverPort: 22,
                                          startedAt: Date(timeIntervalSince1970: start + (offset ?? 0)),
                                          offset: offset, forwarded: forwarded, herdrPane: herdrPane))
    }

    /// The server's herdr pane is the session's, whichever `ssh` here was
    /// picked: it rides to the app, ambiguous picks in one app included.
    func testTheServersHerdrPaneReachesTheApp() throws {
        for pane in [RemoteHost.Pane.selectable, .unselectable] {
            guard case .app(let one) = remote(connection(herdrPane: pane)) else { return XCTFail("\(pane)") }
            XCTAssertEqual(one.serverPane, pane)
            let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
            guard case .app(let either) = remote(connection(herdrPane: pane), table: twoTabs, sockets: twoTabSockets,
                                                 started: started) else { return XCTFail("\(pane)") }
            XCTAssertNil(either.tab, "ambiguous")
            XCTAssertEqual(either.serverPane, pane)
        }
        guard case .app(let plain) = remote(connection()) else { return XCTFail() }
        XCTAssertNil(plain.serverPane)
    }

    func remote(_ reply: RemoteHost.Reply, table: [Int32: Proc]? = nil,
                sockets: [Int32: [SessionHost.TCPSocket]]? = nil, started: [Int32: TimeInterval] = [:],
                environment: [Int32: [String]]? = nil, running: [String: SessionHost.App] = [:],
                tunnel: Int32? = SessionHostTests.tunnel) -> SessionHost {
        SessionHost.resolve(remote: reply, tunnel: tunnel, evlat: Self.evlat,
                            probe(table ?? sshInBateri, running: running,
                                  environment: environment ?? [1001: Self.bateriTab(Self.olderTab),
                                                               1101: Self.bateriTab(Self.newerTab)],
                                  started: started, tcp: sockets ?? sshSockets))
    }

    // MARK: - Candidates

    /// Only the user's `ssh` to the tunnel's end: not Evlat's own calls, not
    /// an `ssh` elsewhere.
    func testTheCandidatesAreTheUsersSshToTheTunnelsEnd() {
        let candidates = Ssh.candidates(tunnel: Self.tunnel, evlat: Self.evlat,
                                        probe(sshInBateri, tcp: sshSockets))
        XCTAssertEqual(candidates, [Ssh.Candidate(pid: 1001, localPorts: [63114])])
    }

    /// Behind a NAT no port matches; the one candidate is the one.
    func testANattedConnectionWithOneCandidateIsThatTab() {
        XCTAssertEqual(tab(of: remote(connection(port: 19554, start: 0))), "bateri://tab/\(Self.olderTab)")
    }

    /// The tab's `ssh` in a tab Bateri's relaunch orphaned: its `login` is
    /// launchd's, and the master of its terminal is the relaunched Bateri's.
    func testAnSshInAnOrphanedTabIsFoundByItsPtyMaster() {
        var table = sshInBateri
        table[1000] = Proc(parent: 999, path: "/bin/zsh")
        table[999] = Proc(parent: 1, path: "/usr/bin/login")
        let tty: Int32 = 0x1000_0012
        let probe = probe(table, environment: [1001: Self.bateriTab(Self.olderTab)], tcp: sshSockets,
                          ttys: [1001: tty, 1000: tty, 999: tty], masters: [580: [0, 18, 22]])
        let host = SessionHost.resolve(remote: connection(port: 19554, start: 0), tunnel: Self.tunnel,
                                       evlat: Self.evlat, probe)
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.olderTab)")
        XCTAssertEqual(SessionHost.resolve(remote: connection(port: 19554, start: 0), tunnel: Self.tunnel,
                                           evlat: Self.evlat, self.probe(table, tcp: sshSockets)),
                       .notFound, "no terminal read: today's walk")
    }

    /// Two tabs to the same server.
    var twoTabs: [Int32: Proc] {
        var table = sshInBateri
        table[1101] = Proc(parent: 1100, path: Self.sshPath)
        table[1100] = Proc(parent: 580, path: "/bin/zsh")
        return table
    }

    var twoTabSockets: [Int32: [SessionHost.TCPSocket]] {
        var sockets = sshSockets
        sockets[1101] = Self.socket(63200)
        return sockets
    }

    /// Without a NAT the client port is the Mac's own: it decides alone.
    func testAnExactPortDecides() {
        XCTAssertEqual(tab(of: remote(connection(port: 63200, start: 0), table: twoTabs, sockets: twoTabSockets)),
                       "bateri://tab/\(Self.newerTab)")
    }

    /// Two tabs behind a NAT: the one that started with the connection.
    func testTheStartTellsTwoTabsApart() {
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart - 3_600]
        XCTAssertEqual(tab(of: remote(connection(), table: twoTabs, sockets: twoTabSockets, started: started)),
                       "bateri://tab/\(Self.olderTab)")
        XCTAssertEqual(tab(of: remote(connection(start: Self.tabStart - 3_600 - 0.19), table: twoTabs,
                                      sockets: twoTabSockets, started: started)),
                       "bateri://tab/\(Self.newerTab)")
    }

    /// Two tabs started within seconds, both in Bateri: Bateri comes
    /// forward, no tab is guessed.
    func testTwoCloseStartsInOneAppBringTheAppOnly() {
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
        XCTAssertEqual(remote(connection(), table: twoTabs, sockets: twoTabSockets, started: started), .app(bateri))
    }

    /// The same in two different apps: no button.
    func testTwoCloseStartsInTwoAppsFindNothing() {
        var table = twoTabs
        table[1100] = Proc(parent: 500, path: "/bin/zsh")
        table[500] = Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
        XCTAssertEqual(remote(connection(), table: table, sockets: twoTabSockets, started: started), .notFound)
    }

    /// Nearest, but past the threshold; or a start that cannot be read; or no
    /// clock: none is picked.
    func testAStartIsTrustedOnlyWithinItsThresholds() {
        var started: [Int32: TimeInterval] = [1001: Self.tabStart + 3, 1101: Self.tabStart + 3_600]
        XCTAssertEqual(remote(connection(), table: twoTabs, sockets: twoTabSockets, started: started), .app(bateri))
        started = [1001: Self.tabStart]
        XCTAssertEqual(remote(connection(), table: twoTabs, sockets: twoTabSockets, started: started), .app(bateri))
        started = [1001: Self.tabStart, 1101: Self.tabStart + 3_600]
        XCTAssertEqual(remote(connection(offset: nil), table: twoTabs, sockets: twoTabSockets, started: started),
                       .app(bateri))
        XCTAssertEqual(Ssh.choose([.init(pid: 1, localPorts: [1]), .init(pid: 2, localPorts: [2])],
                                  for: RemoteHost.Connection(clientPort: 9, serverPort: 22,
                                                             startedAt: Date(timeIntervalSince1970: 100), offset: 0),
                                  startedAt: { Date(timeIntervalSince1970: $0 == 1 ? 102 : 110.5) }),
                       .one(1), "2 s and 10.5 s: just inside both")
    }

    /// One candidate whose start is far from the connection's is another
    /// connection — the session was started from another computer.
    func testALoneCandidateThatStartedElsewhereIsNotIt() {
        XCTAssertEqual(remote(connection(), started: [1001: Self.tabStart - 3_600]), .notFound)
        XCTAssertEqual(tab(of: remote(connection(), started: [1001: Self.tabStart])),
                       "bateri://tab/\(Self.olderTab)")
    }

    /// The user's own `ControlMaster`: a second tab rides the first's
    /// connection on a unix socket, and the server sees one connection for
    /// both. The app comes forward, no tab is guessed.
    func testAMasterWithRidersBringsTheAppOnly() {
        var table = sshInBateri
        table[1101] = Proc(parent: 1100, path: Self.sshPath)
        table[1100] = Proc(parent: 580, path: "/bin/zsh")
        let host = SessionHost.resolve(remote: connection(), tunnel: Self.tunnel, evlat: Self.evlat,
                                       probe(table, environment: [1001: Self.bateriTab(Self.olderTab)],
                                             sockets: [1001: [.init(pcb: 0xA1, peer: 0)],
                                                       1101: [.init(pcb: 0xB1, peer: 0xA1)]],
                                             tcp: sshSockets))
        XCTAssertEqual(host, .app(bateri))
        XCTAssertEqual(Ssh.muxClients(of: 1001, probe(table, sockets: [1001: [.init(pcb: 0xA1, peer: 0)]])), [],
                       "a master alone is a tab like any other")
    }

    /// Through a jump host the socket is a child `ssh -W`'s, on both sides;
    /// the walk goes up from it to the tab.
    func testAJumpHostsSocketIsFollowedUp() {
        let jump = SessionHost.Endpoint(address: "9.9.9.9", port: 22)
        var table = sshInBateri
        table[53] = Proc(parent: 51, path: Self.sshPath)
        table[1002] = Proc(parent: 1001, path: Self.sshPath)
        let sockets: [Int32: [SessionHost.TCPSocket]] = [53: Self.socket(40000, to: jump),
                                                         1002: Self.socket(40001, to: jump)]
        let host = remote(connection(), table: table, sockets: sockets,
                          environment: [1002: Self.bateriTab(Self.olderTab)])
        XCTAssertEqual(tab(of: host), "bateri://tab/\(Self.olderTab)")
    }

    /// No tunnel, a tunnel with no socket, or a session under no ssh: no
    /// candidate, no button.
    func testNothingToMatchFindsNothing() {
        XCTAssertEqual(remote(connection(), tunnel: nil), .notFound)
        var sockets = sshSockets
        sockets[51] = []
        XCTAssertEqual(remote(connection(), sockets: sockets), .notFound)
        XCTAssertEqual(remote(.noConnection), .notFound)
    }

    // MARK: - A tab link forwarded over ssh

    static func forwardedTab(_ id: String) -> String { "LC_BATERI_TAB_URL=bateri://tab/\(id)" }

    /// The table names who forwards what; the core checks only the shape of
    /// a name, so every name in the table must pass it, and each entry's
    /// names stand for its variables one for one.
    func testTheForwardedNamesAreTheTablesAndPassTheCore() {
        XCTAssertEqual(TabLink.forwardedNames, ["LC_BATERI_TAB_URL"])
        for (bundleID, entry) in TabLink.known {
            XCTAssertTrue(entry.forwarded.isEmpty || entry.forwarded.count == entry.variables.count, bundleID)
            for name in entry.forwarded { XCTAssertTrue(RemoteHost.isForwardedName(name), "\(bundleID) \(name)") }
        }
        XCTAssertLessThanOrEqual(TabLink.forwardedNames.count, RemoteHost.maxForwarded)
    }

    /// The forwarded value is checked by the same rule, under its own name.
    func testAForwardedValueIsCheckedByItsTerminalsRule() {
        XCTAssertEqual(TabLink.url(bundleID: "dev.bateri.bateri", environment: [Self.forwardedTab(Self.olderTab)],
                                   forwarded: true)?.absoluteString, "bateri://tab/\(Self.olderTab)")
        XCTAssertNil(TabLink.url(bundleID: "dev.bateri.bateri", environment: Self.bateriTab(Self.olderTab),
                                 forwarded: true), "the local name is not the forwarded one")
        XCTAssertNil(TabLink.url(bundleID: "dev.bateri.bateri", environment: ["LC_BATERI_TAB_URL=bateri://tab/x/../y"],
                                 forwarded: true))
        XCTAssertNil(TabLink.url(bundleID: "dev.metalterm.Metalterm", environment: [Self.forwardedTab(Self.olderTab)],
                                 forwarded: true), "an app that forwards nothing")
    }

    /// On this Mac a tab's `ssh` is Apple's, whose environment cannot be
    /// read: the forwarded value fills the tab the walk could not — when
    /// one candidate is picked, and when two too close to tell apart are in
    /// one app and give the same.
    func testAForwardedTabFillsTheWalkedAppsTab() {
        let reply = connection(forwarded: ["LC_OTHER=1", Self.forwardedTab(Self.newerTab)])
        XCTAssertEqual(tab(of: remote(reply, environment: [:])), "bateri://tab/\(Self.newerTab)", "one candidate")
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
        XCTAssertEqual(tab(of: remote(reply, table: twoTabs, sockets: twoTabSockets, started: started,
                                      environment: [:])), "bateri://tab/\(Self.newerTab)", "two close ones")
        XCTAssertEqual(remote(reply, tunnel: nil), .notFound, "no candidate: the value alone picks nothing")
    }

    /// The walk's own tab stands: through a local multiplexer it is the
    /// client's, and the forwarded value is the server's start environment.
    func testTheWalksOwnTabBeatsTheForwardedOne() {
        let reply = connection(forwarded: [Self.forwardedTab(Self.newerTab)])
        XCTAssertEqual(tab(of: remote(reply)), "bateri://tab/\(Self.olderTab)")
    }

    /// Anything started from a Bateri tab inherits its value: an `ssh` in
    /// another app opens that app, never Bateri's tab.
    func testAForwardedValueNeverChoosesTheApp() {
        var table = sshInBateri
        table[1000] = Proc(parent: 500, path: "/bin/zsh")
        table[500] = Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)
        let host = remote(connection(forwarded: [Self.forwardedTab(Self.newerTab)]), table: table, environment: [:],
                          running: ["dev.bateri.bateri": bateri])
        XCTAssertEqual(host, .app(metalterm))
    }

    /// A value that is not a tab, or none at all: today's order.
    func testABadForwardedValueLeavesTodaysOrder() {
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
        let running = ["dev.bateri.bateri": bateri]
        for value in ["LC_BATERI_TAB_URL=bateri://tab/restart", "LC_BATERI_TAB_URL=metalterm://tab/1",
                      "LC_OTHER=bateri://tab/\(Self.newerTab)"] {
            XCTAssertEqual(remote(connection(forwarded: [value]), table: twoTabs, sockets: twoTabSockets,
                                  started: started, running: running), .app(bateri), value)
        }
        XCTAssertEqual(tab(of: remote(connection(port: 63200, start: 0, forwarded: ["LC_BATERI_TAB_URL=x"]),
                                      table: twoTabs, sockets: twoTabSockets, running: running)),
                       "bateri://tab/\(Self.newerTab)", "the port still decides")
        XCTAssertEqual(remote(.noConnection, running: running), .notFound)
    }

    // MARK: - herdr --remote

    /// The chain measured (2026-10-04, herdr 0.9.3, a Bateri tab running
    /// `herdr --remote ssh://dev@127.0.0.1:2222` to a Docker server): herdr's
    /// first `ssh` detached into a `ControlPersist` master parented to
    /// launchd, which holds the connection; the bridge's `ssh` rides it from
    /// under `herdr --remote`, whose environment names the tab. The server's
    /// `sshd` started 0.85 s after the master, and Docker's NAT showed the
    /// client port 48638.
    static let remoteTab = "DF7C9ABB-5570-4B1E-AB50-DF41E11911A0"
    static let container = SessionHost.Endpoint(address: "127.0.0.1", port: 2222)
    static let masterStart: TimeInterval = 1_791_115_700

    var herdrRemoteChain: [Int32: Proc] {
        [
            50: Proc(parent: 1, path: "/Applications/Evlat.app/Contents/MacOS/Evlat"),
            51: Proc(parent: 50, path: Self.sshPath),
            6679: Proc(parent: 1, path: Self.bateriPath, app: bateri),
            1575: Proc(parent: 6679, path: "/usr/bin/login"),
            1576: Proc(parent: 1575, path: "/bin/zsh"),
            2241: Proc(parent: 1576, path: "/Users/u/.local/bin/herdr"),
            2250: Proc(parent: 2241, path: "/Users/u/.local/bin/herdr"),
            2251: Proc(parent: 2241, path: Self.sshPath),
            2245: Proc(parent: 1, path: Self.sshPath),
        ]
    }

    func herdrRemote(_ reply: RemoteHost.Reply, table: [Int32: Proc]? = nil,
                     environment: [Int32: [String]]? = nil,
                     arguments: [Int32: [String]] = [2241: ["herdr", "--remote", "ssh://dev@127.0.0.1:2222"],
                                                     2250: ["/Users/u/.local/bin/herdr", "client"]]) -> SessionHost {
        // The master's accepted end (0xA2) is the rider's peer; 0xA1 is its
        // listening socket.
        let sockets: [Int32: [SessionHost.UnixSocket]] = [2245: [.init(pcb: 0xA1, peer: 0), .init(pcb: 0xA2, peer: 0)],
                                                          2251: [.init(pcb: 0xB1, peer: 0xA2)]]
        let tcp: [Int32: [SessionHost.TCPSocket]] = [
            51: [.init(local: .init(address: "127.0.0.1", port: 49890), remote: Self.container)],
            2245: [.init(local: .init(address: "127.0.0.1", port: 49567), remote: Self.container)]]
        return SessionHost.resolve(remote: reply, tunnel: Self.tunnel, evlat: Self.evlat,
                                   probe(table ?? herdrRemoteChain,
                                         environment: environment ?? [2241: Self.bateriTab(Self.remoteTab)],
                                         arguments: arguments, sockets: sockets,
                                         started: [2245: Self.masterStart, 2251: Self.masterStart + 1], tcp: tcp))
    }

    var herdrBridge: RemoteHost.Reply {
        .connection(RemoteHost.Connection(clientPort: 48638, serverPort: 22,
                                          startedAt: Date(timeIntervalSince1970: Self.masterStart + 0.85), offset: 0,
                                          forwarded: [Self.forwardedTab(Self.remoteTab)], herdrPane: .selectable))
    }

    func testHerdrsOwnMasterStandsForItsRemoteClient() {
        guard case .app(let app) = herdrRemote(herdrBridge) else { return XCTFail("no app") }
        XCTAssertEqual(app.bundleID, bateri.bundleID)
        XCTAssertEqual(app.tab?.absoluteString, "bateri://tab/\(Self.remoteTab)")
        XCTAssertEqual(app.serverPane, .selectable)
        XCTAssertEqual(tab(of: herdrRemote(herdrBridge, environment: [:])), "bateri://tab/\(Self.remoteTab)",
                       "herdr's environment unread: the forwarded value fills the tab")
    }

    /// Only that chain: a master that did not detach, a rider under a
    /// shell (the user's own `ControlPersist`), or a `herdr` not run with
    /// `--remote` leave the rule for riders as it was.
    func testOnlyHerdrsDetachedMasterStandsForItsClient() {
        var shell = herdrRemoteChain
        shell[2251] = Proc(parent: 1576, path: Self.sshPath)
        XCTAssertEqual(herdrRemote(herdrBridge, table: shell), .notFound, "the user's own detached master")
        XCTAssertEqual(herdrRemote(herdrBridge, arguments: [2241: ["herdr"]]), .notFound, "not --remote")
        var attached = herdrRemoteChain
        attached[2245] = Proc(parent: 2241, path: Self.sshPath)
        XCTAssertNil(Ssh.herdrRemoteClients(master: 2245, riders: [2251],
                                            probe(attached, arguments: [2241: ["herdr", "--remote", "x"]])))
        XCTAssertEqual(Ssh.herdrRemoteClients(master: 2245, riders: [2251],
                                              probe(herdrRemoteChain, arguments: [2241: ["herdr", "--remote", "x"]])),
                       [2241])
    }

    /// Two `herdr --remote` tabs on one master are one connection to the
    /// server: the app comes forward, no tab is guessed.
    func testTwoRemoteClientsOnOneMasterBringTheAppOnly() {
        var table = herdrRemoteChain
        table[3576] = Proc(parent: 1575, path: "/bin/zsh")
        table[3241] = Proc(parent: 3576, path: "/Users/u/.local/bin/herdr")
        table[3251] = Proc(parent: 3241, path: Self.sshPath)
        let sockets: [Int32: [SessionHost.UnixSocket]] = [2245: [.init(pcb: 0xA1, peer: 0), .init(pcb: 0xA2, peer: 0),
                                                                 .init(pcb: 0xA3, peer: 0)],
                                                          2251: [.init(pcb: 0xB1, peer: 0xA2)],
                                                          3251: [.init(pcb: 0xC1, peer: 0xA3)]]
        let tcp: [Int32: [SessionHost.TCPSocket]] = [
            51: [.init(local: .init(address: "127.0.0.1", port: 49890), remote: Self.container)],
            2245: [.init(local: .init(address: "127.0.0.1", port: 49567), remote: Self.container)]]
        let host = SessionHost.resolve(remote: herdrBridge, tunnel: Self.tunnel, evlat: Self.evlat,
                                       probe(table, environment: [2241: Self.bateriTab(Self.remoteTab),
                                                                  3241: Self.bateriTab(Self.olderTab)],
                                             arguments: [2241: ["herdr", "--remote", "a"], 3241: ["herdr", "--remote", "a"]],
                                             sockets: sockets, started: [2245: Self.masterStart], tcp: tcp))
        guard case .app(let app) = host else { return XCTFail("no app") }
        XCTAssertEqual(app.bundleID, bateri.bundleID)
        XCTAssertNil(app.tab)
        XCTAssertEqual(app.serverPane, .selectable)
    }
}
