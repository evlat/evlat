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
                    offset: TimeInterval? = 0.24, forwarded: [String] = []) -> RemoteHost.Reply {
        // The server's clock runs `offset` ahead: its start reads that much later.
        .connection(RemoteHost.Connection(clientPort: port, serverPort: 22,
                                          startedAt: Date(timeIntervalSince1970: start + (offset ?? 0)),
                                          offset: offset, forwarded: forwarded))
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
        XCTAssertEqual(TabLink.owners(ofForwarded: "LC_BATERI_TAB_URL"), ["dev.bateri.bateri", "io.github.bateri.bateri"])
        XCTAssertEqual(TabLink.owners(ofForwarded: "BATERI_TAB_URL"), [])
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

    /// A forwarded tab names it outright: no candidate is needed, none is
    /// matched — not even when two are too close to tell apart.
    func testAForwardedTabComesBeforeTheCandidates() {
        let reply = connection(forwarded: ["LC_OTHER=1", Self.forwardedTab(Self.newerTab)])
        let running = ["dev.bateri.bateri": bateri]
        XCTAssertEqual(tab(of: remote(reply, running: running, tunnel: nil)), "bateri://tab/\(Self.newerTab)",
                       "no tunnel, no candidate")
        let started: [Int32: TimeInterval] = [1001: Self.tabStart, 1101: Self.tabStart + 5]
        XCTAssertEqual(tab(of: remote(reply, table: twoTabs, sockets: twoTabSockets, started: started,
                                      running: running)), "bateri://tab/\(Self.newerTab)")
        XCTAssertEqual(remote(reply, table: twoTabs, sockets: twoTabSockets, started: started), .app(bateri),
                       "Bateri not running: today's order, which brings the app only")
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
}
