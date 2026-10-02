import XCTest
@testable import EvlatCore

/// The chat's seam run with a stand-in backend (`TestChatBackend`): the
/// session, the routes and the index ask the backend's values, never which
/// agent it is.
final class ChatSeamTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let backend = TestChatBackend()

    private func running(_ mode: ChatMode) -> ChatSession {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/p", isWorkspace: false, mode: mode)
        _ = chat.begin(prompt: "go", attachments: [], at: t0)
        return chat
    }

    private func denied(_ chat: inout ChatSession, _ id: String, retryable: Bool, answered: Bool = false) {
        chat.apply(.assistant(text: nil, tools: [.init(id: id, name: "Bash", subject: "x \(id)")]), at: t0)
        chat.apply(.permissionDenied(.init(tool: "Bash", toolUseID: id, reason: "why",
                                           answered: answered, retryable: retryable)), at: t0)
    }

    private func notDone(_ chat: ChatSession) -> [ChatSession.NotDone] {
        chat.messages.compactMap { if case .notDone(let line) = $0 { return line } else { return nil } }
    }

    /// The mode's own judgement is retried in the mode it names; a rule is
    /// not, nor is any denial in a mode that names none; a card's answer is
    /// no line at all.
    func testADenialIsRetriedInTheModeTheTurnsModeNames() {
        var chat = running(TestChatBackend.auto)
        denied(&chat, "t1", retryable: true)
        denied(&chat, "t2", retryable: false)
        denied(&chat, "t3", retryable: true, answered: true)
        XCTAssertEqual(notDone(chat).map(\.retryAs), ["ask", nil])
        XCTAssertEqual(notDone(chat).map(\.mode), [TestChatBackend.auto, TestChatBackend.auto])

        var asking = running(TestChatBackend.ask)
        denied(&asking, "t1", retryable: true)
        XCTAssertEqual(notDone(asking).map(\.retryAs), [nil], "a mode that names no retry offers none")
    }

    /// The turn is what the chat knows, in its mode; its backend makes the
    /// launch.
    func testTheTurnIsTheChatsAndTheBackendLaunchesIt() throws {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/p", isWorkspace: false,
                               mode: TestChatBackend.ask)
        let spec = try XCTUnwrap(chat.begin(prompt: "hi", attachments: ["/a"], at: t0, allowedTools: ["R"]))
        XCTAssertEqual(spec, TurnSpec(chatID: "C1", sessionID: "S1", resume: false, prompt: "hi", attachments: ["/a"],
                                      directory: "/tmp/p", allowedTools: ["R"], mode: TestChatBackend.ask))
        let launch = backend.turn(spec, ctx: TurnContext(port: 1, token: "T"))
        XCTAssertEqual(launch.arguments, ["--mode", "ask"])
        XCTAssertEqual(launch.environment, [TurnLaunch.taskVariable: "C1"])
    }

    /// What a turn inherits loses what the backend takes out, keeps the
    /// rest, and gains what the turn adds.
    func testTheLaunchsEnvironment() {
        let launch = TurnLaunch(arguments: [], input: [], environment: ["A": "new"], removedEnvironment: ["B"],
                                directory: "/")
        XCTAssertEqual(launch.environment(inheriting: ["A": "old", "B": "1", "C": "2"]), ["A": "new", "C": "2"])
    }

    /// A stored mode is read among the backend's own; anything else takes
    /// the default handed in.
    func testARestoredChatsModeIsItsBackends() {
        var entry = ChatIndex.Entry(id: "C1", sessionID: "S1", folder: "/p", isWorkspace: false,
                                    createdAt: t0, lastActivity: t0, permissionMode: "bypass")
        XCTAssertEqual(ChatSession.restored(entry, modes: backend.modes, mode: TestChatBackend.auto).mode,
                       TestChatBackend.bypass)
        entry.permissionMode = "dontKnow"
        XCTAssertEqual(ChatSession.restored(entry, modes: backend.modes, mode: TestChatBackend.ask).mode,
                       TestChatBackend.ask)
        XCTAssertEqual(backend.mode(stored: "auto"), TestChatBackend.auto)
        XCTAssertNil(backend.mode(stored: nil))
    }

    /// Each backend keeps its own default and its own index file, unless it
    /// names the ones it kept from before.
    func testEachBackendHasItsOwnKeyAndFile() {
        XCTAssertEqual(backend.modeKey, "chat.test.mode")
        XCTAssertEqual(backend.indexFile, "chats-test.json")
        XCTAssertEqual(ChatIndex.fileName(for: AgentID("other")), "chats-other.json")
        XCTAssertEqual(backend.executableVariable, "EVLAT_TESTAGENT")
    }

    /// `/permission` belongs to the first agent whose chat asks one way; a
    /// duplex backend asks on its own channel and takes no route.
    func testThePermissionRouteIsAOneWayBackends() {
        struct Duplex: ChatBackend {
            var id = AgentID.other
            let executable = "duplex"
            let modes = [TestChatBackend.ask]
            let offered = [TestChatBackend.ask]
            let standardMode = TestChatBackend.ask
            let caps = ChatCapabilities(asks: true, alwaysOption: .thisCommand, resume: true, memory: false,
                                        transport: .duplex)
            let stopPlan = ChatStopPlan.line(Data("stop\n".utf8))
            func turn(_ spec: TurnSpec, ctx: TurnContext) -> TurnLaunch {
                TurnLaunch(arguments: [], input: [], environment: [:], directory: spec.directory)
            }
            func parser() -> any ChatParser { TestChatBackend.Quiet() }
            func encode(_ decision: ChatDecision, for request: ChatRequest) -> ChatReply { .line(Data()) }
        }
        let duplex = TestAgent("other", chat: Duplex())
        let oneWay = TestAgent("third", chat: TestChatBackend(id: .third))
        XCTAssertEqual(RouteTable([TestAgent(), duplex, oneWay]).permission, .third)
        XCTAssertNil(RouteTable([TestAgent(), duplex]).permission)
        XCTAssertNil(Duplex().request(json: ["tool_name": "Bash"], token: "T"), "a duplex backend reads no listener body")
    }

    /// A duplex turn's request arrives in its stream; the card is the
    /// store's to open, where the reply target is held, not the stream's.
    func testARequestInTheStreamIsTheStoresToAsk() {
        var chat = running(TestChatBackend.ask)
        let before = chat
        chat.apply(.asked(ChatRequest(id: "R1", token: nil, tool: "Bash", subject: "ls", replyTarget: .runner)), at: t0)
        XCTAssertEqual(chat, before)
        XCTAssertTrue(chat.ask(ChatRequest(id: "R1", token: nil, tool: "Bash", subject: "ls", replyTarget: .runner),
                               at: t0))
        XCTAssertEqual(chat.openRequests, ["R1"])
    }
}
