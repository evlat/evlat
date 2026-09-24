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
            "--verbose", "--include-partial-messages", "--session-id", "S1",
        ])
        XCTAssertEqual(call.directory, "/tmp/p")
        XCTAssertEqual(call.environment, [ClaudeInvocation.taskVariable: "C1"])
        XCTAssertEqual(ClaudeInvocation.taskVariable, "EVLAT_TASK",
                       "the installed hook command reads this name (LocalAPI.installedHookCommand)")
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
