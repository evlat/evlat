import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The half of the local endpoint's contract that names the agents: each
/// agent's route, and the hook command already installed in the user's
/// settings files. The routing rules every route shares (the browser, the
/// answers, the keyed and held routes) stay with the core's own tests.
final class LocalAPITests: XCTestCase {
    /// Default arguments are what a hook's `curl` actually sends: no `Origin`,
    /// a loopback `Host`.
    private func dispatch(_ method: String, _ target: String,
                          origin: String? = nil, host: String? = "127.0.0.1:48151") -> LocalAPI.Dispatch {
        LocalAPI.dispatch(method: method, target: target, origin: origin, host: host, routes: Agents.routes)
    }

    private func post(_ target: String, body: String,
                      taskID: String? = nil, pid: String? = nil) -> LocalAPI.Outcome {
        LocalAPI.handle(HTTPRequest(method: "POST", target: target, body: Data(body.utf8),
                                    taskID: taskID, pid: pid, origin: nil, host: "127.0.0.1:48151"),
                        listener: LocalAPI.Listener(routes: Agents.routes), agents: Agents.all)
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
        for source in Agents.all {
            XCTAssertEqual(dispatch("POST", source.hookPath), .hook(source.id), source.id.rawValue)
            if let usagePath = source.statusLineUsage?.path {
                XCTAssertEqual(dispatch("POST", usagePath), .usage(source.id), source.id.rawValue)
            }
        }
        // Only Claude documents its usage; Codex's is read from a file.
        XCTAssertEqual(Claude().statusLineUsage?.path, "/usage/claude")
        XCTAssertNil(Codex().statusLineUsage?.path)
        XCTAssertEqual(dispatch("POST", "/usage/codex"), .notFound)
    }

    /// A side-effecting endpoint is POST-only, and that is what makes the
    /// `Origin` rule hold: a browser's no-cors request carries no `Origin`, but
    /// it can only be a GET.
    func testHookRoutesAreReachedByPOSTOnly() {
        for source in Agents.all {
            XCTAssertEqual(dispatch("GET", source.hookPath), .notFound, source.id.rawValue)
        }
        XCTAssertEqual(dispatch("GET", "/hook/claude"), .notFound)
    }

