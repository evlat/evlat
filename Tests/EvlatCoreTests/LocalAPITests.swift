import XCTest
@testable import EvlatCore

/// The local endpoint's contract: which four routes exist, what a browser gets,
/// and what a hook gets back. No socket is opened here — that is the listener's
/// transport, and none of the rules below need it. The agents' own routes and
/// the installed hook command are held by `LocalAPITests` in `EvlatAgentsTests`.
final class LocalAPITests: XCTestCase {
    /// One agent, posting to the bare hook prefix and relaying a status
    /// line: the rules below hold for any agent's route.
    private static let agent = TestAgent(paths: [RouteTable.installedPrefix], statusLineUsage: .test(),
                                         chat: TestChatBackend())
    private static let routes = RouteTable([agent])

    private func handle(_ request: HTTPRequest,
                        listener: LocalAPI.Listener = LocalAPI.Listener(routes: routes)) -> LocalAPI.Outcome {
        LocalAPI.handle(request, listener: listener, agents: [Self.agent])
    }

    /// Default arguments are what a hook's `curl` actually sends: no `Origin`,
    /// a loopback `Host`.
    private func dispatch(_ method: String, _ target: String,
                          origin: String? = nil, host: String? = "127.0.0.1:48151") -> LocalAPI.Dispatch {
        LocalAPI.dispatch(method: method, target: target, origin: origin, host: host, routes: Self.routes)
    }

    private func post(_ target: String, body: String,
                      taskID: String? = nil, pid: String? = nil) -> LocalAPI.Outcome {
        handle(HTTPRequest(method: "POST", target: target, body: Data(body.utf8),
                                    taskID: taskID, pid: pid, origin: nil, host: "127.0.0.1:48151"))
    }

    // MARK: - The table

    /// The path is compared as written. Normalising it would let a route be
    /// reached by a spelling the route's defences never examined.
    func testThePathIsNotNormalised() {
        XCTAssertEqual(dispatch("POST", "/hook/x/.."), .notFound, "would be the hook route if normalised")
        XCTAssertEqual(dispatch("POST", "/./hook"), .notFound)
        XCTAssertEqual(dispatch("POST", "/hook/"), .notFound, "a trailing slash is a different path")
        XCTAssertEqual(dispatch("GET", "/mac/screenshot/../click"), .notFound)
        // Nor is it unescaped: a decoded path would give every route a second,
        // unexamined spelling.
        XCTAssertEqual(dispatch("POST", "/%68ook"), .notFound)
        XCTAssertEqual(dispatch("POST", "/hook%2Fx"), .notFound)
    }

    /// The query is not part of the path, and it is ignored: v2 has no endpoint
    /// that takes an argument.
    func testTheQueryDoesNotChangeTheRoute() {
        XCTAssertEqual(dispatch("POST", "/hook?source=x"), .hook(.test))
        XCTAssertEqual(dispatch("GET", "http://127.0.0.1:48151/health"), .health, "an absolute target is legal HTTP")
    }

    /// The usage route keeps every rule the hook routes keep: POST only, the
    /// path as written, and a browser turned away before the path is read.
    func testTheUsageRouteIsDefendedLikeTheHooks() {
        XCTAssertEqual(dispatch("GET", "/usage/test"), .notFound)
        XCTAssertEqual(dispatch("POST", "/usage/test", origin: "https://example.com"), .forbidden)
        XCTAssertEqual(dispatch("POST", "/usage/test", host: "evil.example:48151"), .forbidden)
        for spelling in ["/usage/test/", "/usage/test/..", "/usage/test/../test", "/usage",
                         "/usage/", "/%75sage/test", "/usage%2Ftest", "/hook/../usage/test"] {
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
            XCTAssertEqual(dispatch("POST", "/hook", host: host), .hook(.test), host)
        }
        // A browser always sends `Host`; its absence means the request is not
        // from one (v1's `curl -H 'Host:'` case).
        XCTAssertEqual(dispatch("POST", "/hook", host: nil), .hook(.test))
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
        XCTAssertEqual(outcome.event?.source, .test)
    }

