import XCTest
@testable import EvlatCore

/// The half of the local endpoint's contract that names the agents: each
/// agent's route, and the hook command already installed in the user's
/// settings files. The routing rules every route shares (the browser, the
/// answers, the keyed and held routes) stay with the core's own tests.
final class LocalAPITests: XCTestCase {
    /// Default arguments are what a hook's `curl` actually sends: no `Origin`,
    /// a loopback `Host`.
    private func dispatch(_ method: String, _ target: String,
                          origin: String? = nil, host: String? = "127.0.0.1:48151") -> LocalAPI.Dispatch {
        LocalAPI.dispatch(method: method, target: target, origin: origin, host: host)
    }

    private func post(_ target: String, body: String,
                      taskID: String? = nil, pid: String? = nil) -> LocalAPI.Outcome {
        LocalAPI.handle(HTTPRequest(method: "POST", target: target, body: Data(body.utf8),
                                    taskID: taskID, pid: pid, origin: nil, host: "127.0.0.1:48151"))
    }

    // MARK: - The table

    /// The routes, and the reason each one is there. `/hook` is the path
    /// inside the command already installed in the user's settings file;
    /// `/hook/claude` is the synonym v1 accepted, and dropping it would change
    /// the contract silently. `/usage/claude` is the status line's relay,
    /// `/signal` the way in for outside programs, `/askpass` the tunnel's
    /// `ssh` asking for a password.
    func testTheTable() {
        XCTAssertEqual(dispatch("POST", "/hook"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/claude"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/codex"), .hook(.codex))
        XCTAssertEqual(dispatch("POST", "/usage/claude"), .usage(.claude))
        XCTAssertEqual(dispatch("GET", "/health"), .health)
        XCTAssertEqual(dispatch("POST", "/permission"), .permission)
        XCTAssertEqual(dispatch("GET", "/permission"), .notFound)
        XCTAssertEqual(dispatch("POST", "/signal"), .signal)
        XCTAssertEqual(dispatch("GET", "/signal"), .notFound, "no reading surface")
        XCTAssertEqual(dispatch("POST", "/askpass"), .askpass)
        XCTAssertEqual(dispatch("GET", "/askpass"), .notFound)
        XCTAssertEqual(dispatch("POST", "/askpass/"), .notFound)
        // v1's action, read and `/mac/` endpoints are out of scope for v2 and
        // were not ported: they answer nothing at all.
        for target in ["/status", "/ask?q=hi", "/panel/toggle", "/mac/screenshot", "/motions", "/hook/nope"] {
            XCTAssertEqual(dispatch("POST", target), .notFound, target)
            XCTAssertEqual(dispatch("GET", target), .notFound, target)
        }
    }

    /// Every source's own path answers, and it answers as that source. Adding a
    /// source without opening its route fails here rather than at runtime.
    func testEverySourceHasItsOwnRoute() {
        for source in AgentSource.allCases {
            XCTAssertEqual(dispatch("POST", source.hookPath), .hook(source), source.rawValue)
            if let usagePath = source.usagePath {
                XCTAssertEqual(dispatch("POST", usagePath), .usage(source), source.rawValue)
            }
        }
        // Only Claude documents its usage; Codex's is read from a file.
        XCTAssertEqual(AgentSource.claude.usagePath, "/usage/claude")
        XCTAssertNil(AgentSource.codex.usagePath)
        XCTAssertEqual(dispatch("POST", "/usage/codex"), .notFound)
    }

    /// A side-effecting endpoint is POST-only, and that is what makes the
    /// `Origin` rule hold: a browser's no-cors request carries no `Origin`, but
    /// it can only be a GET.
    func testHookRoutesAreReachedByPOSTOnly() {
        for source in AgentSource.allCases {
            XCTAssertEqual(dispatch("GET", source.hookPath), .notFound, source.rawValue)
        }
        XCTAssertEqual(dispatch("GET", "/hook/claude"), .notFound)
    }

    // MARK: - The answers

    func testTheCodexRouteStampsTheEventWithItsSource() {
        let outcome = post("/hook/codex", body: #"{"hook_event_name":"Interrupt","session_id":"c-1"}"#)
        XCTAssertEqual(outcome.response?.body, "{}")
        XCTAssertEqual(outcome.event?.source, .codex)
        XCTAssertEqual(outcome.event?.name, "Stop", "the adapter runs before the typed view")
    }

    // MARK: - The installed command

    /// **The golden string.** This set installs nothing: the command below is
    /// already sitting in the user's `~/.claude/settings.json` and
    /// `~/.codex/hooks.json`, and nothing else in v2 checks that v2 still
    /// answers it. The literals are written out by hand, port and path
    /// included, precisely so that a change anywhere in the derivation —
    /// `hookPath`, `defaultPort`, a header name, a shell quote — breaks here
    /// instead of in a session that silently stops reporting.
    ///
    /// Both were read back from the installed files on 2026-09-22 and matched
    /// byte for byte.
    func testTheInstalledHookCommandIsUnchanged() {
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .claude),
            "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true")
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .codex),
            "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook/codex >/dev/null 2>&1 || true")
    }

    /// What the command promises about itself: it stays silent, it gives up
    /// quickly, and it never fails the hook. The answer is not fed back to
    /// Claude Code, and `curl` waiting on a closed Evlat would stall the agent.
    func testTheInstalledCommandFailsSilently() {
        for source in AgentSource.allCases {
            let command = LocalAPI.installedHookCommand(for: source)
            XCTAssertTrue(command.contains("|| true"), source.rawValue)
            XCTAssertTrue(command.contains("-m 2"), source.rawValue)
            XCTAssertTrue(command.contains(">/dev/null 2>&1"), source.rawValue)
            XCTAssertTrue(command.contains("http://127.0.0.1:\(LocalAPI.defaultPort)\(source.hookPath) "), source.rawValue)
        }
    }

    /// The header names the command sends are the ones the parser reads. `$PPID`
    /// and `${EVLAT_TASK:-}` resolve while the hook runs, not while it is
    /// installed, so they are plain text here.
    ///
    /// The hand-written request below carries `X-Evlat-Task` because it is
    /// pinning the **parser**. On the wire the user's own sessions send no such
    /// line at all: `${EVLAT_TASK:-}` expands to nothing and curl drops a
    /// header with an empty value rather than sending it (measured, curl 8.7.1
    /// — unlike `Origin`, where an empty value still counts because a browser
    /// does send the line).
    func testTheCommandSendsTheHeadersTheServerReads() throws {
        let command = LocalAPI.installedHookCommand(for: .claude)
        XCTAssertTrue(command.contains("X-Evlat-Task: ${EVLAT_TASK:-}"))
        XCTAssertTrue(command.contains("X-Evlat-Pid: $PPID"))
        // The same names, read back off the wire.
        let request = try XCTUnwrap(HTTPRequest.parse(Data(
            "POST /hook HTTP/1.1\r\nX-Evlat-Task: t\r\nX-Evlat-Pid: 7747\r\n\r\n".utf8)))
        XCTAssertEqual(request.taskID, "t")
        XCTAssertEqual(request.pid, "7747")
    }
}

private extension LocalAPI.Outcome {
    /// The hook event, when the delivery is one; most of this file asks only that.
    var event: HookEvent? {
        if case .hook(let event)? = delivery { return event }
        return nil
    }
}
