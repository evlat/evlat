import XCTest
@testable import EvlatCore

/// One chat's state machine: stream events in, messages and a `Signal` out.
/// Headless — the process is the shell's (`ClaudeRunner`).
final class ChatSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func chat() -> ChatSession {
        ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
    }

    func testANewChatHasNoRow() {
        XCTAssertNil(chat().signal())
    }

    func testTheFirstTurnNamesTheSessionAndLaterOnesResumeIt() {
        var chat = chat()
        let first = chat.begin(prompt: "hi", attachments: [], at: t0)
        XCTAssertEqual(first?.arguments.contains("--session-id"), true)
        XCTAssertNil(chat.begin(prompt: "again", attachments: [], at: t0), "one turn at a time")
        chat.apply(.started(sessionID: "S1"), at: t0)
        chat.apply(.result(.init(subtype: "success", isError: false, text: "ok")), at: t0)
        chat.ended(status: 0, stderr: "", at: t0)
        let second = chat.begin(prompt: "again", attachments: [], at: t0)
        XCTAssertEqual(second?.arguments.contains("--resume"), true)
        XCTAssertEqual(second?.arguments.contains("--session-id"), false)
    }

    /// A turn that never reached Claude created no session there: the next
    /// one names it again rather than resuming nothing.
    func testATurnThatNeverStartedIsNotResumed() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.ended(status: 1, stderr: "boom", at: t0)
        XCTAssertEqual(chat.begin(prompt: "hi", attachments: [], at: t0)?.arguments.contains("--session-id"), true)
    }

    func testTheRowIsAnOfficialJobInEvlatsNamespace() throws {
        var chat = chat()
        _ = chat.begin(prompt: "Summarise the report\nplease", attachments: [], at: t0)
        let signal = try XCTUnwrap(chat.signal())
        XCTAssertEqual(signal.provider, ChatSession.provider)
        XCTAssertEqual(signal.provider, "evlat")
        XCTAssertEqual(signal.entity, "evlat:C1")
        XCTAssertEqual(signal.kind, .job)
        XCTAssertEqual(signal.phase, .working)
        XCTAssertNil(signal.source, "a chat is not an agent's session")
        XCTAssertEqual(signal.fidelity, .official, "the phase comes from the documented stream")
        XCTAssertEqual(signal.label, "Summarise the report", "the first line of the first prompt")
        XCTAssertEqual(signal.detail, "/tmp/project")
        XCTAssertEqual(signal.updatedAt, t0)
    }

    func testASuccessfulTurnEndsInReview() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.apply(.started(sessionID: "S1"), at: t0)
        chat.apply(.textDelta("o"), at: t0)
        chat.apply(.textDelta("k"), at: t0)
        chat.apply(.assistant(text: "ok", tools: []), at: t0)
        chat.apply(.result(.init(subtype: "success", isError: false, text: "ok")), at: t0 + 3)
        XCTAssertEqual(chat.phase, .review)
        XCTAssertEqual(chat.signal()?.updatedAt, t0 + 3)
        XCTAssertEqual(chat.signal()?.activity?.lastReply, "ok")
        XCTAssertEqual(chat.messages, [.user(text: "hi", attachments: []), .reply("ok")],
                       "the final message replaces the streamed text rather than doubling it")
        chat.ended(status: 0, stderr: "", at: t0 + 4)
        XCTAssertEqual(chat.phase, .review, "a clean exit after the result changes nothing")
        XCTAssertFalse(chat.isRunning)
    }

    func testToolsBecomeOneLineMessagesAndTheCardsLastTool() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.apply(.textDelta("Look"), at: t0)
        chat.apply(.assistant(text: "Looking.", tools: [.init(id: "t1", name: "Bash", subject: "ls")]), at: t0)
        chat.apply(.toolResult(id: "t1", isError: true, output: "no such file"), at: t0)
        chat.apply(.textDelta("Done"), at: t0)
        chat.apply(.assistant(text: "Done.", tools: []), at: t0)
        XCTAssertEqual(chat.messages, [
            .user(text: "hi", attachments: []),
            .reply("Looking."),
            .tool(id: "t1", name: "Bash", subject: "ls", failed: true, output: "no such file"),
            .reply("Done."),
        ])
        XCTAssertEqual(chat.signal()?.activity?.lastTool, Signal.Activity.Tool(name: "Bash", subject: "ls"))
        XCTAssertEqual(chat.signal()?.activity?.toolCount, 1)
    }

    func testAnErrorResultFails() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.apply(.result(.init(subtype: "error_max_turns", isError: true, text: nil)), at: t0)
        XCTAssertEqual(chat.phase, .failed)
        XCTAssertEqual(chat.failure, .result(subtype: "error_max_turns", text: nil))
    }

    /// The process died without a result: a crash, not a finished turn.
    func testAnExitWithoutAResultFails() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.apply(.started(sessionID: "S1"), at: t0)
        chat.ended(status: 3, stderr: "warning\nfatal: gone\n", at: t0)
        XCTAssertEqual(chat.phase, .failed)
        XCTAssertEqual(chat.failure, .exited(status: 3, detail: "fatal: gone"))
    }

    /// Stopping is the user's choice, not a failure: whatever the turn says
    /// on the way out, it ends as a finished turn.
    func testAStoppedTurnEndsInReview() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        XCTAssertEqual(chat.requestStop(at: t0), [])
        chat.ended(status: 130, stderr: "", at: t0)
        XCTAssertEqual(chat.phase, .review)
        XCTAssertNil(chat.failure)
        XCTAssertEqual(chat.signal()?.rawStatus, ChatSession.stoppedWord)
        XCTAssertNil(chat.requestStop(at: t0), "nothing is running to stop")
    }

    func testANewTurnClearsTheLastOnesFacts() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.apply(.assistant(text: nil, tools: [.init(id: "t1", name: "Bash", subject: "ls")]), at: t0)
        chat.apply(.result(.init(subtype: "error", isError: true, text: nil)), at: t0)
        chat.ended(status: 1, stderr: "", at: t0)
        _ = chat.begin(prompt: "again", attachments: [], at: t0 + 1)
        XCTAssertEqual(chat.phase, .working)
        XCTAssertNil(chat.failure)
        XCTAssertNil(chat.signal()?.activity?.lastTool)
        XCTAssertEqual(chat.signal()?.activity?.toolCount, 0)
    }

    func testAFailureWithoutAProcess() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        chat.fail(.noBinary, at: t0)
        XCTAssertEqual(chat.phase, .failed)
        XCTAssertEqual(chat.failure, .noBinary)
        XCTAssertFalse(chat.isRunning)
    }

    /// The card's reply keeps the session card's privacy promise.
    func testTheLastReplyIsCapped() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        let long = String(repeating: "a", count: 1000) + "\n\nsecond"
        chat.apply(.result(.init(subtype: "success", isError: false, text: long)), at: t0)
        XCTAssertLessThanOrEqual(chat.signal()?.activity?.lastReply?.count ?? .max, HookEvent.replyLimit + 1)
    }
}

