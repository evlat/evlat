import XCTest
@testable import EvlatCore

/// The arguments and input one `claude -p` turn is started with. The flag
/// set is the one measured on 2.1.281; `--verbose` is not
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
    func testAParentSessionsMarkersAreNotInherited() {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: false,
                                         prompt: "hi", attachments: [], directory: "/tmp/p")
        let inherited = ["CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
                         "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/s", "CLAUDE_PID": "1",
                         "CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/bin", "EVLAT_TASK": "old"]
        XCTAssertEqual(call.environment(inheriting: inherited),
                       ["CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/bin", "EVLAT_TASK": "C1"],
                       "a turn started from inside Claude Code is not its child; user settings pass")
    }

    func testEveryTurnNamesItsMode() {
        XCTAssertEqual(PermissionMode.standard, .auto)
        XCTAssertEqual(PermissionMode.allCases.map(\.rawValue), ["default", "auto", "acceptEdits", "bypassPermissions"],
                       "the CLI's values; no dontAsk")
        for mode in PermissionMode.allCases {
            for resume in [false, true] {
                let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: resume, prompt: "hi",
                                                 attachments: [], directory: "/tmp/p", mode: mode)
                let at = try? XCTUnwrap(call.arguments.firstIndex(of: "--permission-mode"))
                XCTAssertEqual(at.map { call.arguments[$0 + 1] }, mode.rawValue)
                XCTAssertEqual(call.arguments.filter { $0 == "--permission-mode" }.count, 1)
            }
        }
        XCTAssertEqual(PermissionMode(stored: "bypassPermissions"), .bypass)
        XCTAssertNil(PermissionMode(stored: "dontAsk"), "a mode this build does not offer falls back")
        XCTAssertNil(PermissionMode(stored: nil))
        XCTAssertEqual(PermissionMode(stored: "default"), .ask)
    }

    /// Bypass is only ever the chat's own mode flag, by its mode name — never
    /// `--dangerously-skip-permissions` — and a started bypass turn still
    /// carries the ask rules and the hook that turns them into cards.
    func testABypassTurnKeepsTheAskRulesAndItsHook() throws {
        let call = ClaudeInvocation.turn(chatID: "C1", sessionID: "S1", resume: false, prompt: "hi",
                                         attachments: [], directory: "/tmp/p", mode: .bypass)
        let at = try XCTUnwrap(call.arguments.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(call.arguments[at + 1], "bypassPermissions")
        XCTAssertFalse(call.arguments.contains { $0.hasPrefix("--dangerously") || $0.hasPrefix("--allow-dangerously") })
        let endpoint = PermissionHook.Endpoint(port: 48999, token: "T")
        let asking = call.asking(endpoint)
        XCTAssertEqual(Array(asking.arguments.suffix(4)), ["--permission-prompts", "none", "--settings", endpoint.settings])
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(endpoint.settings.utf8)) as? [String: Any])
        XCTAssertEqual((settings["permissions"] as? [String: Any])?["ask"] as? [String], PermissionHook.askRules)
    }

    /// Only bypass asks before it is picked, and only bypass is never a
    /// default: Settings and Setup offer every other mode, recommended first.
    func testOnlyBypassAsksAndIsNeverADefault() {
        XCTAssertEqual(PermissionMode.allCases.filter(\.asksBeforePicking), [.bypass])
        XCTAssertEqual(PermissionMode.allCases.filter { !$0.mayBeDefault }, [.bypass])
        XCTAssertEqual(PermissionMode.offered.first, .standard)
        XCTAssertEqual(Set(PermissionMode.offered), Set(PermissionMode.allCases.filter(\.mayBeDefault)))
        XCTAssertEqual(PermissionMode.offered.count, PermissionMode.allCases.count - 1)
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
    /// inline hook decides.
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
