import XCTest
@testable import EvlatCore

/// The typed view of a hook body, and the one place a source's own dialect is
/// translated.
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
        XCTAssertEqual(event.source, .claude, "fixtures without a source are Claude's, like v1's")
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

    // MARK: - Sources

    /// Codex sends no `Stop` when a turn is interrupted; without the
    /// translation the session would sit at `working` forever (measured in v1).
    func testCodexInterruptBecomesAStop() {
        let translated = AgentSource.codex.canonical(["hook_event_name": "Interrupt", "session_id": "c-1"])
        XCTAssertEqual(HookEvent(json: translated, source: .codex).name, "Stop")
        XCTAssertEqual(translated["session_id"] as? String, "c-1", "nothing else is touched")
    }

    /// The branching lives in `canonical` and nowhere else: the same word from
    /// Claude is left alone, and an event Codex spells the canonical way passes
    /// through untouched.
    func testOnlyCodexTranslatesInterrupt() {
        XCTAssertEqual(HookEvent(json: AgentSource.claude.canonical(["hook_event_name": "Interrupt"]),
                                 source: .claude).name, "Interrupt")
        for name in ["SessionStart", "PreToolUse", "PermissionRequest", "Stop", "SomethingNew"] {
            XCTAssertEqual(AgentSource.codex.canonical(["hook_event_name": name])["hook_event_name"] as? String,
                           name, name)
        }
    }

    /// The server stamps its two keys **before** the adapter runs, so the
    /// adapter has to carry them through: if they were dropped, the session's
    /// whereabouts would be lost for every source but Claude.
    func testTheAdapterCarriesTheServersKeys() {
        let translated = AgentSource.codex.canonical([
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
        XCTAssertEqual(AgentSource.claude.hookPath, "/hook")
        XCTAssertEqual(AgentSource.codex.hookPath, "/hook/codex")
        XCTAssertEqual(Set(AgentSource.allCases.map(\.hookPath)).count, AgentSource.allCases.count)
    }
}