    /// Each agent's approvals come in on its own path, so the listener
    /// knows who asks without reading the body: this Mac's listener and a
    /// machine's hold both, a sandbox's neither.
    func testEachApprovalPathIsItsAgents() {
        XCTAssertEqual(dispatch("POST", "/approval"), .approval(.claude))
        XCTAssertEqual(dispatch("POST", "/approval/codex"), .approval(.codex))
        XCTAssertEqual(dispatch("GET", "/approval/codex"), .notFound)
        XCTAssertEqual(dispatch("POST", "/approval/antigravity"), .notFound, "no approvals, no route")
        let body = #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        for (path, agent) in [("/approval", AgentID.claude), ("/approval/codex", .codex)] {
            for origin in [LocalAPI.Origin.local, .machine] {
                let outcome = LocalAPI.handleAsTheApp(HTTPRequest(method: "POST", target: path, body: Data(body.utf8),
                                                                  host: "127.0.0.1:48151"),
                                                      listener: LocalAPI.Listener(origin: origin))
                XCTAssertNil(outcome.response, "\(path) \(origin): held")
                guard case .approval(let held)? = outcome.delivery else { XCTFail("\(path) \(origin)"); continue }
                XCTAssertEqual(held.source, agent, "\(path) \(origin)")
            }
            let sandboxed = LocalAPI.handleAsTheApp(HTTPRequest(method: "POST", target: path, body: Data(body.utf8),
                                                                host: "127.0.0.1:48151"),
                                                    listener: LocalAPI.Listener(origin: .sandbox))
            XCTAssertEqual(sandboxed.response?.status, .notFound, path)
            XCTAssertNil(sandboxed.delivery, path)
        }
    }

    // MARK: - The answers

    func testTheCodexRouteStampsTheEventWithItsSource() {
        let outcome = post("/hook/codex", body: #"{"hook_event_name":"Interrupt","session_id":"c-1"}"#)
        XCTAssertEqual(outcome.response?.body, "{}")
        XCTAssertEqual(outcome.event?.source, .codex)
        XCTAssertEqual(outcome.event?.name, "Stop", "the adapter runs before the typed view")
    }

    /// A bubble turn's own hooks carry its task id: the Codex server runs the
    /// user's hooks too (measured), and their events open no row — the same
    /// exclusion a Claude turn's get.
    func testABubbleTurnsCodexEventOpensNoRow() throws {
        let provider = HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in nil },
                                                        now: Date.init),
                                     isQuestion: Agents.isQuestion)
        let body = #"{"hook_event_name":"UserPromptSubmit","session_id":"thr-1","cwd":"/tmp/p"}"#
        let errand = try XCTUnwrap(post("/hook/codex", body: body, taskID: "chat-1", pid: "4242").event)
        XCTAssertEqual(errand.source, .codex)
        provider.handle(errand)
        XCTAssertTrue(provider.currentSignals().isEmpty, "a bubble turn's event must not become a row")
        provider.handle(try XCTUnwrap(post("/hook/codex", body: body, pid: "4242").event))
        XCTAssertEqual(provider.currentSignals().map(\.phase), [.working], "the user's own session still does")
    }

    // MARK: - The installed command

    /// **The golden string.** The command below is what sits in the user's
    /// `~/.claude/settings.json` and `~/.codex/hooks.json` once installed,
    /// and on a server the same. The literals are written out by hand, path
    /// and socket included, precisely so that a change anywhere in the
    /// derivation — `hookPath`, `relativePath`, a header name, a shell
    /// quote — breaks here instead of in a session that silently stops
    /// reporting.
    func testTheInstalledHookCommandIsUnchanged() {
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .claude),
            "curl -q -s -m 2 --noproxy '*' --unix-socket \"$HOME/.config/evlat/run/evlat.sock\" -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true")
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .codex),
            "curl -q -s -m 2 --noproxy '*' --unix-socket \"$HOME/.config/evlat/run/evlat.sock\" -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook/codex >/dev/null 2>&1 || true")
    }

    /// The bytes before the socket, as every copy of Evlat until it wrote
    /// the ones above: what a card reads as Evlat's older command
    /// (`HookSettingsTests`), never as someone else's.
    static let tcpCommand = [
        "claude": "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true",
        "codex": "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\" --data-binary @- http://127.0.0.1:48151/hook/codex >/dev/null 2>&1 || true",
    ]

    /// A shell runs the installed command as a hook would: the body on
    /// stdin, the socket found under `$HOME`. It reaches the listener with
    /// its headers and the body byte for byte, prints nothing and exits 0.
    func testTheInstalledCommandReachesTheSocketUnderTheHome() throws {
        let home = try SocketHome()
        defer { home.remove() }
        let listener = try home.listen()
        let body = Data(#"{"session_id":"s","hook_event_name":"Stop","note":"it's"}"#.utf8)
        let result = try runHook(LocalAPI.installedHookCommand(for: .codex), body: body, home: home)
        XCTAssertEqual(result.output, Data(), "nothing on stdout or stderr")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(listener.body(), body)
        let head = try XCTUnwrap(listener.requestHead())
        XCTAssertTrue(head.hasPrefix("POST /hook/codex HTTP/1.1"), head)
        XCTAssertTrue(head.contains("Host: 127.0.0.1:48151"), "a host the route reads as loopback")
        XCTAssertTrue(head.contains("X-Evlat-Pid: "), head)
    }

    /// No socket — Evlat closed, or never on this machine — and a socket
    /// that never answers: silent, exit 0, and within the command's own
    /// bound.
    func testTheInstalledCommandIsSilentAndQuickWithoutEvlat() throws {
        let home = try SocketHome()
        defer { home.remove() }
        let command = LocalAPI.installedHookCommand(for: .claude)
        let missing = try runHook(command, body: Data("{}".utf8), home: home)
        XCTAssertEqual(missing.output, Data())
        XCTAssertEqual(missing.status, 0)
        XCTAssertLessThan(missing.seconds, 1, "no socket fails at once")
        let silent = try home.listen(answer: false)
        defer { silent.close() }
        let held = try runHook(command, body: Data("{}".utf8), home: home)
        XCTAssertEqual(held.output, Data())
        XCTAssertEqual(held.status, 0)
        XCTAssertLessThan(held.seconds, 4, "`-m 2` bounds a socket that never answers")
    }

    private struct HookRun { let output: Data; let status: Int32; let seconds: TimeInterval }

    /// `sh -c <command>` with `body` on stdin, stdout and stderr together.
    private func runHook(_ command: String, body: Data, home: SocketHome) throws -> HookRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = home.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(body)
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return HookRun(output: printed, status: process.terminationStatus, seconds: Date().timeIntervalSince(start))
    }

    /// What the command promises about itself: it stays silent, it gives up
    /// quickly, and it never fails the hook. The answer is not fed back to
    /// Claude Code, and `curl` waiting on a closed Evlat would stall the agent.
    func testTheInstalledCommandFailsSilently() {
        for source in Agents.all {
            let command = LocalAPI.installedHookCommand(for: source)
            XCTAssertTrue(command.contains("|| true"), source.id.rawValue)
            XCTAssertTrue(command.contains("-m 2"), source.id.rawValue)
            XCTAssertTrue(command.contains(">/dev/null 2>&1"), source.id.rawValue)
            XCTAssertTrue(command.contains("http://127.0.0.1:\(LocalAPI.defaultPort)\(source.hookPath) "), source.id.rawValue)
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
