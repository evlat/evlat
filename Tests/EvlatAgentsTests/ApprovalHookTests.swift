import XCTest
@testable import EvlatCore

/// The approval hook's contract: the one group it installs, the route, and
/// the rule that tells a request answered in the terminal. Files live under
/// a temporary home; nothing here reaches the user's `~/.claude`.
final class ApprovalHookTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: AgentSource.claude.configDirectory(home: home),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var file: URL { AgentSource.claude.settingsFile(home: home) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func groups(_ settings: [String: Any]) -> [Any] {
        (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] ?? []
    }

    // MARK: - The installed hook

    /// The second installed contract, byte for byte: an http hook on the
    /// fixed port, with its timeout written out.
    func testTheInstalledHookIsUnchanged() throws {
        let data = try JSONSerialization.data(withJSONObject: ApprovalHook.installedHook,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"timeout":600,"type":"http","url":"http://127.0.0.1:48151/approval"}"#)
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
        XCTAssertEqual(try LocalHooks.install(at: file, for: .claude), .unchanged)
    }

    func testLocalHooksRemoveBothAndLeaveOthers() throws {
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#.utf8).write(to: file)
        try LocalHooks.install(at: file, for: .claude)
        try LocalHooks.remove(at: file, for: .claude)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .missing)
        XCTAssertEqual(groups(try json(file)).count, 0)
        XCTAssertEqual(((try json(file))["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] != nil, true)
    }

    /// A server never gets the approval hook: its route is `404` through the
    /// tunnel, and Codex has none either.
    func testOnlyThisMacsClaudeHasIt() {
        XCTAssertEqual(ApprovalHook.state(of: HookSettings.installing(into: [:], for: .claude)), .missing,
                       "RemoteSettings writes HookSettings' bytes")
        XCTAssertEqual(LocalHooks.installing(into: [:], for: .codex, approvals: true) as NSDictionary,
                       HookSettings.installing(into: [:], for: .codex) as NSDictionary)
        XCTAssertTrue(LocalHooks.manual(for: .claude).contains("/approval"))
        XCTAssertFalse(RemoteSettings.manual.hooks(for: .claude).contains("/approval"))
    }

    func testAnOtherTimeoutOrTwoCopiesReadOutdated() {
        let other: [String: Any] = ["type": "http", "url": ApprovalHook.url, "timeout": 30]
        let once: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [other]]]]]
        XCTAssertEqual(ApprovalHook.state(of: once), .outdated)
        let ours: [String: Any] = ["hooks": [ApprovalHook.installedHook]]
        let twice: [String: Any] = ["hooks": ["PermissionRequest": [ours, ours]]]
        XCTAssertEqual(ApprovalHook.state(of: twice), .outdated)
        XCTAssertEqual(ApprovalHook.state(of: ApprovalHook.installing(into: twice)), .current)
    }

    // MARK: - The route

    private let body = #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"rm -r build"}}"#

    private func post(_ body: String, origin: LocalAPI.Origin = .local, browser: String? = nil) -> LocalAPI.Outcome {
        LocalAPI.handle(HTTPRequest(method: "POST", target: "/approval", body: Data(body.utf8),
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
    }

    func testATunnelOrABrowserNeverReachesIt() {
        XCTAssertEqual(post(body, origin: .tunneled).response?.status, .notFound)
        XCTAssertNil(post(body, origin: .tunneled).delivery)
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

    private func request(agent: String? = nil) -> PermissionHook.Request {
        PermissionHook.Request(id: "r-1", token: nil, tool: "Bash", subject: "rm -r build",
                               command: "rm -r build", sessionID: "s-1", agentID: agent)
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
        let newer = PermissionHook.Request(id: "r-2", token: nil, tool: "Bash", subject: "ls", sessionID: "s-1")
        XCTAssertTrue(ApprovalHook.supersedes(newer, request()))
        XCTAssertFalse(ApprovalHook.supersedes(newer, request(agent: "a-1")))
        XCTAssertFalse(ApprovalHook.supersedes(request(), request()))
    }
}
