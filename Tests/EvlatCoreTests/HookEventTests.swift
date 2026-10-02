import XCTest
@testable import EvlatCore

/// The typed view of a hook body. Each agent's own dialect is translated
/// before it, by the agent (`HookChannel.canonical`).
final class HookEventTests: XCTestCase {
    func testReadsTheCanonicalFields() {
        let event = HookEvent(json: [
            "hook_event_name": "PermissionRequest",
            "session_id": "s-1",
            "cwd": "/tmp/project",
            "agent_id": "a-9",
            "notification_type": "permission_prompt",
            "stop_hook_active": true,
            HookEvent.taskKey: "build-42",
            HookEvent.pidKey: "7747",
        ])
        XCTAssertEqual(event.name, "PermissionRequest")
        XCTAssertEqual(event.sessionID, "s-1")
        XCTAssertEqual(event.cwd, "/tmp/project")
        XCTAssertEqual(event.agentID, "a-9")
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertTrue(event.stopHookActive)
        XCTAssertEqual(event.taskID, "build-42")
        XCTAssertEqual(event.pid, 7747)
        XCTAssertEqual(event.source, .test, "a fixture without a source is the test agent's")
    }

    /// A missing field is `nil`, never a stand-in. v1 called a session without
    /// an id `"unknown"`, which merged every such event onto one row.
    func testAMissingFieldIsNothing() {
        let event = HookEvent(json: ["hook_event_name": "Stop"])
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
        XCTAssertNil(event.agentID)
        XCTAssertNil(event.notificationType)
        XCTAssertNil(event.taskID)
        XCTAssertNil(event.pid)
        XCTAssertFalse(event.stopHookActive)
        XCTAssertEqual(HookEvent(json: [:]).name, "", "an event with no name matches no rule")
    }

    /// An empty value is as good as absent — `X-Evlat-Task: ${EVLAT_TASK:-}` is
    /// empty in the user's own sessions and must not read as a task named "".
    func testAnEmptyValueIsNothing() {
        let event = HookEvent(json: ["session_id": "", "cwd": "", HookEvent.taskKey: "", "agent_id": ""])
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
        XCTAssertNil(event.taskID)
        XCTAssertNil(event.agentID)
    }

    /// The pid arrives as text and a session's whereabouts are resolved from
    /// it. Anything that is not a plausible process is dropped: `1` is launchd,
    /// `0` the kernel, and neither ever ran an agent.
    func testThePidHasToBeAPlausibleProcess() {
        for text in ["", " ", "abc", "0", "1", "-7747", "7747.0", "99999999999999999999"] {
            XCTAssertNil(HookEvent(json: [HookEvent.pidKey: text]).pid, text)
        }
        XCTAssertEqual(HookEvent(json: [HookEvent.pidKey: "2"]).pid, 2)
        XCTAssertEqual(HookEvent(json: [HookEvent.pidKey: "7747"]).pid, 7747)
        XCTAssertNil(HookEvent(json: [HookEvent.pidKey: 7747]).pid, "the server writes it as text")
    }

    // MARK: - The card's fields

