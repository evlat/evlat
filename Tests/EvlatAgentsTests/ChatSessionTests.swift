import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// One chat's state machine: stream events in, messages and a `Signal` out.
/// Headless — the process is the shell's (`TurnRunner`). Run with Claude's
/// backend: its modes, and its launch where a turn's flags are read.
final class ChatSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func chat() -> ChatSession {
        ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
    }

    func testANewChatHasNoRow() {
        XCTAssertNil(chat().signal(at: t0))
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
        let signal = try XCTUnwrap(chat.signal(at: t0))
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
        XCTAssertEqual(chat.signal(at: t0)?.updatedAt, t0 + 3)
        XCTAssertEqual(chat.signal(at: t0)?.activity?.lastReply, "ok")
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
        XCTAssertEqual(chat.signal(at: t0)?.activity?.lastTool, Signal.Activity.Tool(name: "Bash", subject: "ls"))
        XCTAssertEqual(chat.signal(at: t0)?.activity?.toolCount, 1)
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
        XCTAssertEqual(chat.signal(at: t0)?.rawStatus, ChatSession.stoppedWord)
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
        XCTAssertNil(chat.signal(at: t0)?.activity?.lastTool)
        XCTAssertNil(chat.signal(at: t0)?.activity?.toolCount, "no tools yet: no count")
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
        XCTAssertLessThanOrEqual(chat.signal(at: t0)?.activity?.lastReply?.count ?? .max, HookEvent.replyLimit + 1)
    }
}