/// Permission cards (`phase-3`): `waiting` while one is open, `working`
/// again once the last is answered.
final class ChatSessionPermissionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func running() -> ChatSession {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
        _ = chat.begin(prompt: "write it", attachments: [], at: t0)
        return chat
    }

    private func request(_ id: String, tool: String = "Write", rules: [PermissionHook.Rule] = [],
                         directories: [String] = []) -> PermissionHook.Request {
        PermissionHook.Request(id: id, token: "T", tool: tool, subject: "/tmp/project/a.txt",
                               rules: rules, directories: directories)
    }

    func testAnOpenCardMakesTheChatWaitAndAnAnswerResumesIt() throws {
        var chat = running()
        XCTAssertTrue(chat.ask(request("R1", rules: [.init(toolName: "Write")]), at: t0))
        XCTAssertEqual(chat.phase, .waiting)
        let row = try XCTUnwrap(chat.signal())
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertEqual(row.activity?.waitKind, .approval)
        XCTAssertEqual(row.activity?.blockingTool, Signal.Activity.Tool(name: "Write", subject: "/tmp/project/a.txt"))
        XCTAssertEqual(chat.openRequests, ["R1"])

        XCTAssertEqual(chat.answer("R1", .allowAlways, at: t0),
                       .allow(rules: [.init(toolName: "Write")], directories: []))
        XCTAssertEqual(chat.phase, .working)
        XCTAssertNil(chat.signal()?.activity?.waitKind)
        XCTAssertNil(chat.signal()?.activity?.blockingTool)
        guard case .permission(let card)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertEqual(card.outcome, .allowedAlways)
        XCTAssertNil(chat.answer("R1", .deny, at: t0), "an answered card is not answered twice")
    }

    func testTwoRequestsAreTwoCards() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        chat.ask(request("R2", tool: "Bash"), at: t0)
        XCTAssertEqual(chat.openRequests, ["R1", "R2"])
        XCTAssertEqual(chat.answer("R2", .deny, at: t0), .deny(interrupt: false))
        XCTAssertEqual(chat.phase, .waiting, "one card is still open")
        XCTAssertEqual(chat.signal()?.activity?.blockingTool?.name, "Write")
        XCTAssertEqual(chat.answer("R1", .allow, at: t0), .allow(rules: [], directories: []))
        XCTAssertEqual(chat.phase, .working)
    }

    func testAnAbandonedCardGoesAndTheTurnGoesOn() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        chat.expire("R1", at: t0)
        XCTAssertEqual(chat.phase, .working)
        XCTAssertTrue(chat.openRequests.isEmpty)
        XCTAssertNil(chat.answer("R1", .allow, at: t0))
    }

    func testStopDeniesEveryOpenCard() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        chat.ask(request("R2"), at: t0)
        XCTAssertEqual(chat.requestStop(at: t0), ["R1", "R2"])
        XCTAssertTrue(chat.openRequests.isEmpty)
        XCTAssertNotEqual(chat.phase, .waiting)
        XCTAssertFalse(chat.ask(request("R3"), at: t0), "a stopping turn asks nothing more")
        chat.ended(status: 130, stderr: "", at: t0)
        XCTAssertEqual(chat.phase, .review)
    }

    func testTheEndOfTheTurnExpiresWhatIsLeft() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        chat.ended(status: 1, stderr: "gone", at: t0)
        XCTAssertTrue(chat.openRequests.isEmpty)
        XCTAssertEqual(chat.phase, .failed)
    }

    func testNoTurnNoCard() {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
        XCTAssertFalse(chat.ask(request("R1"), at: t0))
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testAFolderOutsideIsOfferedAsAccess() {
        var chat = running()
        chat.ask(request("R1", directories: ["/elsewhere"]), at: t0)
        guard case .permission(let card)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertTrue(card.offersAlways)
        XCTAssertEqual(chat.answer("R1", .allowAlways, at: t0), .allow(rules: [], directories: ["/elsewhere"]))
    }

    /// A second card keeps the wait's start: the bar counts how long the
    /// chat has been blocked.
    func testASecondCardKeepsTheWaitsStart() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        chat.ask(request("R2"), at: t0.addingTimeInterval(180))
        XCTAssertEqual(chat.since, t0)
    }

    /// An answer that never reached Claude (its connection closed first)
    /// shows as expired, not as allowed.
    func testAnAnsweredCardThatWasAbandonedExpires() {
        var chat = running()
        chat.ask(request("R1"), at: t0)
        _ = chat.answer("R1", .allow, at: t0)
        chat.expire("R1", at: t0)
        guard case .permission(let card)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertEqual(card.outcome, .expired)
    }
}

