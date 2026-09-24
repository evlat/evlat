import XCTest
@testable import EvlatCore

/// A chat turn's permission hook: the settings it starts with, the request it
/// posts, the decision that goes back — and that nothing but a rule or a
/// folder, for this session, is ever granted through it.
final class PermissionHookTests: XCTestCase {
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testTheSettingsCarryOneHttpHookOnTheBoundPort() throws {
        let text = PermissionHook.settings(port: 48999, token: "T-1")
        XCTAssertEqual(text, #"{"hooks":{"PermissionRequest":[{"hooks":[{"headers":{"X-Evlat-Permission":"T-1"},"#
                       + #""timeout":600,"type":"http","url":"http://127.0.0.1:48999/permission"}],"matcher":"*"}]}}"#)
        XCTAssertEqual(PermissionHook.Endpoint(port: 48999, token: "T-1").settings, text)
        // The token is a plain value: nothing in it for the header's
        // `$VAR` interpolation to expand.
        XCTAssertFalse(text.contains("$"))
    }

    private let body = #"""
    {"session_id":"S1","hook_event_name":"PermissionRequest","cwd":"/p","tool_name":"Bash",
     "tool_input":{"command":"mkdir out","description":"Make it"},
     "permission_suggestions":[
       {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkdir:*"},{"toolName":"Bash","ruleContent":"mkdir:*"}],"behavior":"allow","destination":"localSettings"},
       {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"deny","destination":"session"},
       {"type":"setMode","mode":"acceptEdits","destination":"session"},
       {"type":"addDirectories","directories":["/elsewhere"],"destination":"session"}]}
    """#

    func testTheRequestKeepsOnlyAllowRulesAndFolders() throws {
        let request = try XCTUnwrap(PermissionHook.Request(json: object(body), token: "T-1", id: "R1"))
        XCTAssertEqual(request.id, "R1")
        XCTAssertEqual(request.token, "T-1")
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.subject, HookEvent.subject(of: ["command": "mkdir out", "description": "Make it"]))
        XCTAssertEqual(request.rules, [PermissionHook.Rule(toolName: "Bash", ruleContent: "mkdir:*")],
                       "a deny rule and `setMode` are not offered; a repeated rule once")
        XCTAssertEqual(request.directories, ["/elsewhere"])
        XCTAssertEqual(request.sessionID, "S1")
        XCTAssertEqual(request.cwd, "/p")
        XCTAssertEqual(request.rules.map(\.text), ["Bash(mkdir:*)"])
        XCTAssertEqual(PermissionHook.Rule(toolName: "Write").text, "Write")
    }

    func testABodyThatIsNotAPermissionRequestIsRefused() throws {
        XCTAssertNil(PermissionHook.Request(json: try object(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#),
                                            token: "T"))
        XCTAssertNil(PermissionHook.Request(json: try object(#"{"hook_event_name":"PermissionRequest"}"#), token: "T"))
    }

    func testAnAllowGrantsOnlyRulesAndFoldersForTheSession() throws {
        let body = PermissionHook.body(.allow(rules: [.init(toolName: "Bash", ruleContent: "mkdir:*")],
                                              directories: ["/elsewhere"]))
        let json = try object(body)
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updates = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(updates.compactMap { $0["type"] as? String }, ["addRules", "addDirectories"])
        XCTAssertEqual(Set(updates.compactMap { $0["destination"] as? String }), ["session"],
                       "never the user's settings files")
        XCTAssertEqual(updates[0]["behavior"] as? String, "allow")
        XCTAssertEqual((updates[0]["rules"] as? [[String: String]])?.first,
                       ["toolName": "Bash", "ruleContent": "mkdir:*"])
        XCTAssertEqual(updates[1]["directories"] as? [String], ["/elsewhere"])
    }

    func testAPlainAllowGrantsNothingMore() {
        XCTAssertEqual(PermissionHook.body(.allow(rules: [], directories: [])),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }

    func testADenialAndAStop() throws {
        let denied = try object(PermissionHook.body(.deny(interrupt: false)))
        let decision = (denied["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertNil(decision?["interrupt"])
        XCTAssertNotNil(decision?["message"])
        let stopped = try object(PermissionHook.body(.deny(interrupt: true)))
        let stop = (stopped["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(stop?["interrupt"] as? Bool, true, "a stop ends Claude's turn too")
    }
}