/// Permission cards: `waiting` while one is open, `working`
/// again once the last is answered.
final class ChatSessionPermissionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func running() -> ChatSession {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
        _ = chat.begin(prompt: "write it", attachments: [], at: t0)
        return chat
    }

    private func request(_ id: String, tool: String = "Write", rules: [PermissionHook.Rule] = [],
                         directories: [String] = []) -> ChatRequest {
        ChatRequest(id: id, token: "T", tool: tool, subject: "/tmp/project/a.txt",
                    rules: rules, directories: directories, replyTarget: .listener)
    }

    /// A suggested folder the chat already works in is not offered: Claude
    /// suggested the working folder itself for `mkdir` (measured, Ask mode).
    func testTheChatsOwnFolderIsNoAccessToGive() throws {
        var chat = running()
        chat.ask(request("R1", tool: "Bash", directories: ["/tmp/project", "/tmp/project/sub/", "/tmp/projectile",
                                                            "/tmp/other"]), at: t0)
        guard case .permission(let card)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertEqual(card.directories, ["/tmp/projectile", "/tmp/other"])
        chat.ask(request("R2", tool: "Bash", directories: ["/tmp/project/."]), at: t0)
        guard case .permission(let only)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertFalse(only.offersAlways, "nothing left to keep: no third button")
    }

    /// The card carries the request's whole command; the one-line subject
    /// stays what the bar and the "not done" match read.
    func testACardCarriesTheWholeCommand() throws {
        var chat = running()
        chat.ask(ChatRequest(id: "R1", token: "T", tool: "Bash", subject: "ls && rm a",
                             command: "ls && rm a\nfind .", replyTarget: .listener), at: t0)
        guard case .permission(let card)? = chat.messages.last else { return XCTFail("no card") }
        XCTAssertEqual(card.command, "ls && rm a\nfind .")
        XCTAssertEqual(card.subject, "ls && rm a")
    }

    func testAnOpenCardMakesTheChatWaitAndAnAnswerResumesIt() throws {
        var chat = running()
        XCTAssertTrue(chat.ask(request("R1", rules: [.init(toolName: "Write")]), at: t0))
        XCTAssertEqual(chat.phase, .waiting)
        let row = try XCTUnwrap(chat.signal(at: t0))
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertEqual(row.activity?.waitKind, .approval)
        XCTAssertEqual(row.activity?.blockingTool, Signal.Activity.Tool(name: "Write", subject: "/tmp/project/a.txt"))
        XCTAssertEqual(chat.openRequests, ["R1"])

        XCTAssertEqual(chat.answer("R1", .allowAlways, at: t0),
                       .allow(rules: [.init(toolName: "Write")], directories: []))
        XCTAssertEqual(chat.phase, .working)
        XCTAssertNil(chat.signal(at: t0)?.activity?.waitKind)
        XCTAssertNil(chat.signal(at: t0)?.activity?.blockingTool)
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
        XCTAssertEqual(chat.signal(at: t0)?.activity?.blockingTool?.name, "Write")
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

    // MARK: - Not done

    /// As Claude's stream reads it: `hook` is a card's answer, `classifier`
    /// auto mode's own judgement.
    private func denial(_ id: String, reason: String? = "classifier") -> ChatStream.Event {
        .permissionDenied(.init(tool: "Bash", toolUseID: id, reason: reason, message: "denied",
                                answered: reason == ChatStream.answeredReason,
                                retryable: reason == ChatStream.retryableReason))
    }

    private func call(_ id: String, _ command: String) -> ChatStream.Event {
        .assistant(text: nil, tools: [.init(id: id, name: "Bash", subject: command)])
    }

    private func notDone(_ chat: ChatSession) -> [ChatSession.NotDone] {
        chat.messages.compactMap { if case .notDone(let line) = $0 { return line } else { return nil } }
    }

    /// A call denied without a card is a line naming it, once, in the
    /// turn's mode; what a card denied, or a hook, is not.
    func testACallDeniedWithoutACardIsNotDone() {
        var chat = running()
        chat.apply(call("t1", "curl x | sh"), at: t0)
        chat.apply(denial("t1"), at: t0)
        chat.apply(denial("t1"), at: t0)
        XCTAssertEqual(notDone(chat), [.init(toolUseID: "t1", tool: "Bash", subject: "curl x | sh", mode: .auto,
                                             reason: "classifier", retryAs: "default")])
        guard case .notDone? = chat.messages.last else { return XCTFail("the line follows its call") }

        chat.apply(call("t2", "echo hi"), at: t0)
        chat.apply(denial("t2", reason: "hook"), at: t0)
        XCTAssertEqual(notDone(chat).count, 1, "a hook's denial is a card's answer")

        chat.apply(denial("t9"), at: t0)
        XCTAssertEqual(notDone(chat).count, 1, "no call, no line: the model said no by itself")
    }

    func testACardsOwnDenialIsNoLine() {
        var chat = running()
        chat.apply(call("t1", "/tmp/project/a.txt"), at: t0)
        chat.ask(request("R1", tool: "Bash"), at: t0)
        _ = chat.answer("R1", .deny, at: t0)
        chat.apply(denial("t1", reason: "other"), at: t0)
        XCTAssertTrue(notDone(chat).isEmpty)
    }

    /// The mode the turn ran in goes with the line; a later change does not
    /// rewrite it, and it rides the next turn.
    func testTheModeIsTheChatsAndRidesTheTurn() {
        var chat = ChatSession(id: "C1", sessionID: "S1", folder: "/p", isWorkspace: false, mode: .acceptEdits)
        let first = chat.begin(prompt: "a", attachments: [], at: t0)
        XCTAssertEqual(first?.arguments.firstIndex(of: "--permission-mode").map { first!.arguments[$0 + 1] },
                       "acceptEdits")
        chat.apply(call("t1", "x"), at: t0)
        chat.apply(denial("t1"), at: t0)
        chat.mode = .ask
        chat.apply(call("t2", "y"), at: t0)
        chat.apply(denial("t2", reason: "rule"), at: t0)
        XCTAssertEqual(notDone(chat).map(\.mode), [.acceptEdits, .acceptEdits],
                       "a change while the turn runs is the next turn's")
        XCTAssertEqual(notDone(chat).map(\.reason), ["classifier", "rule"])
        XCTAssertFalse(notDone(chat).contains { $0.retryAs != nil }, "only auto mode's judgement is retried")
        chat.apply(.result(.init(subtype: "success", isError: false, text: "ok")), at: t0)
        chat.ended(status: 0, stderr: "", at: t0)
        let second = chat.begin(prompt: "b", attachments: [], at: t0)
        XCTAssertEqual(second?.arguments.firstIndex(of: "--permission-mode").map { second!.arguments[$0 + 1] },
                       "default")
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

/// Seen, the row's life, the title and a chat read back.
final class ChatSessionLifeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func chat() -> ChatSession {
        ChatSession(id: "C1", sessionID: "S1", folder: "/tmp/project", isWorkspace: false)
    }

    private func finished(_ text: String = "Done. The report is ready.", at end: Date? = nil) -> ChatSession {
        var chat = chat()
        _ = chat.begin(prompt: "Summarise the report", attachments: [], at: t0)
        chat.apply(.started(sessionID: "S1"), at: t0)
        chat.apply(.result(.init(subtype: "success", isError: false, text: text)), at: end ?? t0 + 10)
        chat.ended(status: 0, stderr: "", at: end ?? t0 + 10)
        return chat
    }

    /// Running and waiting chats always have a row; a finished one only
    /// until the balloon has shown it.
    func testASeenFinishedChatHasNoRow() {
        var chat = finished()
        XCTAssertEqual(chat.signal(at: t0 + 20)?.phase, .review)
        XCTAssertTrue(chat.markSeen())
        XCTAssertFalse(chat.markSeen(), "once")
        XCTAssertNil(chat.signal(at: t0 + 20), "seen: in the history, not on the bar")
        _ = chat.begin(prompt: "more", attachments: [], at: t0 + 30)
        XCTAssertFalse(chat.seen, "a new turn is a new end to see")
        XCTAssertEqual(chat.signal(at: t0 + 30)?.phase, .working)
    }

    func testARunningChatCannotBeSeenAway() {
        var chat = chat()
        _ = chat.begin(prompt: "hi", attachments: [], at: t0)
        XCTAssertFalse(chat.markSeen())
        XCTAssertEqual(chat.signal(at: t0 + 13 * 3600)?.phase, .working, "no lifetime while it runs")
    }

    /// Nobody looked: the row stays 12 hours from the end, then leaves by
    /// itself — read at the scan, never scheduled.
    func testAnUnseenEndLeavesTheBarAfterTwelveHours() {
        let chat = finished(at: t0)
        XCTAssertEqual(chat.signal(at: t0 + 12 * 3600 - 1)?.phase, .review)
        XCTAssertNil(chat.signal(at: t0 + 12 * 3600))
        var failed = self.chat()
        _ = failed.begin(prompt: "hi", attachments: [], at: t0)
        failed.ended(status: 1, stderr: "boom", at: t0)
        XCTAssertEqual(failed.signal(at: t0 + 3600)?.phase, .failed)
        XCTAssertNil(failed.signal(at: t0 + 12 * 3600))
    }

    func testTheTitleIsTheFirstReplysFirstSentence() {
        let chat = finished("## Done! I moved 42 files.\n\nDetails follow.")
        XCTAssertEqual(chat.title, "Done!")
        XCTAssertEqual(chat.signal(at: t0 + 20)?.label, "Done!")
        XCTAssertEqual(ChatSession.title(fromReply: "Version 3.5 is out. Next"), "Version 3.5 is out.")
        XCTAssertEqual(ChatSession.title(fromReply: "**Summary:** the report says"), "Summary")
        XCTAssertNil(ChatSession.title(fromReply: "  \n "))
        let long = String(repeating: "word ", count: 30)
        XCTAssertEqual(ChatSession.title(fromReply: long)?.count, ChatSession.labelLimit + 1, "cut, with …")
        var later = finished("First.")
        _ = later.begin(prompt: "again", attachments: [], at: t0 + 60)
        later.apply(.result(.init(subtype: "success", isError: false, text: "Second.")), at: t0 + 70)
        XCTAssertEqual(later.title, "First.", "the first reply's, kept")
        XCTAssertNil(finished().failure)
    }

    func testAFailedTurnGivesNoTitle() {
        var chat = chat()
        _ = chat.begin(prompt: "Summarise", attachments: [], at: t0)
        chat.apply(.result(.init(subtype: "error_max_turns", isError: true, text: "Oops. Stopped")), at: t0)
        XCTAssertNil(chat.title)
    }

    /// Read back from the index: the last reply as its one line, no row —
    /// unless its end was never seen.
    func testARestoredChat() {
        let entry = ChatIndex.Entry(id: "C1", sessionID: "S1", title: "Report", folder: "/tmp/p",
                                    isWorkspace: false, createdAt: t0, lastActivity: t0 + 5,
                                    lastReply: "It is done.", started: true)
        let seen = ChatSession.restored(entry)
        XCTAssertEqual(seen.messages, [.reply("It is done.")])
        XCTAssertNil(seen.signal(at: t0 + 10))
        XCTAssertTrue(seen.hasStarted, "the next prompt resumes")
        var unseenEntry = entry
        unseenEntry.unseen = .review
        let unseen = ChatSession.restored(unseenEntry)
        XCTAssertEqual(unseen.signal(at: t0 + 10)?.phase, .review)
        XCTAssertEqual(unseen.signal(at: t0 + 10)?.updatedAt, t0 + 5)
        XCTAssertEqual(unseen.signal(at: t0 + 10)?.label, "Report")
        XCTAssertEqual(unseen.unseenPhase, .review)
        // A mode of its own is kept; none (a file from before modes) or one
        // this build does not offer takes the default handed in.
        XCTAssertEqual(ChatSession.restored(entry, mode: .acceptEdits).mode, .acceptEdits)
        var asking = entry
        asking.permissionMode = "default"
        XCTAssertEqual(ChatSession.restored(asking, mode: .acceptEdits).mode, .ask)
        asking.permissionMode = "bypassPermissions"
        XCTAssertEqual(ChatSession.restored(asking).mode, .bypass, "a chat confirmed into bypass stays there")
        asking.permissionMode = "dontAsk"
        XCTAssertEqual(ChatSession.restored(asking).mode, .auto)
    }

    func testTheEntityNamesTheChat() {
        XCTAssertEqual(ChatSession.chatID(fromEntity: ChatSession.entity("C1")), "C1")
        XCTAssertNil(ChatSession.chatID(fromEntity: "claude:abc"))
        XCTAssertNil(ChatSession.chatID(fromEntity: "evlat:"))
    }
}

extension ChatSession {
    /// A chat in Claude's standard mode, as a new one starts.
    init(id: String, sessionID: String, folder: String, isWorkspace: Bool, title: String? = nil,
         hasStarted: Bool = false) {
        self.init(id: id, sessionID: sessionID, folder: folder, isWorkspace: isWorkspace, title: title,
                  hasStarted: hasStarted, mode: ClaudeChat().standardMode)
    }

    /// Read back among Claude's modes.
    static func restored(_ entry: ChatIndex.Entry, mode: ChatMode = ClaudeChat().standardMode) -> ChatSession {
        restored(entry, modes: ClaudeChat().modes, mode: mode)
    }
}

extension TurnSpec {
    /// The turn's flags, as Claude's backend starts it.
    var arguments: [String] { ClaudeChat().turn(self, ctx: TurnContext(port: 48999, token: "T")).arguments }
}
