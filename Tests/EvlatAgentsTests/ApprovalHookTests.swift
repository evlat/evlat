import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The approval hook's contract: the one group it installs, the route, and
/// the rule that tells a request answered in the terminal. Files live under
/// a temporary home; nothing here reaches the user's `~/.claude`.
final class ApprovalHookTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: Claude().hooksFile(home: home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var file: URL { Claude().hooksFile(home: home) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func groups(_ settings: [String: Any]) -> [Any] {
        (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] ?? []
    }

    // MARK: - The installed hook

    private var channel: any ApprovalChannel { Claude().approvals! }

    /// The installed contract, byte for byte: a command hook that speaks to
    /// the socket under the home it runs in — this Mac's or a server's —
    /// and prints the decision, and only the decision, on stdout. The
    /// timeout is one constant in three places: the hook's, `curl`'s, the
    /// card's.
    func testTheInstalledHookIsUnchanged() throws {
        let data = try JSONSerialization.data(withJSONObject: ApprovalHook.installedHook(for: channel),
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"command":"curl -q -sf --noproxy '*' --unix-socket \"$HOME/.config/evlat/run/evlat.sock\" -m 600 -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:48151/approval 2>/dev/null || true","timeout":600,"type":"command"}"#)
        XCTAssertEqual(channel.timeout, 600)
        XCTAssertEqual(channel.path, ApprovalHook.path)
    }

    /// Whatever goes wrong is no decision: `-f` writes no error body,
    /// `|| true` exits 0, and nothing but `curl`'s stdout reaches the agent.
    func testTheInstalledCommandPrintsOnlyTheDecision() throws {
        let command = ApprovalHook.command(for: channel)
        XCTAssertTrue(command.hasSuffix(" 2>/dev/null || true"))
        XCTAssertFalse(command.contains(">/dev/null 2>&1"), "stdout is the answer")
        XCTAssertTrue(command.contains(" -sf "))
        XCTAssertTrue(command.contains(" -m \(channel.timeout) "))
        let home = try SocketHome()
        defer { home.remove() }
        let missing = try run(command, home: home)
        XCTAssertEqual(missing.output, Data(), "no socket: empty stdout")
        XCTAssertEqual(missing.status, 0)
        let answering = try home.listen()
        defer { answering.close() }
        let answered = try run(command, home: home)
        XCTAssertEqual(String(decoding: answered.output, as: UTF8.self), "{}",
                       "`{}`, the server's no-decision, passes as it is: the agent's dialog decides")
        XCTAssertEqual(answered.status, 0)
    }

    private func run(_ command: String, home: SocketHome) throws -> (output: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = home.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(body.utf8))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (printed, process.terminationStatus)
    }

    /// One row, one write: this Mac's Claude hooks are the command and the
    /// approval hook together, and neither alone reads current.
    func testLocalHooksInstallBothBesideOthers() throws {
        try Data(#"{"model":"opus","hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"/usr/local/bin/other notify"}]}]}}"#.utf8).write(to: file)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .missing)
        try HookSettings.install(at: file, for: .claude)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .outdated,
                       "the command alone, as every copy before approvals wrote it: one install completes it")
        try LocalHooks.install(at: file, for: .claude)
        let settings = try json(file)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(groups(settings).count, 3, "the other tool's, the command's and ours")
        XCTAssertEqual(((groups(settings)[0] as? [String: Any])?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "/usr/local/bin/other notify", "another tool's group keeps its index")
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current)
        XCTAssertEqual(try HookSettings.state(at: file, for: .claude), .current,
                       "the command hook does not read ours as a duplicate")
        XCTAssertEqual(ApprovalHook.state(of: HookSettings.installing(into: [:], for: .claude), for: channel), .missing,
                       "nor ours the command")
        XCTAssertEqual(try LocalHooks.install(at: file, for: .claude), .unchanged, "a second install adds nothing")
        XCTAssertEqual(groups(try json(file)).count, 3)
    }

    func testLocalHooksRemoveBothAndLeaveOthers() throws {
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#.utf8).write(to: file)
        try LocalHooks.install(at: file, for: .claude)
        try LocalHooks.remove(at: file, for: .claude)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .missing)
        XCTAssertEqual(groups(try json(file)).count, 0)
        XCTAssertEqual(((try json(file))["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] != nil, true)
    }

    /// Every copy before the socket installed an http hook on the port.
    /// It is Evlat's older one: outdated, replaced in place by the command,
    /// and taken out by a removal like the command.
    private var oldHTTP: [String: Any] {
        ["type": "http", "url": "http://127.0.0.1:48151/approval", "timeout": 600]
    }

    func testTheOldHTTPHookIsEvlatsOlderOne() throws {
        let other: [String: Any] = ["hooks": [["type": "command", "command": "/usr/local/bin/other"]]]
        let old: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [oldHTTP]], other]]]
        XCTAssertEqual(ApprovalHook.state(of: old, for: channel), .outdated)
        let installed = ApprovalHook.installing(into: old, for: channel)
        XCTAssertEqual(ApprovalHook.state(of: installed, for: channel), .current)
        let after = groups(installed)
        XCTAssertEqual(after.count, 2, "in place, not beside it")
        XCTAssertEqual(((after[0] as? [String: Any])?["hooks"] as? [[String: Any]])?.first?["type"] as? String,
                       "command", "the old one's index")
        XCTAssertEqual(((after[1] as? [String: Any])?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "/usr/local/bin/other", "another tool's group is left")
        let removed = ApprovalHook.removing(from: old, for: channel)
        XCTAssertEqual(ApprovalHook.state(of: removed, for: channel), .missing)
        XCTAssertEqual(groups(removed).count, 1)
        let both: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [oldHTTP]],
                                                                   ["hooks": [ApprovalHook.installedHook(for: channel)]]]]]
        XCTAssertEqual(ApprovalHook.state(of: both, for: channel), .outdated)
        XCTAssertEqual(groups(ApprovalHook.installing(into: both, for: channel)).count, 1, "folded into one")
        XCTAssertEqual(groups(ApprovalHook.removing(from: both, for: channel)).count, 0, "both go")
    }

    /// Another tool's hook in the same group as ours stays, with the
    /// group's `matcher`, through an install and a removal.
    func testAnotherHookInOurGroupIsLeftAlone() {
        let audit: [String: Any] = ["type": "command", "command": "/usr/local/bin/audit"]
        let shared: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [oldHTTP, audit]]]]]
        let installed = ApprovalHook.installing(into: shared, for: channel)
        XCTAssertEqual(ApprovalHook.state(of: installed, for: channel), .current)
        let group = groups(installed).first as? [String: Any]
        XCTAssertEqual(group?["matcher"] as? String, "*")
        XCTAssertEqual((group?["hooks"] as? [[String: Any]])?.map { $0["type"] as? String ?? "" }, ["command", "command"])
        XCTAssertEqual((group?["hooks"] as? [[String: Any]])?.last?["command"] as? String, "/usr/local/bin/audit")
        let removed = ApprovalHook.removing(from: installed, for: channel)
        XCTAssertEqual(ApprovalHook.state(of: removed, for: channel), .missing)
        XCTAssertEqual(((groups(removed).first as? [String: Any])?["hooks"] as? [[String: Any]])?.count, 1,
                       "the audit hook stays")
    }

    /// The approval hook goes wherever the agent's channel says: Claude's
    /// on this Mac and on a server, Codex's nowhere here.
    func testTheTargetDecidesWhetherTheGroupGoes() {
        XCTAssertEqual(channel.installs, [.mac, .server])
        XCTAssertEqual(ApprovalHook.state(of: LocalHooks.installing(into: [:], for: .claude, target: .server),
                                          for: channel), .current)
        XCTAssertEqual(LocalHooks.installing(into: [:], for: .codex, target: .mac) as NSDictionary,
                       HookSettings.installing(into: [:], for: .codex) as NSDictionary)
        XCTAssertTrue(LocalHooks.manual(for: .claude).contains("/approval"))
        XCTAssertTrue(RemoteSettings.manual(agents: Agents.all).hooks(for: .claude).contains("/approval"))
    }

    func testAnOtherTimeoutOrTwoCopiesReadOutdated() {
        var other = ApprovalHook.installedHook(for: channel)
        other["timeout"] = 30
        let once: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [other]]]]]
        XCTAssertEqual(ApprovalHook.state(of: once, for: channel), .outdated)
        let ours: [String: Any] = ["hooks": [ApprovalHook.installedHook(for: channel)]]
        let twice: [String: Any] = ["hooks": ["PermissionRequest": [ours, ours]]]
        XCTAssertEqual(ApprovalHook.state(of: twice, for: channel), .outdated)
        XCTAssertEqual(ApprovalHook.state(of: ApprovalHook.installing(into: twice, for: channel), for: channel), .current)
    }

    // MARK: - The route

    private let body = #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"rm -r build"}}"#

    private func post(_ body: String, origin: LocalAPI.Origin = .local, browser: String? = nil) -> LocalAPI.Outcome {
        LocalAPI.handleAsTheApp(HTTPRequest(method: "POST", target: "/approval", body: Data(body.utf8),
                                    origin: browser, host: "127.0.0.1:48151"),
                        listener: LocalAPI.Listener(origin: origin))
    }

    func testARequestIsHeldWithoutAToken() {
        let outcome = post(body)
        XCTAssertNil(outcome.response, "the answer is the user's, or the terminal's")
        guard case .approval(let request)? = outcome.delivery else { return XCTFail("no request") }
        XCTAssertEqual(request.sessionID, "s-1")
        XCTAssertEqual(request.command, "rm -r build")
        XCTAssertNil(request.token)
        XCTAssertEqual(request.source, .claude)
    }

    /// A machine's listener holds it like this Mac's; a sandbox's has hooks
    /// only, and a browser nothing.
    func testAMachineReachesItAndASandboxOrABrowserNever() {
        guard case .approval(let request)? = post(body, origin: .machine).delivery else { return XCTFail("no request") }
        XCTAssertNil(post(body, origin: .machine).response, "held")
        XCTAssertEqual(request.source, .claude, "the route's agent, never the body's")
        XCTAssertNil(request.machine, "the machine is the listener's to stamp, not the core's")
        XCTAssertEqual(post(body, origin: .sandbox).response?.status, .notFound)
        XCTAssertNil(post(body, origin: .sandbox).delivery)
        XCTAssertEqual(post(body, browser: "https://example.com").response?.status, .forbidden)
    }

    /// A body Evlat cannot put on a card is no decision: `{}`, and the
    /// terminal's dialog decides.
    func testAnUnreadableRequestIsNoDecision() {
        for bad in ["not json", #"{"tool_name":"Bash"}"#, #"{"session_id":"s-1"}"#] {
            let outcome = post(bad)
            XCTAssertEqual(outcome.response, LocalAPI.Response(status: .ok, body: "{}"), bad)
            XCTAssertNil(outcome.delivery, bad)
        }
    }

    // MARK: - Answered elsewhere

    private func request(agent: String? = nil) -> HeldRequest {
        HeldRequest(id: "r-1", token: nil, tool: "Bash", subject: "rm -r build",
                               command: "rm -r build", sessionID: "s-1", subagent: agent)
    }

    private func event(_ name: String, session: String = "s-1", agent: String? = nil,
                       tool: String? = "Bash", command: String = "rm -r build") -> HookEvent {
        var json: [String: Any] = ["hook_event_name": name, "session_id": session,
                                   "tool_input": ["command": command]]
        if let agent { json["agent_id"] = agent }
        if let tool { json["tool_name"] = tool }
        return HookEvent(json: json)
    }

    /// "Yes" in the terminal leaves the connection open (measured): the
    /// tool's outcome is what says so.
    func testTheToolsOutcomeResolvesIt() {
        XCTAssertTrue(ApprovalHook.resolves(request(), by: event("PostToolUse")))
        XCTAssertTrue(ApprovalHook.resolves(request(), by: event("PostToolUseFailure")))
        XCTAssertFalse(ApprovalHook.resolves(request(), by: event("PostToolUse", command: "ls")),
                       "another tool call")
        XCTAssertFalse(ApprovalHook.resolves(request(), by: event("PostToolUse", agent: "a-1")),
                       "a subagent shares the session, not the request")
        XCTAssertFalse(ApprovalHook.resolves(request(), by: event("PostToolUse", session: "s-2")))
    }

    func testTheTurnsEndResolvesIt() {
        for name in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"] {
            XCTAssertTrue(ApprovalHook.resolves(request(agent: "a-1"), by: event(name, tool: nil)), name)
        }
    }

    /// The installed command posts the same request's `PermissionRequest`
    /// too, at any moment; nor does a tool's start or a notification answer
    /// anything.
    func testNothingBeforeTheAnswerResolvesIt() {
        for name in ["PermissionRequest", "Notification", "PreToolUse"] {
            XCTAssertFalse(ApprovalHook.resolves(request(), by: event(name)), name)
        }
    }

    func testANewerRequestFromTheSameActorSupersedes() {
        let newer = HeldRequest(id: "r-2", token: nil, tool: "Bash", subject: "ls", sessionID: "s-1")
        XCTAssertTrue(ApprovalHook.supersedes(newer, request()))
        XCTAssertFalse(ApprovalHook.supersedes(newer, request(agent: "a-1")))
        XCTAssertFalse(ApprovalHook.supersedes(request(), request()))
    }

    /// A request is its machine's: the same session id heard from another
    /// computer, or from this Mac, answers nothing of it, nor replaces it.
    func testOnlyTheSameMachineResolvesOrSupersedes() {
        var remote = request()
        remote.machine = "m-a"
        XCTAssertTrue(ApprovalHook.resolves(remote, by: event("Stop", tool: nil), machine: "m-a"))
        XCTAssertFalse(ApprovalHook.resolves(remote, by: event("Stop", tool: nil), machine: "m-b"))
        XCTAssertFalse(ApprovalHook.resolves(remote, by: event("Stop", tool: nil), machine: nil))
        XCTAssertFalse(ApprovalHook.resolves(request(), by: event("Stop", tool: nil), machine: "m-a"))
        var newer = HeldRequest(id: "r-2", token: nil, tool: "Bash", subject: "ls", sessionID: "s-1")
        XCTAssertFalse(ApprovalHook.supersedes(newer, remote), "this Mac's does not replace a machine's")
        newer.machine = "m-a"
        XCTAssertTrue(ApprovalHook.supersedes(newer, remote))
    }
}