    /// `Bash` as measured (Claude Code 2.1.280): the command is the subject and
    /// the neighbouring `description` loses to it.
    func testABashToolsSubjectIsItsCommand() {
        let event = HookEvent(json: [
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": ["command": "swift test", "description": "Run the tests"],
        ])
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSubject, "swift test")
    }

    /// `Write` carries the whole file in `content`; the subject is the path and
    /// the content is not kept anywhere on the event.
    func testAWriteToolsSubjectIsItsPath() {
        let event = HookEvent(json: [
            "hook_event_name": "PermissionRequest", "tool_name": "Write",
            "tool_input": ["file_path": "/tmp/project/a.swift", "content": "secret body\nline 2"],
        ])
        XCTAssertEqual(event.toolSubject, "/tmp/project/a.swift")
        XCTAssertFalse(String(describing: event).contains("secret body"), "the raw input is not stored")
    }

    /// A tool whose input has none of the known keys has a name and no subject.
    func testAToolWithoutASubjectKeepsOnlyItsName() {
        let event = HookEvent(json: [
            "hook_event_name": "PreToolUse", "tool_name": "TodoWrite",
            "tool_input": ["todos": [["content": "x"]]],
        ])
        XCTAssertEqual(event.toolName, "TodoWrite")
        XCTAssertNil(event.toolSubject)
        XCTAssertNil(HookEvent(json: ["tool_name": "Bash", "tool_input": ["command": "  \n  "]]).toolSubject,
                     "a blank value is no subject")
    }

    /// A heredoc or a multi-line script is reduced to its first line, trimmed.
    func testAMultiLineCommandKeepsItsFirstLine() {
        let event = HookEvent(json: [
            "tool_name": "Bash", "tool_input": ["command": "  cat <<'EOF' > a.txt\nhello\nEOF"],
        ])
        XCTAssertEqual(event.toolSubject, "cat <<'EOF' > a.txt")
    }

    /// A shell line continuation is one line, as the shell reads it. Claude
    /// Code 2.1.281, measured from the balloon: a command opening with `\` +
    /// newline had a lone `\` for its subject — on the card that asked to run it.
    func testALineContinuationIsReadAsOneLine() {
        let command = "\\\nls -A old && \\\nrm old/a.tmp && \\\nrmdir old\nfind . | sort"
        let subject = HookEvent(json: ["tool_name": "Bash", "tool_input": ["command": command]]).toolSubject
        XCTAssertEqual(subject, "ls -A old && rm old/a.tmp && rmdir old")
        XCTAssertEqual(HookEvent.subject(of: ["command": "echo 'a\\\\'\nls"]), "echo 'a\\\\'",
                       "an escaped backslash at a line's end is no continuation")
    }

    /// The card's command is the whole of it, as written — only blank
    /// lines at either end go — and only `command` has one.
    func testTheFullCommandIsTheCommandAsWritten() {
        let command = "\n\\\nls -A old && \\\n  rm old/a.tmp\n\ncat <<'EOF' > f\na \\\nb\nEOF\n  \n"
        XCTAssertEqual(HookEvent.fullCommand(of: ["command": command]),
                       "\\\nls -A old && \\\n  rm old/a.tmp\n\ncat <<'EOF' > f\na \\\nb\nEOF")
        XCTAssertEqual(HookEvent.fullCommand(of: ["command": "mkdir out"]), "mkdir out")
        XCTAssertNil(HookEvent.fullCommand(of: ["file_path": "/tmp/a.txt"]), "a path is not a command")
        XCTAssertNil(HookEvent.fullCommand(of: ["command": " \n "]))
        let long = String(repeating: "x", count: 10_000) + "; rm -rf x"
        XCTAssertEqual(HookEvent.fullCommand(of: ["command": long]), long, "nothing is cut")
    }

    /// A single-line subject is capped too: a one-line script can be any size.
    func testASubjectIsCapped() {
        let long = String(repeating: "x", count: HookEvent.subjectLimit * 3)
        let subject = HookEvent(json: ["tool_name": "Bash", "tool_input": ["command": long]]).toolSubject
        XCTAssertLessThanOrEqual(subject?.count ?? 0, HookEvent.subjectLimit + 1)
    }

    /// `Stop`'s `last_assistant_message` is documented and was measured. Only
    /// its first paragraph is kept, and that is capped at a named limit.
    func testTheLastReplyIsAOneLinePreviewCapped() {
        let short = HookEvent(json: ["hook_event_name": "Stop",
                                     "last_assistant_message": "  Done: tests pass.\n\nDetails follow."])
        XCTAssertEqual(short.lastReply, "Done: tests pass. Details follow.", "what follows the first line stays")

        let long = String(repeating: "word ", count: HookEvent.replyLimit)
        let reply = HookEvent(json: ["hook_event_name": "Stop", "last_assistant_message": long]).lastReply
        XCTAssertNotNil(reply)
        XCTAssertLessThanOrEqual(reply?.count ?? .max, HookEvent.replyLimit + 1, "capped, plus the ellipsis")
        XCTAssertTrue(reply?.hasSuffix("…") ?? false, "a cut reply says it was cut")
        XCTAssertNil(HookEvent(json: ["last_assistant_message": " \n\n "]).lastReply)
    }
}
