import XCTest
@testable import EvlatCore

/// The local endpoint's contract: which four routes exist, what a browser gets,
/// and what a hook gets back. No socket is opened here — that is the listener's
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

    /// Seven routes, and the reason each one is there. `/hook` is the path
    /// inside the command already installed in the user's settings file;
    /// `/hook/claude` is the synonym v1 accepted, and dropping it would change
    /// the contract silently. `/usage/claude` is the status line's relay,
    /// `/signal` the way in for outside programs.
    func testTheTableIsSevenRoutes() {
        XCTAssertEqual(dispatch("POST", "/hook"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/claude"), .hook(.claude))
        XCTAssertEqual(dispatch("POST", "/hook/codex"), .hook(.codex))
        XCTAssertEqual(dispatch("POST", "/usage/claude"), .usage(.claude))
        XCTAssertEqual(dispatch("GET", "/health"), .health)
        XCTAssertEqual(dispatch("POST", "/permission"), .permission)
        XCTAssertEqual(dispatch("GET", "/permission"), .notFound)
        XCTAssertEqual(dispatch("POST", "/signal"), .signal)
        XCTAssertEqual(dispatch("GET", "/signal"), .notFound, "no reading surface")
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

    /// The usage route keeps every rule the hook routes keep: POST only, the
    /// path as written, and a browser turned away before the path is read.
    func testTheUsageRouteIsDefendedLikeTheHooks() {
        XCTAssertEqual(dispatch("GET", "/usage/claude"), .notFound)
        XCTAssertEqual(dispatch("POST", "/usage/claude", origin: "https://example.com"), .forbidden)
        XCTAssertEqual(dispatch("POST", "/usage/claude", host: "evil.example:48151"), .forbidden)
        for spelling in ["/usage/claude/", "/usage/claude/..", "/usage/claude/../claude", "/usage",
                         "/usage/", "/%75sage/claude", "/usage%2Fclaude", "/hook/../usage/claude"] {
            XCTAssertEqual(dispatch("POST", spelling), .notFound, spelling)
        }
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
    /// (`AGENTS.md` → Pitfalls).
    func testAHookAnswersExactlyAnEmptyObject() {
        let outcome = post("/hook", body: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertEqual(outcome.response?.status, .ok)
        XCTAssertEqual(outcome.response?.body, "{}")
        XCTAssertEqual(outcome.event?.name, "Stop")
        XCTAssertEqual(outcome.event?.sessionID, "s-1")
        XCTAssertEqual(outcome.event?.source, .claude)
    }

    /// The status line's body: `{}` back, and only the two windows forward.
    /// The rest of the body (`cost`, `workspace`, `session_id`…) has no field
    /// to land in.
    func testAUsagePostAnswersAnEmptyObjectAndDeliversTheWindows() {
        let body = #"{"session_id":"s-1","cost":{"total_cost_usd":3},"rate_limits":"#
            + #"{"five_hour":{"used_percentage":25,"resets_at":1790206798},"spend_limit":{"used_percentage":2}}}"#
        let outcome = post("/usage/claude", body: body)
        XCTAssertEqual(outcome.response?.status, .ok)
        XCTAssertEqual(outcome.response?.body, "{}")
        guard case .usage(let report)? = outcome.delivery else {
            return XCTFail("expected a usage delivery")
        }
        XCTAssertEqual(report.windows.map(\.minutes), [300])
        XCTAssertEqual(report.unrecognizedWindows, ["spend_limit"])
        XCTAssertNil(outcome.event, "a usage report is not a hook event")
    }

    func testABrokenUsageBodyIsABadRequest() {
        for body in ["", "not json", "[]", "\"text\"", "{", "null"] {
            let outcome = post("/usage/claude", body: body)
            XCTAssertEqual(outcome.response?.status, .badRequest, body)
            XCTAssertNil(outcome.delivery, body)
        }
        let refused = LocalAPI.handle(HTTPRequest(method: "POST", target: "/usage/claude", body: Data("{}".utf8),
                                                  origin: "null", host: "127.0.0.1"))
        XCTAssertEqual(refused.response?.status, .forbidden)
        XCTAssertNil(refused.delivery)
    }

    func testTheCodexRouteStampsTheEventWithItsSource() {
        let outcome = post("/hook/codex", body: #"{"hook_event_name":"Interrupt","session_id":"c-1"}"#)
        XCTAssertEqual(outcome.response?.body, "{}")
        XCTAssertEqual(outcome.event?.source, .codex)
        XCTAssertEqual(outcome.event?.name, "Stop", "the adapter runs before the typed view")
    }

    /// A body that is not a JSON object produces no event at all: half an event
    /// would move the mascot on a request Evlat could not read.
    func testABrokenBodyIsABadRequest() {
        for body in ["", "not json", "[]", "\"text\"", "{", "null"] {
            let outcome = post("/hook", body: body)
            XCTAssertEqual(outcome.response?.status, .badRequest, body)
            XCTAssertNil(outcome.event, body)
            XCTAssertTrue(outcome.response?.body.hasPrefix("{\"error\"") == true, body)
        }
    }

    func testTheRefusedAndTheUnknownCarryTheirCodes() {
        let browser = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook", body: Data("{}".utf8),
                                                  origin: "https://example.com", host: "127.0.0.1"))
        XCTAssertEqual(browser.response?.status, .forbidden)
        XCTAssertNil(browser.event, "a refused request never reaches the state machine")
        XCTAssertTrue(browser.response?.body.contains("\"forbidden\"") == true)

        let unknown = post("/hooks", body: "{}")
        XCTAssertEqual(unknown.response?.status, .notFound)
        XCTAssertTrue(unknown.response?.body.contains("\"notFound\"") == true)
    }

    func testHealthAnswersWithoutTouchingAnything() {
        let outcome = LocalAPI.handle(HTTPRequest(method: "GET", target: "/health", host: "127.0.0.1:48151"))
        XCTAssertEqual(outcome.response?.status, .ok)
        XCTAssertEqual(outcome.response?.body, "{\"ok\":true}")
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

    /// A request that came through a machine's tunnel speaks for another
    /// computer: its `$PPID` is a remote process number, and asking this Mac
    /// about it would compare against whatever local process holds that
    /// number. So the headers are treated as absent and the body's claim is
    /// deleted exactly as it is for a local request without them.
    func testATunneledRequestCarriesNoIdentity() {
        let forged = #"{"hook_event_name":"Stop","session_id":"s-1","evlat_pid":"1234","evlat_task":"stolen"}"#
        let request = HTTPRequest(method: "POST", target: "/hook", body: Data(forged.utf8),
                                  taskID: "real-task", pid: "7747", origin: nil, host: "127.0.0.1:48151")

        let tunneled = LocalAPI.handle(request, listener: LocalAPI.Listener(origin: .tunneled))
        XCTAssertEqual(tunneled.response, LocalAPI.Response(status: .ok, body: "{}"))
        XCTAssertNotNil(tunneled.event, "the event itself still arrives")
        XCTAssertNil(tunneled.event?.pid, "neither the header's pid nor the body's")
        XCTAssertNil(tunneled.event?.taskID)
        XCTAssertEqual(tunneled.event?.sessionID, "s-1")

        let local = LocalAPI.handle(request, listener: LocalAPI.Listener(origin: .local))
        XCTAssertEqual(local.event?.pid, 7747, "a local request is read as before")
        XCTAssertEqual(LocalAPI.handle(request).event?.pid, 7747, "and local is the default")
    }

    /// The tunnel changes whose identity is trusted, not who may speak: the
    /// browser defence and the table are the same on both origins.
    func testATunneledRequestIsDefendedLikeALocalOne() {
        let browser = HTTPRequest(method: "POST", target: "/hook", body: Data("{}".utf8),
                                  origin: "https://example.com", host: "127.0.0.1:48151")
        XCTAssertEqual(LocalAPI.handle(browser, listener: LocalAPI.Listener(origin: .tunneled)).response?.status, .forbidden)
        let unknown = HTTPRequest(method: "POST", target: "/nope", body: Data("{}".utf8),
                                  host: "127.0.0.1:48151")
        XCTAssertEqual(LocalAPI.handle(unknown, listener: LocalAPI.Listener(origin: .tunneled)).response?.status, .notFound)
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

    // MARK: - Permission

    private let permissionBody = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func permission(_ body: String, token: String? = "T-1",
                            origin: LocalAPI.Origin = .local) -> LocalAPI.Outcome {
        LocalAPI.handle(HTTPRequest(method: "POST", target: "/permission", body: Data(body.utf8),
                                    host: "127.0.0.1:48151", permissionToken: token),
                        listener: LocalAPI.Listener(origin: origin))
    }

    /// A chat's own request: no answer yet — it is the user's — and the
    /// request goes to the app with its token.
    func testAPermissionRequestIsHeldForTheUser() {
        let outcome = permission(permissionBody)
        XCTAssertNil(outcome.response, "the answer waits for the card")
        guard case .permission(let request)? = outcome.delivery else { return XCTFail("no request") }
        XCTAssertEqual(request.token, "T-1")
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertFalse(request.id.isEmpty)
    }

    /// A remote machine never opens a card here; the route does not exist
    /// through a tunnel.
    func testATunneledPermissionRequestIsNotFound() {
        let outcome = permission(permissionBody, origin: .tunneled)
        XCTAssertEqual(outcome.response?.status, .notFound)
        XCTAssertNil(outcome.delivery)
    }

    func testAPermissionRequestWithoutATokenIsForbidden() {
        let outcome = permission(permissionBody, token: nil)
        XCTAssertEqual(outcome.response?.status, .forbidden)
        XCTAssertNil(outcome.delivery)
        XCTAssertEqual(LocalAPI.unknownToken.status, .forbidden)
    }

    func testABadPermissionBodyIsABadRequest() {
        for body in ["", "[]", #"{"hook_event_name":"PermissionRequest"}"#, #"{"hook_event_name":"Stop","tool_name":"Bash"}"#] {
            let outcome = permission(body)
            XCTAssertEqual(outcome.response?.status, .badRequest, body)
            XCTAssertNil(outcome.delivery, body)
        }
    }

    /// A browser is turned away before the route is looked at, as everywhere.
    func testABrowserCannotAskForPermission() {
        let request = HTTPRequest(method: "POST", target: "/permission", body: Data(permissionBody.utf8),
                                  origin: "https://example.com", host: "127.0.0.1:48151", permissionToken: "T-1")
        XCTAssertEqual(LocalAPI.handle(request).response?.status, .forbidden)
    }

    // MARK: - /signal

    private let signalBody = #"{"id":"build","ttl":60,"phase":"working","label":"npm run build"}"#
    private let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func signal(_ body: String? = nil, sent: String? = nil, listenerKey: String? = nil,
                        origin: LocalAPI.Origin = .local, target: String = "/signal") -> LocalAPI.Outcome {
        LocalAPI.handle(HTTPRequest(method: "POST", target: target, body: Data((body ?? signalBody).utf8),
                                    host: "127.0.0.1:48151", signalKey: sent),
                        listener: LocalAPI.Listener(origin: origin, signalKey: listenerKey))
    }

    /// The right key: the report is handed over and the answer is `{}`.
    func testASignalWithTheRightKeyIsDelivered() {
        let outcome = signal(sent: key, listenerKey: key)
        XCTAssertEqual(outcome.response, LocalAPI.Response(status: .ok, body: "{}"))
        guard case .signal(let report)? = outcome.delivery else { return XCTFail("no report") }
        XCTAssertEqual(report.id, "build")
        XCTAssertEqual(report.label, "npm run build")
    }

    /// No key sent, a wrong one, or one of another length: `403`, and nothing
    /// reaches the app.
    func testASignalWithoutTheKeyIsForbidden() {
        for sent in [nil, "wrong", String(key.dropLast()), key + "0", key.uppercased()] as [String?] {
            let outcome = signal(sent: sent, listenerKey: key)
            XCTAssertEqual(outcome.response?.status, .forbidden, sent ?? "nil")
            XCTAssertNil(outcome.delivery, sent ?? "nil")
        }
    }

    /// A listener without a key refuses every signal — whatever is sent,
    /// even an empty header that "matches" an empty key.
    func testAListenerWithoutAKeyRefusesEverySignal() {
        XCTAssertEqual(signal(sent: key, listenerKey: nil).response?.status, .forbidden)
        XCTAssertEqual(signal(sent: nil, listenerKey: nil).response?.status, .forbidden)
        XCTAssertEqual(signal(sent: nil, listenerKey: "").response?.status, .forbidden)
        XCTAssertEqual(signal(sent: "", listenerKey: "").response?.status, .forbidden)
        // The default listener has none.
        let request = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  host: "127.0.0.1:48151", signalKey: key)
        XCTAssertEqual(LocalAPI.handle(request).response?.status, .forbidden)
    }

    /// Through a tunnel whose listener has no key the route does not exist,
    /// whatever is sent: a machine without a key learns nothing about it.
    func testATunneledSignalWithoutAListenerKeyIsNotFound() {
        for sent in [key, nil] as [String?] {
            let outcome = signal(sent: sent, listenerKey: nil, origin: .tunneled)
            XCTAssertEqual(outcome.response?.status, .notFound, sent ?? "nil")
            XCTAssertNil(outcome.delivery)
        }
        let request = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  host: "127.0.0.1:48151", signalKey: key)
        XCTAssertEqual(LocalAPI.handle(request, listener: LocalAPI.Listener(origin: .tunneled)).response?.status, .notFound)
    }

    /// A tunnel's listener with its machine's key answers exactly as
    /// the local one does: the key first, then the body.
    func testATunneledSignalWithTheMachinesKeyIsTheLocalRoute() {
        let delivered = signal(sent: key, listenerKey: key, origin: .tunneled)
        XCTAssertEqual(delivered.response, LocalAPI.Response(status: .ok, body: "{}"))
        guard case .signal(let report)? = delivered.delivery else { return XCTFail("no report") }
        XCTAssertEqual(report.id, "build")
        for sent in [nil, "wrong", String(key.dropLast()), key + "0"] as [String?] {
            let outcome = signal(sent: sent, listenerKey: key, origin: .tunneled)
            XCTAssertEqual(outcome.response?.status, .forbidden, sent ?? "nil")
            XCTAssertNil(outcome.delivery, sent ?? "nil")
        }
        let broken = signal(#"{"id":"x","ttl":60,"phase":"idle"}"#, sent: key, listenerKey: key, origin: .tunneled)
        XCTAssertEqual(broken.response?.status, .badRequest)
        XCTAssertEqual(broken.response?.body.contains("\"code\":\"invalidPhase\""), true)
        XCTAssertEqual(signal("[]", sent: nil, listenerKey: key, origin: .tunneled).response?.status, .forbidden,
                       "the body is read only once the key has passed")
    }

    /// A key on the tunnel's listener opens `/signal` and nothing else:
    /// `/permission` stays this Mac's own.
    func testAKeyedTunnelStillHasNoPermissionRoute() {
        let request = HTTPRequest(method: "POST", target: PermissionHook.path, body: Data(permissionBody.utf8),
                                  host: "127.0.0.1:48151", permissionToken: "t", signalKey: key)
        let outcome = LocalAPI.handle(request, listener: LocalAPI.Listener(origin: .tunneled, signalKey: key))
        XCTAssertEqual(outcome.response?.status, .notFound)
        XCTAssertNil(outcome.delivery)
    }

    /// A browser is refused before the key is looked at: the key never
    /// decides for a request that carries an `Origin`.
    func testABrowserIsRefusedBeforeTheKey() {
        let request = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  origin: "https://example.com", host: "127.0.0.1:48151", signalKey: key)
        let outcome = LocalAPI.handle(request, listener: LocalAPI.Listener(origin: .local, signalKey: key))
        XCTAssertEqual(outcome.response?.status, .forbidden)
        XCTAssertNil(outcome.delivery)
        let rebound = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  host: "evil.example:48151", signalKey: key)
        XCTAssertEqual(LocalAPI.handle(rebound, listener: LocalAPI.Listener(origin: .local, signalKey: key))
                        .response?.status, .forbidden)
    }

    /// Only the spelling in the table reaches the route.
    func testTheSignalRouteHasOneSpelling() {
        for target in ["/signal/", "/%73ignal", "/signal%2F..", "/hook/../signal", "/signal/..", "/./signal"] {
            let outcome = signal(sent: key, listenerKey: key, target: target)
            XCTAssertEqual(outcome.response?.status, .notFound, target)
            XCTAssertNil(outcome.delivery, target)
        }
    }

    /// A bad body is `400` with the rejection's own code, and only once the
    /// key has passed: without it, the body is never read.
    func testABadSignalBodyCarriesItsCode() {
        let cases: [(String, String)] = [
            ("[]", "badRequest"),
            ("", "badRequest"),
            (#"{"ttl":60,"phase":"working"}"#, "invalidId"),
            (#"{"id":"x","phase":"working"}"#, "invalidTtl"),
            (#"{"id":"x","ttl":60,"phase":"idle"}"#, "invalidPhase"),
            (#"{"id":"x","ttl":60,"phase":"working","progress":2}"#, "invalidProgress"),
        ]
        for (body, code) in cases {
            let outcome = signal(body, sent: key, listenerKey: key)
            XCTAssertEqual(outcome.response?.status, .badRequest, body)
            XCTAssertEqual(outcome.response?.body.contains("\"code\":\"\(code)\""), true, body)
            XCTAssertNil(outcome.delivery, body)
            XCTAssertEqual(signal(body, sent: nil, listenerKey: key).response?.status, .forbidden, body)
        }
    }

    /// The comparison walks every byte whatever the lengths, and still says
    /// no to a prefix, an extension and an empty key.
    func testTheKeyComparison() {
        XCTAssertTrue(LocalAPI.sameKey("abc", "abc"))
        XCTAssertFalse(LocalAPI.sameKey("abd", "abc"))
        XCTAssertFalse(LocalAPI.sameKey("ab", "abc"))
        XCTAssertFalse(LocalAPI.sameKey("abcd", "abc"))
        XCTAssertFalse(LocalAPI.sameKey("", "abc"))
        XCTAssertFalse(LocalAPI.sameKey("", ""), "an empty key is no key")
        // 256 bytes apart: a length difference folded into a byte would wrap.
        XCTAssertFalse(LocalAPI.sameKey(String(repeating: "a", count: 256), ""))
        XCTAssertFalse(LocalAPI.sameKey("a" + String(repeating: "\0", count: 256), "a"))
    }
}

private extension LocalAPI.Outcome {
    /// The hook event, when the delivery is one; most of this file asks only that.
    var event: HookEvent? {
        if case .hook(let event)? = delivery { return event }
        return nil
    }
}
