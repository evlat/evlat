import XCTest
@testable import EvlatCore

/// The arguments and input one `claude -p` turn is started with. The flag
/// set is the one measured on 2.1.281 (`011/phase-1`); `--verbose` is not
/// optional there, stream-json output refuses to run without it.
final class ClaudeInvocationTests: XCTestCase {
    func testTheFirstTurnNamesTheSession() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: false,
                                         prompt: "hi", attachments: [], directory: "/tmp/p")
        XCTAssertEqual(call.arguments, [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-mode", "auto", "--session-id", "S1",
        ])
        XCTAssertEqual(call.directory, "/tmp/p")
        XCTAssertEqual(call.environment, [ClaudeInvocation.taskVariable: "C1"])
        XCTAssertEqual(ClaudeInvocation.taskVariable, "EVLAT_TASK",
                       "the installed hook command reads this name (LocalAPI.installedHookCommand)")
    }

    /// Every turn names the chat's mode, a resumed one too: none of the
    /// modes that skip or deny every check can be named.
    func testEveryTurnNamesItsMode() {
        XCTAssertEqual(PermissionMode.standard, .auto)
        XCTAssertEqual(PermissionMode.allCases.map(\.rawValue), ["default", "auto", "acceptEdits"],
                       "the CLI's values; no bypassPermissions, no dontAsk")
        for mode in PermissionMode.allCases {
            for resume in [false, true] {
                let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: resume, prompt: "hi",
                                                 attachments: [], directory: "/tmp/p", mode: mode)
                let at = try? XCTUnwrap(call.arguments.firstIndex(of: "--permission-mode"))
                XCTAssertEqual(at.map { call.arguments[$0 + 1] }, mode.rawValue)
                XCTAssertEqual(call.arguments.filter { $0 == "--permission-mode" }.count, 1)
            }
        }
        XCTAssertNil(PermissionMode(stored: "bypassPermissions"))
        XCTAssertNil(PermissionMode(stored: nil))
        XCTAssertEqual(PermissionMode(stored: "default"), .ask)
    }

    func testALaterTurnResumes() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: true,
                                         prompt: "hi", attachments: [], directory: "/tmp/p")
        XCTAssertEqual(Array(call.arguments.suffix(2)), ["--resume", "S1"])
        XCTAssertFalse(call.arguments.contains("--session-id"))
    }

    /// Both flags take a list, so each value gets its own flag: a bare list
    /// would swallow whatever option came next.
    func testDirectoriesAndRulesEachGetTheirOwnFlag() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: true,
                                         prompt: "hi", attachments: [], directory: "/tmp/p",
                                         addDirectories: ["/a", "/b"], allowedTools: ["Bash(ls:*)"])
        XCTAssertEqual(Array(call.arguments.suffix(8)), [
            "--add-dir", "/a", "--add-dir", "/b", "--allowedTools", "Bash(ls:*)", "--resume", "S1",
        ])
    }

    /// A value that would read as an option never reaches the list
    /// flags: a folder must be absolute, a rule must not lead with `-`.
    func testAValueThatReadsAsAnOptionIsDropped() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: true,
                                         prompt: "hi", attachments: [], directory: "/tmp/p",
                                         addDirectories: ["--dangerously-skip-permissions", "rel", "/a"],
                                         allowedTools: ["--permission-mode=bypassPermissions", "", "Read"])
        XCTAssertEqual(Array(call.arguments.suffix(6)), [
            "--add-dir", "/a", "--allowedTools", "Read", "--resume", "S1",
        ])
        XCTAssertFalse(call.arguments.contains { $0.hasPrefix("--dangerously") || $0.hasPrefix("--permission-mode=") })
        XCTAssertEqual(call.arguments.filter { $0.hasPrefix("--permission-mode") }, ["--permission-mode"],
                       "only the chat's own mode flag")
    }

    /// A started turn asks through its own hook: nothing prompts, the
    /// inline hook decides (`phase-3`).
    func testAStartedTurnAsksThroughItsHook() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: false,
                                         prompt: "hi", attachments: [], directory: "/tmp/p")
        let endpoint = PermissionHook.Endpoint(port: 48999, token: "T")
        let asking = call.asking(endpoint)
        XCTAssertEqual(asking.arguments, call.arguments + ["--permission-prompts", "none",
                                                          "--settings", endpoint.settings])
        XCTAssertEqual(asking.input, call.input)
        XCTAssertEqual(asking.environment, call.environment, "the token is not in the environment")
        XCTAssertEqual(asking.directory, call.directory)
    }

    /// The documented user line, one line, newline-terminated.
    func testTheInputIsOneUserLine() throws {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: false,
                                         prompt: "say \"ok\"\nnow", attachments: ["/tmp/p/a.pdf"],
                                         directory: "/tmp/p")
        let text = try XCTUnwrap(String(data: call.input, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "one line, whatever the prompt holds")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.input) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "user")
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? String)
        XCTAssertTrue(content.hasPrefix("say \"ok\"\nnow"))
        XCTAssertTrue(content.contains("/tmp/p/a.pdf"))
    }
}
