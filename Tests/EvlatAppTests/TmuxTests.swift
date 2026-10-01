import XCTest
@testable import EvlatApp

/// A tmux pane is hosted where its session's most recent client runs (`Tmux`).
extension SessionHostTests {
    static let tmuxPath = "/opt/homebrew/bin/tmux"
    static let tmuxEnvironment = ["TMUX=/private/tmp/tmux-501/default,4000,0", "TMUX_PANE=%3"]

    /// claude in a tmux pane; the server is parented to launchd, two clients
    /// in two Bateri tabs and a third attached to another session.
    var tmuxInBateri: [Int32: Proc] {
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

    func tmuxProbe(_ reply: TmuxReply?, asked: ((TmuxQuery) -> Void)? = nil) -> SessionHost.Probe {
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
}