    /// The status line's body: `{}` back, and only the two windows forward.
    /// The rest of the body (`cost`, `workspace`, `session_id`…) has no field
    /// to land in.
    func testAUsagePostAnswersAnEmptyObjectAndDeliversTheWindows() {
        let body = #"{"session_id":"s-1","cost":{"total_cost_usd":3},"rate_limits":"#
            + #"{"five_hour":{"used_percentage":25,"resets_at":1790206798},"spend_limit":{"used_percentage":2}}}"#
        let outcome = post("/usage/test", body: body)
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
            let outcome = post("/usage/test", body: body)
            XCTAssertEqual(outcome.response?.status, .badRequest, body)
            XCTAssertNil(outcome.delivery, body)
        }
        let refused = handle(HTTPRequest(method: "POST", target: "/usage/test", body: Data("{}".utf8),
                                                  origin: "null", host: "127.0.0.1"))
        XCTAssertEqual(refused.response?.status, .forbidden)
        XCTAssertNil(refused.delivery)
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
        let browser = handle(HTTPRequest(method: "POST", target: "/hook", body: Data("{}".utf8),
                                                  origin: "https://example.com", host: "127.0.0.1"))
        XCTAssertEqual(browser.response?.status, .forbidden)
        XCTAssertNil(browser.event, "a refused request never reaches the state machine")
        XCTAssertTrue(browser.response?.body.contains("\"forbidden\"") == true)

