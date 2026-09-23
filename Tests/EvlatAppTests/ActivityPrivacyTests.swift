import XCTest
import EvlatCore
@testable import EvlatApp

/// The card's data is shown on the card and nowhere else (R1.3): not in
/// `--list`, which ends up in pasted bug reports, and not in the hook
/// diagnostics, which stream every event to a terminal.
final class ActivityPrivacyTests: XCTestCase {
    private let secret = "curl -H 'Authorization: sk-secret'"

    func testTheListLineCarriesNoActivity() {
        let signal = Signal(provider: "hooks", entity: "s-1", phase: .waiting, label: "project",
                            detail: "/tmp/project", fidelity: .official, rawStatus: "PermissionRequest",
                            updatedAt: Date(),
                            activity: Signal.Activity(pid: 4242,
                                                      lastTool: .init(name: "Bash", subject: secret),
                                                      blockingTool: .init(name: "Bash", subject: secret),
                                                      waitKind: .approval, lastReply: secret,
                                                      toolCount: 3))
        let line = AppController.listLine(signal)
        XCTAssertTrue(line.contains("project"), line)
        XCTAssertFalse(line.contains("sk-secret"), line)
        XCTAssertFalse(line.contains("Bash"), line)
        XCTAssertFalse(line.contains("4242"), line)
    }

    func testTheDiagnosticsLineCarriesNoToolOrReply() {
        let event = HookEvent(json: ["hook_event_name": "PreToolUse", "session_id": "s-1",
                                     "tool_name": "Bash", "tool_input": ["command": secret],
                                     "last_assistant_message": secret])
        let line = HookDiagnostics().record(event).text
        XCTAssertFalse(line.contains("sk-secret"), line)
        XCTAssertFalse(line.contains("Bash"), line)
    }
}
