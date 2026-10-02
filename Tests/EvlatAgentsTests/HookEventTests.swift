import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The half of the typed hook view that names the agents: each one's
/// translation into the canonical vocabulary, and its wire path. The
/// parsing every agent shares stays with the core's own tests.
final class HookEventTests: XCTestCase {
    /// v1's measured rule: `apply_patch` becomes the canonical
    /// tool its first header names, with that file as the path. The patch
    /// text itself does not survive the translation.
    func testCodexApplyPatchBecomesEditOrWrite() {
        func translated(_ patch: String) -> HookEvent {
            HookEvent(json: Codex().hooks.canonical([
                "hook_event_name": "PreToolUse", "tool_name": "apply_patch",
                "tool_input": ["command": patch],
            ]), source: .codex)
        }
        let add = translated("*** Begin Patch\n*** Add File: docs/a.md\n+hello\n*** End Patch")
        XCTAssertEqual(add.toolName, "Write")
        XCTAssertEqual(add.toolSubject, "docs/a.md")

        let update = translated("*** Begin Patch\n*** Update File: Sources/b.swift\n@@\n-x\n+y\n*** End Patch")
        XCTAssertEqual(update.toolName, "Edit")
        XCTAssertEqual(update.toolSubject, "Sources/b.swift")

        let delete = translated("*** Begin Patch\n*** Delete File: old.txt\n*** End Patch")
        XCTAssertEqual(delete.toolName, "Edit")
        XCTAssertEqual(delete.toolSubject, "old.txt")

        let headerless = translated("some patch without a header")
        XCTAssertEqual(headerless.toolName, "Edit", "an unreadable patch is still an edit")
        XCTAssertNil(headerless.toolSubject, "and the patch text is never the subject")
    }

    /// Codex's subagent tools read as the canonical `Agent`, with the task's
    /// name as its description when there is one.
    func testCodexSubagentToolsBecomeAgent() {
        for tool in ["collaborationspawn_agent", "collaborationwait_agent"] {
            let event = HookEvent(json: Codex().hooks.canonical([
                "hook_event_name": "PreToolUse", "tool_name": tool,
                "tool_input": ["task_name": "review the diff", "message": "opaque"],
            ]), source: .codex)
            XCTAssertEqual(event.toolName, "Agent", tool)
            XCTAssertEqual(event.toolSubject, "review the diff", tool)
        }
        let unnamed = HookEvent(json: Codex().hooks.canonical([
            "tool_name": "collaborationspawn_agent", "tool_input": ["message": "opaque"],
        ]), source: .codex)
        XCTAssertEqual(unnamed.toolName, "Agent")
        XCTAssertNil(unnamed.toolSubject)
    }

    /// Claude's tools are already canonical and pass through untouched.
    func testClaudeToolsAreNotTranslated() {
        let json: [String: Any] = ["tool_name": "apply_patch", "tool_input": ["command": "x"]]
        XCTAssertEqual(Claude().hooks.canonical(json)["tool_name"] as? String, "apply_patch")
    }


    /// Codex sends no `Stop` when a turn is interrupted; without the
    /// translation the session would sit at `working` forever (measured in v1).
    func testCodexInterruptBecomesAStop() {
        let translated = Codex().hooks.canonical(["hook_event_name": "Interrupt", "session_id": "c-1"])
        XCTAssertEqual(HookEvent(json: translated, source: .codex).name, "Stop")
        XCTAssertEqual(translated["session_id"] as? String, "c-1", "nothing else is touched")
    }

    /// The branching lives in `canonical` and nowhere else: the same word from
    /// Claude is left alone, and an event Codex spells the canonical way passes
    /// through untouched.
    func testOnlyCodexTranslatesInterrupt() {
        XCTAssertEqual(HookEvent(json: Claude().hooks.canonical(["hook_event_name": "Interrupt"]),
                                 source: .claude).name, "Interrupt")
        for name in ["SessionStart", "PreToolUse", "PermissionRequest", "Stop", "SomethingNew"] {
            XCTAssertEqual(Codex().hooks.canonical(["hook_event_name": name])["hook_event_name"] as? String,
                           name, name)
        }
    }

    /// The server stamps its two keys **before** the adapter runs, so the
    /// adapter has to carry them through: if they were dropped, the session's
    /// whereabouts would be lost for every source but Claude.
    func testTheAdapterCarriesTheServersKeys() {
        let translated = Codex().hooks.canonical([
            "hook_event_name": "Interrupt",
            HookEvent.taskKey: "build-42",
            HookEvent.pidKey: "7747",
        ])
        let event = HookEvent(json: translated, source: .codex)
        XCTAssertEqual(event.taskID, "build-42")
        XCTAssertEqual(event.pid, 7747)
    }

    /// Each source's wire path. `/hook` is Claude's because that is the path in
    /// the command already installed on this machine.
    func testEachSourceHasItsOwnPath() {
        XCTAssertEqual(Claude().hookPath, "/hook")
        XCTAssertEqual(Codex().hookPath, "/hook/codex")
        XCTAssertEqual(Set(Agents.all.map(\.hookPath)).count, Agents.all.count)
    }
}
