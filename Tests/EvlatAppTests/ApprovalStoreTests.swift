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

    // MARK: - Questions

    private func question(_ id: String, session: String = "s-1") -> PermissionHook.Request {
        let questions = [AskQuestion.Question(text: "Which color?", options: [.init(label: "Red"), .init(label: "Blue")]),
                         AskQuestion.Question(text: "Which sizes?", options: [.init(label: "S"), .init(label: "L")],
                                              multiSelect: true)]
        return PermissionHook.Request(id: id, token: nil, tool: AskQuestion.tool, subject: nil, sessionID: session,
                                      questions: questions, input: Data(#"{"questions":[]}"#.utf8))
    }

    /// Nothing goes back until the last question is answered; then one
    /// reply carries every answer, and the request is no longer held.
    func testAQuestionIsSentOnceEveryAnswerIsIn() throws {
        let store = store()
        store.asked(question("q-1"))
        XCTAssertTrue(store.choose("q-1", option: 1))
        XCTAssertEqual(store.draft("q-1")?.index, 1)
        XCTAssertTrue(store.choose("q-1", option: 1))
        XCTAssertTrue(store.write("q-1", "XL"))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(store.commit("q-1"))
        let body = try XCTUnwrap(sent.first?.1.body)
        XCTAssertTrue(body.contains(#""answers":{"Which color?":"Blue","Which sizes?":"L, XL"}"#), body)
        XCTAssertNil(store.request(forSession: "s-1"))
        XCTAssertNil(store.draft("q-1"))
        XCTAssertFalse(store.choose("q-1", option: 0), "the card went stale")
        XCTAssertEqual(sent.count, 1)
    }

    /// Back is a step in the draft, never a reply.
    func testBackSendsNothing() {
        let store = store()
        store.asked(question("q-1"))
        store.choose("q-1", option: 0)
        XCTAssertTrue(store.back("q-1"))
        XCTAssertEqual(store.draft("q-1")?.index, 0)
        XCTAssertTrue(sent.isEmpty)
    }

    /// A bare allow answers no question (the reported bug): it is not sent.
    /// Deny still is.
    func testAQuestionIsNeverAllowedBare() throws {
        let store = store()
        store.asked(question("q-1"))
        XCTAssertFalse(store.answer("q-1", allow: true))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(store.answer("q-1", allow: false))
        XCTAssertTrue(try XCTUnwrap(sent.first?.1.body).contains(#""behavior":"deny""#))
    }

    /// Answered in the terminal: the draft goes with the request.
    func testAQuestionAnsweredInTheTerminalTakesItsDraft() {
        let store = store()
        store.asked(question("q-1"))
        store.choose("q-1", option: 0)
        store.heard(HookEvent(json: ["hook_event_name": "PostToolUse", "session_id": "s-1",
                                     "tool_name": AskQuestion.tool, "tool_input": ["questions": []]]))
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
        XCTAssertNil(store.draft("q-1"))
    }
}
