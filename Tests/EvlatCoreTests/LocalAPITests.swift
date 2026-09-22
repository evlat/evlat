import XCTest
@testable import EvlatCore

/// The local endpoint's contract: which four routes exist, what a browser gets,
/// and what a hook gets back. No socket is opened here — that is `phase-3`'s
/// transport, and none of the rules below need it.
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

    /// Four routes, and the reason each one is there. `/hook` is the path
    /// inside the command already installed in the user's settings file;
    /// `/hook/claude` is the synonym v1 accepted, and dropping it would change
    /// the contract silently.
    func testTheTableIsFourRoutes() {
        XCTAssertEqual(dispatch("POST", "/hook"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/claude"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/codex"), .hook(.codex))
        XCTAssertEqual(dispatch("GET", "/health"), .health)
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
        }
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

    /// The path is compared as written. Normalising it would let a route be
    /// reached by a spelling the defence above never examined.
    func testThePathIsNotNormalised() {
        XCTAssertEqual(dispatch("POST", "/hook/codex/../claude"), .notFound, "would be a Claude hook if normalised")
        XCTAssertEqual(dispatch("POST", "/./hook"), .notFound)
        XCTAssertEqual(dispatch("POST", "/hook/"), .notFound, "a trailing slash is a different path")
        XCTAssertEqual(dispatch("GET", "/mac/screenshot/../click"), .notFound)
        // Nor is it unescaped: a decoded path would give every route a second,
        // unexamined spelling.
        XCTAssertEqual(dispatch("POST", "/%68ook"), .notFound)
        XCTAssertEqual(dispatch("POST", "/hook%2Fcodex"), .notFound)
    }

    /// The query is not part of the path, and it is ignored: v2 has no endpoint
    /// that takes an argument.
    func testTheQueryDoesNotChangeTheRoute() {
        XCTAssertEqual(dispatch("POST", "/hook?source=codex"), .hook(.claude))
        XCTAssertEqual(dispatch("GET", "http://127.0.0.1:48151/health"), .health, "an absolute target is legal HTTP")
    }

    // MARK: - The browser

    /// `curl` and the installed hook command never send `Origin`; a browser
    /// does, on every cross-origin POST. An empty value counts too.
    func testAnOriginMakesTheRequestABrowsersAndItIsRefused() {
        for origin in ["https://example.com", "null", ""] {
            XCTAssertEqual(dispatch("POST", "/hook", origin: origin), .forbidden, origin)
            XCTAssertEqual(dispatch("GET", "/health", origin: origin), .forbidden, origin)
        }
    }

    /// DNS rebinding: a page that resolves its own name to 127.0.0.1 sends no
    /// `Origin` on a same-origin request, but its name stays in `Host`.
    func testANonLoopbackHostIsRefused() {
        for host in ["evil.example:48151", "127.0.0.1.evil.example", "localhost.evil.example", "0.0.0.0"] {
            XCTAssertEqual(dispatch("POST", "/hook", host: host), .forbidden, host)
        }
    }

    func testTheLoopbackSpellingsPass() {
        for host in ["127.0.0.1:48151", "127.0.0.1", "localhost:48151", "LOCALHOST", "[::1]:48151", "[::1]"] {
            XCTAssertEqual(dispatch("POST", "/hook", host: host), .hook(.claude), host)
        }
        // A browser always sends `Host`; its absence means the request is not
        // from one (v1's `curl -H 'Host:'` case).
        XCTAssertEqual(dispatch("POST", "/hook", host: nil), .hook(.claude))
    }

    // MARK: - The answers

    /// The installed command throws the answer away (`>/dev/null`), but `{}`
    /// is not a coincidence: were this body ever fed back to Claude Code, a
    /// stray JSON could allow or deny a permission on the user's behalf
    /// (`proje.md` → tuzaklar).
    func testAHookAnswersExactlyAnEmptyObject() {
        let outcome = post("/hook", body: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertEqual(outcome.response.status, .ok)
        XCTAssertEqual(outcome.response.body, "{}")
        XCTAssertEqual(outcome.event?.name, "Stop")
        XCTAssertEqual(outcome.event?.sessionID, "s-1")
        XCTAssertEqual(outcome.event?.source, .claude)
    }

    func testTheCodexRouteStampsTheEventWithItsSource() {
        let outcome = post("/hook/codex", body: #"{"hook_event_name":"Interrupt","session_id":"c-1"}"#)
        XCTAssertEqual(outcome.response.body, "{}")
        XCTAssertEqual(outcome.event?.source, .codex)
        XCTAssertEqual(outcome.event?.name, "Stop", "the adapter runs before the typed view")
    }

    /// A body that is not a JSON object produces no event at all: half an event
    /// would move the mascot on a request Evlat could not read.
    func testABrokenBodyIsABadRequest() {
        for body in ["", "not json", "[]", "\"text\"", "{", "null"] {
            let outcome = post("/hook", body: body)
            XCTAssertEqual(outcome.response.status, .badRequest, body)
            XCTAssertNil(outcome.event, body)
            XCTAssertTrue(outcome.response.body.hasPrefix("{\"error\""), body)
        }
    }

    func testTheRefusedAndTheUnknownCarryTheirCodes() {
        let browser = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook", body: Data("{}".utf8),
                                                  origin: "https://example.com", host: "127.0.0.1"))
        XCTAssertEqual(browser.response.status, .forbidden)
        XCTAssertNil(browser.event, "a refused request never reaches the state machine")
        XCTAssertTrue(browser.response.body.contains("\"forbidden\""))

        let unknown = post("/hooks", body: "{}")
        XCTAssertEqual(unknown.response.status, .notFound)
        XCTAssertTrue(unknown.response.body.contains("\"notFound\""))
    }

    func testHealthAnswersWithoutTouchingAnything() {
        let outcome = LocalAPI.handle(HTTPRequest(method: "GET", target: "/health", host: "127.0.0.1:48151"))
        XCTAssertEqual(outcome.response.status, .ok)
        XCTAssertEqual(outcome.response.body, "{\"ok\":true}")
        XCTAssertNil(outcome.event)
    }

    /// These two keys are the server's word, never the body's. POST asks for no
    /// identity, so a local process could otherwise put `evlat_pid` in the body
    /// and pick where a session appears to run, or claim with `evlat_task` to be
    /// Evlat's own errand.
    func testOnlyTheServerWritesTheEvlatKeys() {
        let forged = #"{"hook_event_name":"Stop","session_id":"s-1","evlat_pid":"1234","evlat_task":"stolen"}"#

        let withoutHeaders = post("/hook", body: forged)
        XCTAssertNil(withoutHeaders.event?.pid, "the body's claim is deleted, not trusted")
        XCTAssertNil(withoutHeaders.event?.taskID)

        let withHeaders = post("/hook", body: forged, taskID: "real-task", pid: "7747")
        XCTAssertEqual(withHeaders.event?.pid, 7747, "the header wins over the body")
        XCTAssertEqual(withHeaders.event?.taskID, "real-task")
    }

    /// The bytes on the wire. `Content-Length` counts UTF-8 bytes, not
    /// characters; a body with one multi-byte character would otherwise be cut
    /// short and the client would wait for the rest until it timed out.
    func testTheWireFormatCountsBytes() {
        let response = LocalAPI.Response(status: .badRequest, body: "{\"e\":\"çığ\"}")
        let text = response.httpText
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), text)
        XCTAssertTrue(text.contains("\r\nContent-Length: 14\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"e\":\"çığ\"}"), text)
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