        let unknown = post("/hooks", body: "{}")
        XCTAssertEqual(unknown.response?.status, .notFound)
        XCTAssertTrue(unknown.response?.body.contains("\"notFound\"") == true)
    }

    func testHealthAnswersWithoutTouchingAnything() {
        let outcome = handle(HTTPRequest(method: "GET", target: "/health", host: "127.0.0.1:48151"))
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

        let tunneled = handle(request, listener: LocalAPI.Listener(origin: .machine, routes: Self.routes))
        XCTAssertEqual(tunneled.response, LocalAPI.Response(status: .ok, body: "{}"))
        XCTAssertNotNil(tunneled.event, "the event itself still arrives")
        XCTAssertNil(tunneled.event?.pid, "neither the header's pid nor the body's")
        XCTAssertNil(tunneled.event?.taskID)
        XCTAssertEqual(tunneled.event?.sessionID, "s-1")

        let local = handle(request, listener: LocalAPI.Listener(origin: .local, routes: Self.routes))
        XCTAssertEqual(local.event?.pid, 7747, "a local request is read as before")
        XCTAssertEqual(handle(request).event?.pid, 7747, "and local is the default")
    }

    // MARK: - A sandbox's listener

    private static let sandbox = LocalAPI.Listener(origin: .sandbox, routes: routes)

    private func sandboxHook(_ body: String, name: String? = "claude-evlat",
                             listener: LocalAPI.Listener = sandbox) -> LocalAPI.Outcome {
        handle(HTTPRequest(method: "POST", target: "/hook", body: Data(body.utf8), taskID: "t", pid: "446",
                           host: "127.0.0.1:48152", sandboxName: name),
               listener: listener)
    }

    /// Only a sandbox's listener believes the header, and it stamps it
    /// into the body the way the pid is stamped: a body's own claim is
    /// deleted first. It is still a tunnel: the VM's pid and task mean
    /// nothing here.
    func testASandboxListenerStampsItsHeaderAndNoPid() {
        let forged = #"{"hook_event_name":"Stop","session_id":"s-1","evlat_sandbox":"forged"}"#
        let outcome = sandboxHook(forged)
        XCTAssertEqual(outcome.response, LocalAPI.Response(status: .ok, body: "{}"))
        XCTAssertEqual(outcome.event?.sandboxName, "claude-evlat", "the header wins over the body")
        XCTAssertNil(outcome.event?.pid, "the VM's pid is no process on this Mac")
        XCTAssertNil(outcome.event?.taskID)

        let bare = sandboxHook(forged, name: nil)
        XCTAssertNil(bare.event?.sandboxName, "no header, and the body's claim is gone too")

        let invalid = sandboxHook(forged, name: "a b")
        XCTAssertNotNil(invalid.event, "a bad name costs the name, not the event")
        XCTAssertNil(invalid.event?.sandboxName)
    }

    /// Any other listener — this Mac's own, a machine's tunnel — ignores the
    /// headers and deletes the body's keys: no local process can put a
    /// sandbox's name on a row.
    func testEveryOtherListenerIgnoresTheSandboxHeaders() {
        let forged = #"{"hook_event_name":"Stop","session_id":"s-1","evlat_sandbox":"forged"}"#
        for listener in [LocalAPI.Listener(origin: .local, routes: Self.routes),
                         LocalAPI.Listener(origin: .machine, routes: Self.routes)] {
            let outcome = sandboxHook(forged, listener: listener)
            XCTAssertNotNil(outcome.event)
            XCTAssertNil(outcome.event?.sandboxName, "\(listener.origin)")
        }
    }

    /// A sandbox's listener is a tunnel for every other route: nothing that
    /// grants or asks for anything, and no `/signal` without a key.
    func testASandboxListenerHasNoSensitiveRoute() {
        for path in [ChatRequest.path, ApprovalHook.path, Askpass.path, SignalReport.path] {
            let request = HTTPRequest(method: "POST", target: path, body: Data("{}".utf8),
                                      host: "127.0.0.1:48152", permissionToken: "p", signalKey: "k",
                                      askpassToken: "a")
            XCTAssertEqual(handle(request, listener: Self.sandbox).response?.status, .notFound, path)
        }
    }

    /// The role, not the key, closes a route: a sandbox's listener given a
    /// key — or the socket's keyless `/signal` — still has nothing but
    /// `/hook`, and a machine's listener with its key still has no held
    /// route that grants or asks.
    func testTheRoleClosesRoutesWhateverTheListenerHolds() {
        let key = String(repeating: "ab", count: 32)
        let post = { (path: String) in
            HTTPRequest(method: "POST", target: path, body: Data(#"{"id":"x","ttl":60,"phase":"working"}"#.utf8),
                        host: "127.0.0.1", permissionToken: "p", signalKey: key, askpassToken: "a")
        }
        for keyless in [false, true] {
            let sandbox = LocalAPI.Listener(origin: .sandbox, signalKey: key, keylessSignal: keyless,
                                            routes: Self.routes)
            for path in [SignalReport.path, ApprovalHook.path, ChatRequest.path, Askpass.path, "/usage/claude"] {
                let outcome = handle(post(path), listener: sandbox)
                XCTAssertEqual(outcome.response?.status, .notFound, "sandbox \(path)")
                XCTAssertNil(outcome.delivery, "sandbox \(path)")
            }
            XCTAssertEqual(handle(HTTPRequest(method: "GET", target: "/health", host: "127.0.0.1"),
                                  listener: sandbox).response?.status, .notFound, "a sandbox has only /hook")
        }
        let machine = LocalAPI.Listener(origin: .machine, signalKey: key, keylessSignal: true, routes: Self.routes)
        for path in [ChatRequest.path, Askpass.path, ApprovalHook.path] {
            XCTAssertEqual(handle(post(path), listener: machine).response?.status, .notFound, "machine \(path)")
        }
        XCTAssertEqual(handle(post(SignalReport.path), listener: machine).response?.status, .ok,
                       "a machine keeps its keyed /signal")
        XCTAssertEqual(LocalAPI.Origin.machine.role.routes, [.hook, .usage, .signal, .health])
        XCTAssertEqual(LocalAPI.Origin.sandbox.role.routes, [.hook])
        XCTAssertEqual(LocalAPI.Origin.local.role.routes, Set(LocalAPI.Route.allCases))
        XCTAssertEqual(LocalAPI.Origin.allTrusting.map(\.role.trustsSandbox), [false, false, true],
                       "only the sandbox believes X-Evlat-Sandbox")
        XCTAssertEqual(LocalAPI.Origin.allTrusting.map(\.role.trustsProcess), [true, false, false],
                       "only this Mac's pid and task are processes here")
    }

    /// The socket's listener takes `/signal` with no key; the port's local
    /// listener, with no key of its own, still refuses it.
    func testTheSocketsSignalTakesNoKey() {
        let request = HTTPRequest(method: "POST", target: SignalReport.path,
                                  body: Data(#"{"id":"x","ttl":60,"phase":"working"}"#.utf8), host: "127.0.0.1")
        let socket = handle(request, listener: LocalAPI.Listener(origin: .local, keylessSignal: true, routes: Self.routes))
        XCTAssertEqual(socket.response?.status, .ok)
        guard case .signal(let report)? = socket.delivery else { return XCTFail("not delivered") }
        XCTAssertEqual(report.id, "x")
        XCTAssertEqual(handle(request, listener: LocalAPI.Listener(origin: .local, routes: Self.routes)).response?.status,
                       .forbidden)
        let browser = HTTPRequest(method: "POST", target: SignalReport.path, body: Data("{}".utf8),
                                  origin: "https://example.com", host: "127.0.0.1")
        XCTAssertEqual(handle(browser, listener: LocalAPI.Listener(origin: .local, keylessSignal: true,
                                                                    routes: Self.routes)).response?.status,
                       .forbidden, "a browser is refused before the key is looked at")
    }

    /// The tunnel changes whose identity is trusted, not who may speak: the
    /// browser defence and the table are the same on both origins.
    func testATunneledRequestIsDefendedLikeALocalOne() {
        let browser = HTTPRequest(method: "POST", target: "/hook", body: Data("{}".utf8),
                                  origin: "https://example.com", host: "127.0.0.1:48151")
        XCTAssertEqual(handle(browser, listener: LocalAPI.Listener(origin: .machine, routes: Self.routes)).response?.status, .forbidden)
        let unknown = HTTPRequest(method: "POST", target: "/nope", body: Data("{}".utf8),
                                  host: "127.0.0.1:48151")
        XCTAssertEqual(handle(unknown, listener: LocalAPI.Listener(origin: .machine, routes: Self.routes)).response?.status, .notFound)
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

    // MARK: - Permission

    private let permissionBody = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func permission(_ body: String, token: String? = "T-1",
                            origin: LocalAPI.Origin = .local) -> LocalAPI.Outcome {
        handle(HTTPRequest(method: "POST", target: "/permission", body: Data(body.utf8),
                                    host: "127.0.0.1:48151", permissionToken: token),
                        listener: LocalAPI.Listener(origin: origin, routes: Self.routes))
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
        let outcome = permission(permissionBody, origin: .machine)
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
        XCTAssertEqual(handle(request).response?.status, .forbidden)
    }

    // MARK: - /askpass

    private let askpassToken = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

    private func askpass(_ prompt: Data = Data("nobodyx@127.0.0.1's password: ".utf8), token: String? = nil,
                         origin: LocalAPI.Origin = .local, browser: String? = nil,
                         signalKey: String? = nil) -> LocalAPI.Outcome {
        handle(HTTPRequest(method: "POST", target: Askpass.path, body: prompt,
                                    origin: browser, host: "127.0.0.1:48151",
                                    askpassToken: token ?? askpassToken),
                        listener: LocalAPI.Listener(origin: origin, signalKey: signalKey, routes: Self.routes))
    }

    /// The prompt goes to the app with its token; the answer is held, the
    /// user's (or a stored password's) to give.
    func testAnAskpassRequestIsHeld() {
        let outcome = askpass()
        XCTAssertNil(outcome.response, "the answer waits")
        guard case .askpass(let request)? = outcome.delivery else { return XCTFail("no request") }
        XCTAssertEqual(request.token, askpassToken)
        XCTAssertEqual(request.prompt, "nobodyx@127.0.0.1's password: ")
        XCTAssertFalse(request.id.isEmpty)
        // The body is the prompt as text, not JSON: several lines pass whole.
        guard case .askpass(let multi)? = askpass(Data("line one\nAre you sure (yes/no)? ".utf8)).delivery
        else { return XCTFail("no request") }
        XCTAssertEqual(multi.prompt, "line one\nAre you sure (yes/no)? ")
    }

    /// A remote machine never asks this Mac for a password, keyed or not.
    func testATunneledAskpassIsNotFound() {
        for listenerKey in [nil, key] {
            let outcome = askpass(origin: .machine, signalKey: listenerKey)
            XCTAssertEqual(outcome.response?.status, .notFound)
            XCTAssertNil(outcome.delivery)
        }
    }

    func testAnAskpassWithoutATokenIsForbidden() {
        let request = HTTPRequest(method: "POST", target: Askpass.path, body: Data("Password:".utf8),
                                  host: "127.0.0.1:48151")
        let outcome = handle(request)
        XCTAssertEqual(outcome.response?.status, .forbidden)
        XCTAssertNil(outcome.delivery)
    }

    func testABrowserCannotAskForAPassword() {
        let outcome = askpass(browser: "https://example.com")
        XCTAssertEqual(outcome.response?.status, .forbidden)
        XCTAssertNil(outcome.delivery)
    }

    func testAPromptThatIsNotTextIsABadRequest() {
        let outcome = askpass(Data([0xff, 0xfe, 0x00]))
        XCTAssertEqual(outcome.response?.status, .badRequest)
        XCTAssertNil(outcome.delivery)
        XCTAssertNotEqual(LocalAPI.noAnswer.status, .ok, "a refusal is never an answer")
    }

    func testTheAskpassTokenIsReadOffTheWire() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(Data(
            "POST /askpass HTTP/1.1\r\n\(Askpass.header): \(askpassToken)\r\nContent-Length: 9\r\n\r\nPassword:".utf8)))
        XCTAssertEqual(request.askpassToken, askpassToken)
        XCTAssertEqual(request.body, Data("Password:".utf8))
        let empty = try XCTUnwrap(HTTPRequest.parse(Data("POST /askpass HTTP/1.1\r\n\(Askpass.header):\r\n\r\n".utf8)))
        XCTAssertNil(empty.askpassToken)
    }

    // MARK: - /signal

    private let signalBody = #"{"id":"build","ttl":60,"phase":"working","label":"npm run build"}"#
    private let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func signal(_ body: String? = nil, sent: String? = nil, listenerKey: String? = nil,
                        origin: LocalAPI.Origin = .local, target: String = "/signal") -> LocalAPI.Outcome {
        handle(HTTPRequest(method: "POST", target: target, body: Data((body ?? signalBody).utf8),
                                    host: "127.0.0.1:48151", signalKey: sent),
                        listener: LocalAPI.Listener(origin: origin, signalKey: listenerKey, routes: Self.routes))
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
        XCTAssertEqual(handle(request).response?.status, .forbidden)
    }

    /// Through a tunnel whose listener has no key the route does not exist,
    /// whatever is sent: a machine without a key learns nothing about it.
    func testATunneledSignalWithoutAListenerKeyIsNotFound() {
        for sent in [key, nil] as [String?] {
            let outcome = signal(sent: sent, listenerKey: nil, origin: .machine)
            XCTAssertEqual(outcome.response?.status, .notFound, sent ?? "nil")
            XCTAssertNil(outcome.delivery)
        }
        let request = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  host: "127.0.0.1:48151", signalKey: key)
        XCTAssertEqual(handle(request, listener: LocalAPI.Listener(origin: .machine, routes: Self.routes)).response?.status, .notFound)
    }

    /// A tunnel's listener with its machine's key answers exactly as
    /// the local one does: the key first, then the body.
    func testATunneledSignalWithTheMachinesKeyIsTheLocalRoute() {
        let delivered = signal(sent: key, listenerKey: key, origin: .machine)
        XCTAssertEqual(delivered.response, LocalAPI.Response(status: .ok, body: "{}"))
        guard case .signal(let report)? = delivered.delivery else { return XCTFail("no report") }
        XCTAssertEqual(report.id, "build")
        for sent in [nil, "wrong", String(key.dropLast()), key + "0"] as [String?] {
            let outcome = signal(sent: sent, listenerKey: key, origin: .machine)
            XCTAssertEqual(outcome.response?.status, .forbidden, sent ?? "nil")
            XCTAssertNil(outcome.delivery, sent ?? "nil")
        }
        let broken = signal(#"{"id":"x","ttl":60,"phase":"idle"}"#, sent: key, listenerKey: key, origin: .machine)
        XCTAssertEqual(broken.response?.status, .badRequest)
        XCTAssertEqual(broken.response?.body.contains("\"code\":\"invalidPhase\""), true)
        XCTAssertEqual(signal("[]", sent: nil, listenerKey: key, origin: .machine).response?.status, .forbidden,
                       "the body is read only once the key has passed")
    }

    /// A key on the tunnel's listener opens `/signal` and nothing else:
    /// `/permission` stays this Mac's own.
    func testAKeyedTunnelStillHasNoPermissionRoute() {
        let request = HTTPRequest(method: "POST", target: ChatRequest.path, body: Data(permissionBody.utf8),
                                  host: "127.0.0.1:48151", permissionToken: "t", signalKey: key)
        let outcome = handle(request, listener: LocalAPI.Listener(origin: .machine, signalKey: key, routes: Self.routes))
        XCTAssertEqual(outcome.response?.status, .notFound)
        XCTAssertNil(outcome.delivery)
    }

    /// A browser is refused before the key is looked at: the key never
    /// decides for a request that carries an `Origin`.
    func testABrowserIsRefusedBeforeTheKey() {
        let request = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  origin: "https://example.com", host: "127.0.0.1:48151", signalKey: key)
        let outcome = handle(request, listener: LocalAPI.Listener(origin: .local, signalKey: key, routes: Self.routes))
        XCTAssertEqual(outcome.response?.status, .forbidden)
        XCTAssertNil(outcome.delivery)
        let rebound = HTTPRequest(method: "POST", target: "/signal", body: Data(signalBody.utf8),
                                  host: "evil.example:48151", signalKey: key)
        XCTAssertEqual(handle(rebound, listener: LocalAPI.Listener(origin: .local, signalKey: key, routes: Self.routes))
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

extension LocalAPI.Origin {
    /// The three, in the order the role table above is read.
    static let allTrusting: [LocalAPI.Origin] = [.local, .machine, .sandbox]
}
