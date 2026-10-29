import XCTest
import EvlatCore
@testable import EvlatApp

/// A `claude --bg` session's chain, as measured on 2.1.312: the hook's
/// parent is the session (`claude bg-spare …`), under `claude bg-pty-host`,
/// under `claude daemon run`, under launchd.
final class BackgroundSessionTests: XCTestCase {
    let table: [Int32: (parent: Int32, args: [String])] = [
        38546: (1, ["claude", "daemon", "run", "--origin", "transient"]),
        38553: (38546, ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/x.pty.sock", "200", "50"]),
        38556: (38553, ["claude", "bg-spare", "--bg-spare", "/tmp/x.claim.sock"]),
        500: (1, ["/Applications/cmux.app/Contents/MacOS/cmux"]),
        501: (500, ["-zsh"]),
        502: (501, ["claude"]),
    ]

    func attach(_ pid: Int32?) -> [String]? {
        BackgroundSession.attach(pid: pid, sessionID: "b5376907-867a-4a71-9299-a4b750c98b28",
                                 parent: { self.table[$0]?.parent },
                                 arguments: { self.table[$0]?.args ?? [] })?.arguments
    }

    func testABackgroundSessionIsAttachedByItsShortID() {
        XCTAssertEqual(attach(38556), ["claude", "attach", "b5376907"])
    }

    func testASessionInATerminalIsNot() {
        XCTAssertNil(attach(502))
        XCTAssertNil(attach(nil))
        XCTAssertNil(attach(9999))
    }

    // MARK: - Where it opens: where the other sessions run

    let cmux = SessionHost.App(bundleID: "com.cmuxterm.app", name: "cmux", pid: 651)
    let terminal = SessionHost.App(bundleID: "com.apple.Terminal", name: "Terminal", pid: 400)
    let ghostty = SessionHost.App(bundleID: "com.mitchellh.ghostty", name: "Ghostty", pid: 300)

    /// Measured with herdr 0.9.5 in cmux: the client is `herdr` in a shell
    /// of cmux's tab, the server `herdr server` under launchd, its panes'
    /// agents under it. Beside them, a Terminal and a Ghostty with an agent
    /// each, in a plain shell.
    func probe(herdrServer: Bool = true, herdrClient: Bool = true) -> SessionHost.Probe {
        var table: [Int32: SessionHostTests.Proc] = [
            651: .init(parent: 1, path: "/Applications/cmux.app/Contents/MacOS/cmux", app: cmux),
            52722: .init(parent: 651, path: "/bin/zsh"),
            60000: .init(parent: 52722, path: "/Users/u/.local/bin/herdr"),
            400: .init(parent: 1, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                       app: terminal),
            401: .init(parent: 400, path: "/bin/zsh"),
            410: .init(parent: 401, path: "/Users/u/.local/bin/claude"),
            411: .init(parent: 401, path: "/Users/u/.local/bin/claude"),
            300: .init(parent: 1, path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", app: ghostty),
            301: .init(parent: 300, path: "/bin/zsh"),
            310: .init(parent: 301, path: "/Users/u/.local/bin/codex"),
        ]
        if herdrClient { table[53524] = .init(parent: 52722, path: "/Users/u/.local/bin/herdr") }
        if herdrServer {
            table[22418] = .init(parent: 1, path: "/Users/u/.local/bin/herdr")
            table[22500] = .init(parent: 22418, path: "/bin/zsh")
            table[22510] = .init(parent: 22500, path: "/Users/u/.local/bin/claude")
            table[22511] = .init(parent: 22500, path: "/Users/u/.local/bin/claude")
        }
        return SessionHostTests().probe(table, arguments: [
            53524: ["herdr"], 22418: ["/Users/u/.local/bin/herdr", "server"],
            60000: ["herdr", "pane", "list"],
        ], terminals: [53524: true, 60000: true])
    }

    func place(_ others: [Int32], herdrServer: Bool = true, herdrClient: Bool = true) -> BackgroundSession.Place {
        BackgroundSession.place(among: others, probe(herdrServer: herdrServer, herdrClient: herdrClient),
                                opensCommandFiles: { _ in true })
    }

    /// Everything in Terminal: Terminal, though herdr is open in cmux.
    func testItOpensWhereTheOtherSessionsRun() {
        XCTAssertEqual(place([410, 411]), .app(terminal))
        XCTAssertEqual(place([310]), .app(ghostty))
        XCTAssertEqual(place([310]).name, "Ghostty")
    }

    /// Sessions in herdr's panes: a new tab of herdr's newest client, in
    /// the app that client runs in.
    func testSessionsInHerdrOpenInANewHerdrTab() {
        let herdr = BackgroundSession.Place.herdr(app: cmux, cli: "/Users/u/.local/bin/herdr", session: nil)
        XCTAssertEqual(place([22510]), herdr)
        XCTAssertEqual(place([22510]).name, "cmux")
        XCTAssertEqual(place([22510, 22511, 410]), herdr, "most of them")
    }

    func testTheMostWinsAndATieGoesToTheMostRecent() {
        XCTAssertEqual(place([310, 410, 411]), .app(terminal))
        XCTAssertEqual(place([310, 410]), .app(ghostty))
        XCTAssertEqual(place([410, 22510]), .app(terminal))
    }

    /// Sessions in herdr with no client open: herdr cannot be shown, so
    /// the next place the sessions run.
    func testAPlaceThatCannotBeOpenedGivesWayToTheNext() {
        XCTAssertEqual(place([22510, 22511, 410], herdrClient: false), .app(terminal))
        let found = BackgroundSession.place(among: [410, 411, 310], probe(), opensCommandFiles: { $0 != self.terminal })
        XCTAssertEqual(found, .app(ghostty))
    }

    /// With nothing left to follow, the default app.
    func testWithNothingToFollowItIsTheDefaultApp() {
        XCTAssertEqual(place([22510], herdrClient: false), .commandFile(app: BackgroundSession.terminalName))
        XCTAssertEqual(place([]), .commandFile(app: BackgroundSession.terminalName))
        XCTAssertEqual(place([9999]), .commandFile(app: BackgroundSession.terminalName), "no app found")
    }

    /// An app that opens no `.command` files is not one to open it in.
    func testAnAppThatCannotOpenItIsSkipped() {
        let found = BackgroundSession.place(among: [410], probe(), opensCommandFiles: { $0 != self.terminal })
        XCTAssertEqual(found, .commandFile(app: BackgroundSession.terminalName))
    }

    /// The file runs the line in the user's shell, login and interactive:
    /// `claude` is often on the `PATH` only from `.zshrc`.
    func testTheCommandFileRunsTheLineInTheUsersShell() {
        let text = BackgroundSession.commandFileText("claude attach 1a2b3c4d")
        XCTAssertTrue(text.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(text.contains(#""${SHELL:-/bin/zsh}" -lic 'claude attach 1a2b3c4d' ||"#))
    }

    func testTheNewTabsPaneIsReadFromHerdrsReply() {
        let reply = #"{"id":"cli:tab:create","result":{"root_pane":{"pane_id":"w7:pJ","tab_id":"w7:tJ"},"tab":{"tab_id":"w7:tJ"},"type":"tab_created"}}"#
        XCTAssertEqual(BackgroundSession.createdPane(reply), "w7:pJ")
        XCTAssertNil(BackgroundSession.createdPane("{}"))
    }
}
