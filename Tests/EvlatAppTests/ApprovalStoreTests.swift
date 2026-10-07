import XCTest
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// Held terminal permissions: a press answers once, a stale press sends
/// nothing, and a request answered elsewhere is let go with `{}` — never a
/// decision Evlat made on its own.
@MainActor
final class ApprovalStoreTests: XCTestCase {
    private var sent: [(String, LocalAPI.Response)] = []
    /// Which listener each answer went to: the request's machine.
    private var listeners: [String?] = []

    private func store() -> ApprovalStore {
        let store = ApprovalStore(agents: Agents.all)
        store.respond = { [weak self] request, response in
            self?.sent.append((request.id, response))
            self?.listeners.append(request.machine)
        }
        return store
    }

    private func request(_ id: String, session: String = "s-1", machine: String? = nil) -> HeldRequest {
        HeldRequest(id: id, token: nil, tool: "Bash", subject: "rm -r build",
                    command: "rm -r build", sessionID: session, source: .claude, machine: machine)
    }

    private func stop(_ session: String = "s-1") -> HookEvent {
        HookEvent(json: ["hook_event_name": "Stop", "session_id": session])
    }

    func testAllowIsOnceAndOnlyOnce() throws {
        let store = store()
        store.asked(request("r-1"))
        XCTAssertEqual(store.request(forSession: "s-1", machine: nil)?.id, "r-1")
        XCTAssertTrue(store.answer("r-1", allow: true))
        let body = try XCTUnwrap(sent.first?.1.body)
        XCTAssertTrue(body.contains(#""behavior":"allow""#))
        XCTAssertFalse(body.contains("updatedPermissions"), "no rule and no folder is kept from the bar")
        XCTAssertFalse(store.answer("r-1", allow: false), "a second press on the same card sends nothing")
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(store.request(forSession: "s-1", machine: nil))
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
                                     "tool_name": "Bash", "tool_input": ["command": "rm -r build"]]), machine: nil)
        XCTAssertEqual(sent.map(\.0), ["r-1"])
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
        XCTAssertFalse(store.answer("r-1", allow: true), "the card went stale")
        XCTAssertEqual(store.request(forSession: "s-2", machine: nil)?.id, "r-9", "another session's stays")
    }

    func testAClosedConnectionTakesTheCardAndSendsNothing() {
        let store = store()
        store.asked(request("r-1"))
        store.abandoned("r-1")
        XCTAssertNil(store.request(forSession: "s-1", machine: nil))
        XCTAssertTrue(sent.isEmpty)
    }

    func testANewerRequestLetsTheOlderGo() {
        let store = store()
        store.asked(request("r-1"))
        store.asked(request("r-2"))
        XCTAssertEqual(sent.map(\.0), ["r-1"])
        XCTAssertEqual(store.request(forSession: "s-1", machine: nil)?.id, "r-2")
    }

    // MARK: - Machines

    /// A session id is the agent's and can come from any computer: an
    /// event heard on machine A answers none of B's requests, nor this
    /// Mac's, for the same id.
    func testAMachinesEventResolvesOnlyItsOwnRequests() {
        let store = store()
        store.asked(request("local"))
        store.asked(request("a", machine: "m-a"))
        store.asked(request("b", machine: "m-b"))
        store.heard(stop(), machine: "m-a")
        XCTAssertEqual(sent.map(\.0), ["a"])
        XCTAssertEqual(Set(store.pending.map(\.id)), ["local", "b"])
        store.heard(stop(), machine: nil)
        XCTAssertEqual(sent.map(\.0), ["a", "local"])
        XCTAssertEqual(store.pending.map(\.id), ["b"])
    }

    /// The card asks by the row's machine: a server that sends this Mac's
    /// session id finds no local card, and a local row none of a server's.
    func testARemoteRequestNeverShowsOnALocalRow() {
        let store = store()
        store.asked(request("a", machine: "m-a"))
        XCTAssertNil(store.request(forSession: "s-1", machine: nil))
        XCTAssertNil(store.request(forSession: "s-1", machine: "m-b"))
        XCTAssertEqual(store.request(forSession: "s-1", machine: "m-a")?.id, "a")
        store.asked(request("local"))
        XCTAssertEqual(store.request(forSession: "s-1", machine: nil)?.id, "local",
                       "nor did the machine's replace this Mac's")
        XCTAssertEqual(store.request(forSession: "s-1", machine: "m-a")?.id, "a")
    }

    /// The answer goes back to the listener that heard the request.
    func testTheAnswerGoesToTheRequestsListener() throws {
        let store = store()
        store.asked(request("a", machine: "m-a"))
        store.asked(request("local"))
        XCTAssertTrue(store.answer("a", allow: true))
        XCTAssertTrue(store.answer("local", allow: false))
        XCTAssertEqual(sent.map(\.0), ["a", "local"])
        XCTAssertEqual(listeners, ["m-a", nil])
        XCTAssertTrue(try XCTUnwrap(sent.first?.1.body).contains(#""behavior":"allow""#),
                      "in the format of the agent that asked")
    }

    /// A machine switching its agent off lets its own requests go, `{}`;
    /// this Mac's and another machine's stay held.
    func testAMachinesAgentOffLetsOnlyItsRequestsGo() {
        let store = store()
        store.asked(request("local"))
        store.asked(request("a", machine: "m-a"))
        store.asked(request("b", machine: "m-b"))
        store.release { $0.machine == "m-a" && $0.source == .claude }
        XCTAssertEqual(sent.map(\.0), ["a"])
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
        XCTAssertEqual(listeners, ["m-a"])
        XCTAssertEqual(Set(store.pending.map(\.id)), ["local", "b"])
    }

    /// Codex's dialog waits for the hook, and Esc ends the turn while the
    /// hook's process lives on (measured): the request is let go by the
    /// `Interrupt` that follows, which its adapter reads as `Stop` — heard
    /// on the machine's listener, as a server's hook posts it.
    func testACodexRequestIsLetGoByItsInterrupt() {
        let store = store()
        let session = "019a-thread"
        let asked = LocalAPI.handle(
            HTTPRequest(method: "POST", target: "/approval/codex",
                        body: Data(#"{"hook_event_name":"PermissionRequest","session_id":"019a-thread","turn_id":"t-1","tool_name":"Bash","tool_input":{"command":"rm -r build"}}"#.utf8),
                        host: "127.0.0.1:48151"),
            listener: LocalAPI.Listener(origin: .machine, routes: Agents.routes), agents: Agents.all)
        guard case .approval(var request)? = asked.delivery else { return XCTFail("not held") }
        request.machine = "m-a"
        XCTAssertEqual(request.source, .codex)
        store.asked(request)
        let interrupt = LocalAPI.handle(
            HTTPRequest(method: "POST", target: "/hook/codex",
                        body: Data(#"{"hook_event_name":"Interrupt","session_id":"019a-thread","turn_id":"t-1"}"#.utf8),
                        host: "127.0.0.1:48151"),
            listener: LocalAPI.Listener(origin: .machine, routes: Agents.routes), agents: Agents.all)
        guard case .hook(let event)? = interrupt.delivery else { return XCTFail("not heard") }
        store.heard(event, machine: nil)
        XCTAssertNotNil(store.request(forSession: session, machine: "m-a"), "this Mac's events speak of none of it")
        store.heard(event, machine: "m-a")
        XCTAssertEqual(sent.map(\.0), [request.id])
        XCTAssertEqual(sent.first?.1, ApprovalStore.released, "no decision: the turn is already over")
        XCTAssertNil(store.request(forSession: session, machine: "m-a"))
    }

    /// Allow once and Deny reach Codex in its own measured shape.
    func testACodexRequestIsAnsweredInCodexsShape() throws {
        let store = store()
        var request = request("c-1", machine: "m-a")
        request.source = .codex
        store.asked(request)
        XCTAssertTrue(store.answer("c-1", allow: true))
        XCTAssertEqual(sent.first?.1.body, Codex().approvals?.body(.allow(rules: [], directories: [])))
    }

    /// The card says which agent asks: a server's Codex is not "Claude".
    func testTheCardNamesTheAgentThatAsks() {
        var codex = request("c-1", machine: "m-a")
        codex.source = .codex
        XCTAssertEqual(SessionDetail.ApprovalCard(codex).agentNameKey, Codex().display.nameKey)
        XCTAssertEqual(SessionDetail.ApprovalCard(request("r-1")).agentNameKey, Claude().display.nameKey)
    }

    /// A request naming no agent this build knows is answered with no
    /// decision.
    func testARequestOfNoKnownAgentIsAnsweredWithNoDecision() {
        let store = store()
        var unknown = request("r-1")
        unknown.source = nil
        store.asked(unknown)
        store.answer("r-1", allow: true)
        XCTAssertEqual(sent.first?.1.body, "{}")
    }

    // MARK: - Questions

    private func question(_ id: String, session: String = "s-1") -> HeldRequest {
        let questions = [AgentQuestion(text: "Which color?", options: [.init(label: "Red"), .init(label: "Blue")]),
                         AgentQuestion(text: "Which sizes?", options: [.init(label: "S"), .init(label: "L")],
                                              multiSelect: true)]
        return HeldRequest(id: id, token: nil, tool: AskQuestion.tool, subject: nil, sessionID: session,
                           questions: questions, input: Data(#"{"questions":[]}"#.utf8), source: .claude)
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
        XCTAssertNil(store.request(forSession: "s-1", machine: nil))
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
                                     "tool_name": AskQuestion.tool, "tool_input": ["questions": []]]), machine: nil)
        XCTAssertEqual(sent.first?.1, ApprovalStore.released)
        XCTAssertNil(store.draft("q-1"))
    }
}
