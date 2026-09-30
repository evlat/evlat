import XCTest
import EvlatCore
@testable import EvlatApp

/// Held terminal permissions: a press answers once, a stale press sends
/// nothing, and a request answered elsewhere is let go with `{}` — never a
/// decision Evlat made on its own.
@MainActor
final class ApprovalStoreTests: XCTestCase {
    private var sent: [(String, LocalAPI.Response)] = []

    private func store() -> ApprovalStore {
        let store = ApprovalStore()
        store.respond = { [weak self] id, response in self?.sent.append((id, response)) }
        return store
    }

    private func request(_ id: String, session: String = "s-1") -> PermissionHook.Request {
        PermissionHook.Request(id: id, token: nil, tool: "Bash", subject: "rm -r build",
                               command: "rm -r build", sessionID: session)
    }

    func testAllowIsOnceAndOnlyOnce() throws {
        let store = store()
        store.asked(request("r-1"))
        XCTAssertEqual(store.request(forSession: "s-1")?.id, "r-1")
        XCTAssertTrue(store.answer("r-1", allow: true))
        let body = try XCTUnwrap(sent.first?.1.body)
        XCTAssertTrue(body.contains(#""behavior":"allow""#))
        XCTAssertFalse(body.contains("updatedPermissions"), "no rule and no folder is kept from the bar")
        XCTAssertFalse(store.answer("r-1", allow: false), "a second press on the same card sends nothing")
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(store.request(forSession: "s-1"))
    }

    func testDenyDoesNotInterrupt() throws {
        let store = store()
        store.asked(request("r-1"))
        store.answer("r-1", allow: false)
        let body = try XCTUnwrap(sent.first?.1.body)
        XCTAssertTrue(body.contains(#""behavior":"deny""#))
        XCTAssertFalse(body.contains("interrupt"))
    }

    func testAnsweredInTheTerminalIsLetGoWithNoDecision() {
        let store = store()
        store.asked(request("r-1"))
        store.asked(request("r-9", session: "s-2"))
        store.heard(HookEvent(json: ["hook_event_name": "PostToolUse", "session_id": "s-1",
                                     "tool_name": "Bash", "tool_input": ["command": "rm -r build"]]))
        XCTAssertEqual(sent.map(\.0), ["r-1"])
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
        XCTAssertFalse(store.answer("r-1", allow: true), "the card went stale")
        XCTAssertEqual(store.request(forSession: "s-2")?.id, "r-9", "another session's stays")
    }

    func testAClosedConnectionTakesTheCardAndSendsNothing() {
        let store = store()
        store.asked(request("r-1"))
        store.abandoned("r-1")
        XCTAssertNil(store.request(forSession: "s-1"))
        XCTAssertTrue(sent.isEmpty)
    }

    func testANewerRequestLetsTheOlderGo() {
        let store = store()
        store.asked(request("r-1"))
        store.asked(request("r-2"))
        XCTAssertEqual(sent.map(\.0), ["r-1"])
        XCTAssertEqual(store.request(forSession: "s-1")?.id, "r-2")
    }
}
