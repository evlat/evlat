import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// Claude Code as the chat's backend: the values that were stored or
/// installed before the bubble had backends stay what they were, and the
/// seam's calls give exactly what the chat chain gave before.
final class ClaudeChatTests: XCTestCase {
    private let chat = ClaudeChat()

    /// Stored before each backend had its own: the key, the file and the
    /// modes' ids (the CLI's values) cannot move.
    func testWhatWasStoredBeforeKeepsItsName() {
        XCTAssertEqual(chat.modeKey, "chat.permissionMode")
        XCTAssertEqual(chat.indexFile, "chats.json")
        XCTAssertEqual(chat.modes.map(\.id), ["default", "auto", "acceptEdits", "bypassPermissions"])
        XCTAssertEqual(chat.offered.map(\.id), ["auto", "acceptEdits", "default"])
        XCTAssertEqual(chat.standardMode.id, "auto")
        XCTAssertEqual(chat.executableVariable, "EVLAT_CLAUDE")
    }

    /// Only auto mode judges on its own, and what it turns down is retried
    /// in Ask mode; only bypass asks first and is never a default.
    func testTheModesValues() {
        XCTAssertEqual(chat.modes.map(\.retryDenialAs), [nil, "default", nil, nil])
        XCTAssertEqual(chat.modes.filter(\.asksBeforePicking).map(\.id), ["bypassPermissions"])
        XCTAssertEqual(chat.modes.filter { !$0.mayBeDefault }.map(\.id), ["bypassPermissions"])
        XCTAssertEqual(chat.modes.map(\.nameKey),
                       ["chat.mode.ask", "chat.mode.auto", "chat.mode.acceptEdits", "chat.mode.bypass"])
    }

    func testItIsOneWayAndAsksThroughTheListener() {
        XCTAssertEqual(chat.caps, ChatCapabilities(asks: true, alwaysOption: .rules, resume: true, memory: true,
                                                   transport: .oneWay))
        XCTAssertEqual(chat.stopPlan, .signal)
        XCTAssertEqual(Agents.chatBackends.map(\.id), [.claude, .codex], "the first is the chats' until one is chosen")
        XCTAssertEqual(Agents.routes.permission, .claude)
    }

    /// The launch is the invocation's, asking through its hook: the same
    /// arguments, line, environment and folder the chat chain started.
    func testTheTurnIsTheInvocationAskingThroughItsHook() {
        let spec = TurnSpec(chatID: "C1", sessionID: "S1", resume: true, prompt: "hi", attachments: ["/a"],
                            directory: "/tmp/p", addDirectories: ["/d"], allowedTools: ["Read"],
                            mode: PermissionMode.acceptEdits.chatMode)
        let launch = chat.turn(spec, ctx: TurnContext(socket: "/tmp/evlat-t/evlat.sock", token: "T", memoryDirectory: "/m"))
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: true, prompt: "hi",
                                         attachments: ["/a"], directory: "/tmp/p", addDirectories: ["/d"],
                                         allowedTools: ["Read"], mode: .acceptEdits)
            .asking(PermissionHook.Endpoint(socket: "/tmp/evlat-t/evlat.sock", token: "T"), memoryDirectory: "/m")
        XCTAssertEqual(launch.arguments, call.arguments)
        XCTAssertEqual(launch.input, [call.input])
        XCTAssertEqual(launch.environment, call.environment)
        XCTAssertEqual(launch.directory, call.directory)
        XCTAssertEqual(launch.removedEnvironment, ClaudeInvocation.parentSessionVariables)
    }

    /// The hook's body becomes the card's request, answered at the
    /// listener in the hook's own words.
    func testTheRequestAndItsAnswer() throws {
        let json: [String: Any] = [
            "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "mkdir out"],
            "permission_suggestions": [["type": "addRules", "behavior": "allow",
                                        "rules": [["toolName": "Bash", "ruleContent": "mkdir:*"]]]],
        ]
        let request = try XCTUnwrap(chat.request(json: json, token: "T-1"))
        XCTAssertEqual(request.token, "T-1")
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.subject, "mkdir out")
        XCTAssertEqual(request.rules, [PermissionRule(toolName: "Bash", ruleContent: "mkdir:*")])
        XCTAssertEqual(request.replyTarget, .listener)
        XCTAssertNil(chat.request(json: ["hook_event_name": "Stop", "tool_name": "Bash"], token: "T"))
        for decision: ChatDecision in [.allow(rules: request.rules, directories: []), .deny(interrupt: true)] {
            XCTAssertEqual(chat.encode(decision, for: request), .http(Data(PermissionHook.body(decision).utf8)))
        }
    }

    /// Claude's stream marks a card's answer and auto mode's judgement.
    func testTheStreamMarksTheDenialsTheChatTellsApart() {
        var parser = chat.parser(for: TurnSpec(chatID: "C", sessionID: "S", resume: false, prompt: "", attachments: [], directory: "/", mode: chat.standardMode))
        let lines = [#"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"a","decision_reason_type":"classifier"}"#,
                     #"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"b","decision_reason_type":"hook"}"#,
                     #"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"c","decision_reason_type":"rule"}"#]
        let read = parser.feed(Data(lines.map { $0 + "\n" }.joined().utf8))
        XCTAssertEqual(read.replies, [], "one way: nothing is written back")
        XCTAssertEqual(read.events, [
            .permissionDenied(.init(tool: "Bash", toolUseID: "a", reason: "classifier", retryable: true)),
            .permissionDenied(.init(tool: "Bash", toolUseID: "b", reason: "hook", answered: true)),
            .permissionDenied(.init(tool: "Bash", toolUseID: "c", reason: "rule")),
        ])
    }
}
