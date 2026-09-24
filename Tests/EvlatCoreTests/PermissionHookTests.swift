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
                       + #""timeout":600,"type":"http","url":"http://127.0.0.1:48999/permission"}],"matcher":"*"}]},"#
                       + #""permissions":{"ask":["Bash(rm:*)","Bash(rmdir:*)","Bash(sudo:*)","Bash(git push:*)","#
                       + #""Bash(git reset --hard:*)","Bash(chmod:*)","Bash(chown:*)","Bash(kill:*)","Bash(killall:*)"]}}"#)
        XCTAssertEqual(PermissionHook.Endpoint(port: 48999, token: "T-1").settings, text)
        // The token is a plain value: nothing in it for the header's
        // `$VAR` interpolation to expand.
        XCTAssertFalse(text.contains("$"))
    }

    /// A workspace chat's settings name Evlat's one memory folder; without
    /// it the key is not there at all (the string above).
    func testTheSettingsCarryTheMemoryFolderWhenGiven() throws {
        let settings = try object(PermissionHook.settings(port: 1, token: "T",
                                                          memoryDirectory: "/Users/a/Library/Application Support/Evlat/memory"))
        XCTAssertEqual(settings["autoMemoryDirectory"] as? String, "/Users/a/Library/Application Support/Evlat/memory")
        XCTAssertNotNil(settings["hooks"])
        XCTAssertNil(try object(PermissionHook.settings(port: 1, token: "T"))["autoMemoryDirectory"])
    }

    /// What cannot be undone asks in every mode: the turn's own settings
    /// carry the rules — `permissions.ask`, nothing allowed or denied — and
    /// each is a prefix rule whose `:*` ends it (the only place the form is
    /// read as a wildcard).
    func testTheSettingsAskBeforeWhatCannotBeUndone() throws {
        let settings = try object(PermissionHook.settings(port: 1, token: "T"))
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertEqual(Array(permissions.keys), ["ask"])
        let ask = try XCTUnwrap(permissions["ask"] as? [String])
        XCTAssertEqual(ask, PermissionHook.askRules)
        for command in ["rm", "rmdir", "sudo", "git push", "git reset --hard", "chmod", "chown", "kill", "killall"] {
            XCTAssertTrue(ask.contains("Bash(\(command):*)"), command)
        }
        for rule in ask {
            XCTAssertTrue(rule.hasPrefix("Bash(") && rule.hasSuffix(":*)"), rule)
            XCTAssertEqual(rule.components(separatedBy: ":*").count, 2, "\(rule): one wildcard, at the end")
        }
    }

    /// "Always" for a command an ask rule covers would be kept and never
    /// take effect (ask beats allow): it is not offered.
    func testASuggestionAnAskRuleOverrulesIsNotOffered() throws {
        for content in ["rm:*", "rm -r build:*", "rm *", "git push:*", "git push origin main", "sudo", "kill -9 12"] {
            XCTAssertTrue(PermissionHook.isOverruled(.init(toolName: "Bash", ruleContent: content)), content)
        }
        for content in ["rmx:*", "git pull:*", "npm run:*", "killer"] {
            XCTAssertFalse(PermissionHook.isOverruled(.init(toolName: "Bash", ruleContent: content)), content)
        }
        XCTAssertFalse(PermissionHook.isOverruled(.init(toolName: "Bash")))
        XCTAssertFalse(PermissionHook.isOverruled(.init(toolName: "Write", ruleContent: "rm:*")))
        let json = try object(#"{"tool_name":"Bash","tool_input":{"command":"rm -r build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -r build:*"},{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow","destination":"session"}]}"#)
        XCTAssertEqual(PermissionHook.Request(json: json, token: "T", id: "R")?.rules,
                       [.init(toolName: "Bash", ruleContent: "ls:*")])
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
