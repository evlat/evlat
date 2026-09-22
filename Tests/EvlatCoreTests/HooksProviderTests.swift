import XCTest
@testable import EvlatCore

/// The hook provider's contract: an event becomes a phase, a phase decays on
/// its own, and a row leaves when the process behind it does.
///
/// Headless, like every other provider test. Time and liveness are injected, so
/// the 25 s decay is asserted in microseconds and `kill -9` is a closure.
final class HooksProviderTests: XCTestCase {
    /// A clock the test moves by hand. `Platform.now` is a closure precisely so
    /// a time-dependent rule can be pinned instead of waited out.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private var clock = Clock()

    override func setUp() {
        super.setUp()
        clock = Clock()
    }

    private func provider(alive: @escaping (Int32) -> Bool = { _ in true },
                          startedAt: @escaping (Int32) -> Date? = { _ in nil }) -> HooksProvider {
        HooksProvider(platform: Platform(isAlive: alive,
                                         processStartedAt: startedAt,
                                         now: { [clock] in clock.now }))
    }

    /// A body shaped like the ones measured on the wire (`phase-3`): the pid
    /// arrives as text, because the header it is written from is text.
    private func event(_ name: String, session: String? = "s-1", cwd: String? = "/tmp/project",
                       agent: String? = nil, notification: String? = nil,
                       stopHookActive: Bool = false, pid: Int32? = 4242,
                       source: AgentSource = .claude) -> HookEvent {
        var json: [String: Any] = ["hook_event_name": name]
        if let session { json["session_id"] = session }
        if let cwd { json["cwd"] = cwd }
        if let agent { json["agent_id"] = agent }
        if let notification { json["notification_type"] = notification }
        if stopHookActive { json["stop_hook_active"] = true }
        if let pid { json[HookEvent.pidKey] = String(pid) }
        return HookEvent(json: json, source: source)
    }

    private func phase(after names: [String], in provider: HooksProvider) -> Phase? {
        for name in names { provider.handle(event(name)) }
        return provider.currentSignals().first?.phase
    }

    // MARK: - Event → phase

    /// v1's `SessionStore.handle` core, written out cell by cell. All eleven
    /// installed Claude events appear here or in the tests below; nothing in the
    /// installed set falls through to the unknown branch.
    func testTheEventTable() {
        let table: [(String, Phase)] = [
            ("SessionStart", .idle),
            ("UserPromptSubmit", .working),
            ("PreToolUse", .working),
            ("PostToolUse", .working),
            // The tool ran, so the permission question is answered: without
            // this the session stays `waiting` after a tool that was approved
            // and then failed.
            ("PostToolUseFailure", .working),
            ("PermissionDenied", .working),
            ("PermissionRequest", .waiting),
            ("Stop", .review),
            ("StopFailure", .failed),
        ]
        for (name, expected) in table {
            let hooks = provider()
            XCTAssertEqual(phase(after: [name], in: hooks), expected, name)
        }
    }

    /// Which `Notification` blocks the user is the notification *type*'s
    /// question, not the event's.
    func testBlockingNotificationsWait() {
        for type in ["permission_prompt", "elicitation_dialog",
                     "elicitation_url_dialog", "agent_needs_input"] {
            let hooks = provider()
            hooks.handle(event("Notification", notification: type))
            XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting, type)
        }
    }

    /// `idle_prompt` is Claude Code telling the user it is still there. It says
    /// nothing about the phase, and a rule that read it as one would drag a
    /// working session to idle on a timer nobody set.
    func testANonBlockingNotificationLeavesThePhaseAlone() {
        let hooks = provider()
        hooks.handle(event("UserPromptSubmit"))
        hooks.handle(event("Notification", notification: "idle_prompt"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working)
    }

    func testAnUnknownEventNeitherOpensARowNorMovesOne() {
        let hooks = provider()
        hooks.handle(event("SomethingNewInTheNextRelease"))
        XCTAssertTrue(hooks.currentSignals().isEmpty, "an unknown word opens no row")

        hooks.handle(event("PermissionRequest"))
        hooks.handle(event("SomethingNewInTheNextRelease"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting,
                       "and it does not move one either")
    }

    /// Claude Code sets `stop_hook_active` when the `Stop` hook is itself what
    /// continued the session. Treating that as a real stop loops.
    func testStopHookActiveIsNotAStop() {
        let hooks = provider()
        hooks.handle(event("UserPromptSubmit"))
        hooks.handle(event("Stop", stopHookActive: true))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working)
    }

    func testSessionEndRemovesTheRow() {
        let hooks = provider()
        hooks.handle(event("UserPromptSubmit"))
        XCTAssertEqual(hooks.currentSignals().count, 1)
        hooks.handle(event("SessionEnd"))
        XCTAssertTrue(hooks.currentSignals().isEmpty)
    }

    /// v1 gave an event with no id the placeholder `"unknown"`, which quietly
    /// merged every such event onto one row. `phase-2` dropped the placeholder;
    /// the event is dropped with it.
    func testAnEventWithoutASessionIdIsDropped() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", session: nil))
        XCTAssertTrue(hooks.currentSignals().isEmpty)
    }

    // MARK: - Subagents (Karar 8c)

    /// The filter is **gone**, and this is the tripwire. Measured in `phase-3`:
    /// 43 of 53 events carried an `agent_id`, all of them tool events, and the
    /// subagent produced no `Stop` at all — `SubagentStop` is not installed. A
    /// subagent's event carries the **parent's** `session_id`, so `working` on
    /// a parent that is already `working` is idempotent.
    func testASubagentToolEventReachesTheParentRow() {
        let hooks = provider()
        hooks.handle(event("UserPromptSubmit"))
        hooks.handle(event("PreToolUse", agent: "a7a6733d11250a71f"))
        let rows = hooks.currentSignals()
        XCTAssertEqual(rows.count, 1, "the subagent has no row of its own")
        XCTAssertEqual(rows.first?.phase, .working)
        XCTAssertEqual(rows.first?.entity, "s-1", "it lands on the parent's session")
    }

    // MARK: - Who may lift a block

    /// The scenario this rule exists for, and the one this repo runs all day:
    /// subagent A stops on a permission prompt while sibling B keeps working.
    /// Both events land on the **parent's** row, so without an owner B's
    /// routine tool event would paint the parent `working` while the user is
    /// still blocked on A.
    func testOnlyTheActorThatBlockedCanLiftTheBlock() {
        let hooks = provider()
        hooks.handle(event("UserPromptSubmit"))
        hooks.handle(event("PermissionRequest", agent: "agent-a"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting)

        hooks.handle(event("PostToolUse", agent: "agent-b"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting,
                       "B's tool event says nothing about A's prompt")

        hooks.handle(event("PostToolUse", agent: "agent-a"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working,
                       "A was answered, so A's own next event lifts it")
    }

    /// The main thread is an actor too, and the **absence** of an `agent_id` is
    /// its identity. No subagent may lift a prompt the main thread put up.
    func testASubagentCannotLiftTheMainThreadsBlock() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest"))
        hooks.handle(event("PostToolUse", agent: "agent-b"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting)

        hooks.handle(event("PostToolUse"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working)
    }

    /// The owner is recorded where the row is **opened** too, not only where an
    /// existing row moves: a subagent's prompt is often the first thing Evlat
    /// hears about a session.
    func testABlockThatOpensTheRowRemembersItsOwner() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", agent: "agent-a"))
        hooks.handle(event("PostToolUse", agent: "agent-b"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting)
    }

    /// `failed` blocks the user exactly as `waiting` does, so it is guarded the
    /// same way. (These are also the only two phases that never decay, which is
    /// why the phase alone can say whether a block is standing.)
    func testAFailedPhaseIsGuardedLikeAWait() {
        let hooks = provider()
        hooks.handle(event("StopFailure"))
        hooks.handle(event("PostToolUse", agent: "agent-b"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .failed)
    }

    /// Putting a block up is never refused — only lifting one is. If A's prompt
    /// kept the row while B's arrived, answering A would show `working` with B
    /// still waiting.
    func testTheNewestBlockOwnsTheRow() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", agent: "agent-a"))
        hooks.handle(event("PermissionRequest", agent: "agent-b"))
        hooks.handle(event("PostToolUse", agent: "agent-a"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .waiting,
                       "A was answered; B still has the user")

        hooks.handle(event("PostToolUse", agent: "agent-b"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working)
    }

    /// Events that speak for the **session** rather than for one actor's step
    /// lift any block, whoever put it up. A turn that has ended cannot still be
    /// waiting on a prompt, and a new user prompt could not have been typed
    /// while one was on screen.
    func testASessionLevelEventLiftsAnyBlock() {
        for (name, expected) in [("Stop", Phase.review), ("StopFailure", .failed),
                                 ("UserPromptSubmit", .working)] {
            let hooks = provider()
            hooks.handle(event("PermissionRequest", agent: "agent-a"))
            hooks.handle(event(name))
            XCTAssertEqual(hooks.currentSignals().first?.phase, expected, name)
        }
    }

    func testSessionEndRemovesTheRowWhoeverBlockedIt() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", agent: "agent-a"))
        hooks.handle(event("SessionEnd"))
        XCTAssertTrue(hooks.currentSignals().isEmpty)
    }

    /// The guard refuses the **phase**, not the event: a refused event still
    /// carries whereabouts, and a row that waited out a prompt with a stale
    /// `cwd` would be wrong about which project is blocked.
    func testARefusedEventStillUpdatesTheRowsWhereabouts() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", cwd: nil))
        hooks.handle(event("PostToolUse", cwd: "/tmp/second", agent: "agent-b"))
        let row = hooks.currentSignals().first
        XCTAssertEqual(row?.phase, .waiting)
        XCTAssertEqual(row?.detail, "/tmp/second")
    }

    // MARK: - review → idle, with no timer anywhere

    func testReviewDecaysAtReadTime() {
        let hooks = provider()
        hooks.handle(event("Stop"))
        clock.now += HooksProvider.reviewDecay - 1
        XCTAssertEqual(hooks.currentSignals().first?.phase, .review)

        clock.now += 2
        let row = hooks.currentSignals().first
        XCTAssertEqual(row?.phase, .idle, "derived from the clock, not from a timer")
        XCTAssertEqual(row?.rawStatus, "Stop",
                       "the row stays: dropping it would take the source's own word with it")
    }

    /// The stamp belongs to the phase, not to the traffic. An event that
    /// assigns no phase must not restart the decay — `Notification` is
    /// installed and arrives while a session sits idle.
    func testANoOpEventDoesNotRestartTheDecay() {
        let hooks = provider()
        hooks.handle(event("Stop"))
        clock.now += HooksProvider.reviewDecay + 5
        hooks.handle(event("Notification", notification: "idle_prompt"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .idle,
                       "a decayed review must not spring back to review")
    }

    func testANewEventResetsTheStamp() {
        let hooks = provider()
        hooks.handle(event("Stop"))
        clock.now += HooksProvider.reviewDecay + 5
        hooks.handle(event("UserPromptSubmit"))
        XCTAssertEqual(hooks.currentSignals().first?.phase, .working)
        XCTAssertEqual(hooks.currentSignals().first?.updatedAt, clock.now)
    }

    /// Only `review` decays. `failed` and `waiting` are the user's business and
    /// wait for an event that says otherwise.
    func testNoOtherPhaseDecays() {
        for name in ["StopFailure", "PermissionRequest", "UserPromptSubmit"] {
            let hooks = provider()
            let before = phase(after: [name], in: hooks)
            clock.now += 3_600
            XCTAssertEqual(hooks.currentSignals().first?.phase, before, name)
        }
    }

    // MARK: - Liveness

    /// The reason this provider watches pids at all: `kill -9` sends no
    /// `SessionEnd`, so without the check the row would live as long as Evlat
    /// does (v1's own known bug).
    func testAKilledSessionLeavesNoGhostRow() {
        var running = true
        let hooks = provider(alive: { _ in running })
        hooks.handle(event("UserPromptSubmit"))
        XCTAssertEqual(hooks.currentSignals().count, 1)
        running = false
        XCTAssertTrue(hooks.currentSignals().isEmpty, "no SessionEnd is coming")
    }

    /// A dropped row is forgotten, not merely hidden: the dictionary is the
    /// only thing this provider keeps and it would otherwise grow for the
    /// lifetime of the process.
    func testADroppedRowIsForgotten() {
        var running = true
        let hooks = provider(alive: { _ in running })
        hooks.handle(event("PermissionRequest"))
        running = false
        XCTAssertTrue(hooks.currentSignals().isEmpty)
        running = true
        XCTAssertTrue(hooks.currentSignals().isEmpty, "a pid coming back is a different process")
    }

    /// macOS recycles pids. This source keeps no record of its own, so it
    /// measures the start time it read at **first sight** against the next
    /// reading — the same helper, a different origin (`Platform.sameProcess`).
    func testARecycledPidDropsTheRow() {
        var start = Date(timeIntervalSince1970: 1_790_000_000)
        let hooks = provider(startedAt: { _ in start })
        hooks.handle(event("UserPromptSubmit"))
        XCTAssertEqual(hooks.currentSignals().count, 1)
        start = start.addingTimeInterval(86_400)
        XCTAssertTrue(hooks.currentSignals().isEmpty, "another process owns that pid now")
    }

    func testASteadyStartTimeKeepsTheRow() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let hooks = provider(startedAt: { _ in start })
        hooks.handle(event("UserPromptSubmit"))
        XCTAssertEqual(hooks.currentSignals().count, 1)
    }

    /// Every hook installed on this machine sends `X-Evlat-Pid` (11 of 11
    /// Claude, 8 of 8 Codex, measured in `phase-2`). An event without one
    /// cannot be checked, and the repo's answer to an unprovable check is to
    /// trust it (`Platform.sameProcess`): dropping a live session over a
    /// missing field is worse than the ghost it prevents.
    func testAnEventWithoutAPidIsKept() {
        let hooks = provider(alive: { _ in false })
        hooks.handle(event("PermissionRequest", pid: nil))
        XCTAssertEqual(hooks.currentSignals().count, 1)
    }

    // MARK: - The shape of the row

    func testTheRowIsOfficialAndKeepsTheSourcesOwnWord() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest"))
        let row = hooks.currentSignals().first
        XCTAssertEqual(row?.provider, HooksProvider.id)
        XCTAssertEqual(row?.entity, "s-1")
        XCTAssertEqual(row?.kind, .session)
        XCTAssertEqual(row?.fidelity, .official, "the source's own documented output")
        XCTAssertEqual(row?.rawStatus, "PermissionRequest")
        XCTAssertNil(row?.progress)
        XCTAssertEqual(row?.updatedAt, clock.now)
    }

    /// The label follows the **same fallback** as the file record's, so the two
    /// rows do not disagree about what the session is called (the file's `name`
    /// is the one thing a hook body does not carry — see the phase notes).
    func testTheLabelFollowsTheFileRecordsFallback() {
        let hooks = provider()
        hooks.handle(event("PreToolUse", cwd: "/Users/x/Projects/kararla"))
        XCTAssertEqual(hooks.currentSignals().first?.label, "kararla")
        XCTAssertEqual(hooks.currentSignals().first?.detail, "/Users/x/Projects/kararla")
    }

    func testWithoutACwdTheSessionIdIsTheLabel() {
        let hooks = provider()
        hooks.handle(event("PreToolUse", cwd: nil))
        XCTAssertEqual(hooks.currentSignals().first?.label, "s-1")
        XCTAssertNil(hooks.currentSignals().first?.detail)
    }

    /// A later event fills in a `cwd` the first one lacked, and never blanks
    /// one that was already there.
    func testTheCwdIsRememberedAndRefreshed() {
        let hooks = provider()
        hooks.handle(event("SessionStart", cwd: nil))
        hooks.handle(event("PreToolUse", cwd: "/tmp/first"))
        hooks.handle(event("PostToolUse", cwd: nil))
        XCTAssertEqual(hooks.currentSignals().first?.detail, "/tmp/first")
    }

    /// Two sessions, two rows, and a source that keeps no file record still
    /// gets one — the merge never learns a source name, so this provider must
    /// not either.
    func testEachSessionKeepsItsOwnRow() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", session: "claude-1"))
        hooks.handle(event("UserPromptSubmit", session: "codex-1", source: .codex))
        let rows = hooks.currentSignals()
        XCTAssertEqual(rows.map(\.entity).sorted(), ["claude-1", "codex-1"])
        XCTAssertEqual(Set(rows.map(\.provider)), [HooksProvider.id])
    }

    /// `claude --resume` in another terminal moves the session to a new
    /// process. The row follows the pid it is now hearing from; if it kept the
    /// first one, the next scan would call a live session dead.
    func testTheRowFollowsTheSessionToANewProcess() {
        var living: Set<Int32> = [4242]
        let hooks = provider(alive: { living.contains($0) })
        hooks.handle(event("UserPromptSubmit"))
        living = [5555]
        hooks.handle(event("UserPromptSubmit", pid: 5555))
        XCTAssertEqual(hooks.currentSignals().count, 1)
    }

    // MARK: - Through the registry

    /// The whole point of the set, exercised end to end in the pure layer: a
    /// file record says the session is busy, the hook says it is waiting on the
    /// user, and one row comes out saying `waiting`.
    func testAWaitingReportReachesTheBarThroughTheMergeRule() {
        let hooks = provider()
        hooks.handle(event("PermissionRequest", session: "s-1"))
        let file = Signal(provider: "claude-sessions", entity: "s-1", phase: .working,
                          label: "kararla-cf", fidelity: .derived, rawStatus: "busy",
                          updatedAt: clock.now)
        let registry = Registry()
        registry.register(StubProvider(id: "file", signals: [file]))
        registry.register(hooks)
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.ordered.count, 1, "one session, one row")
        XCTAssertEqual(snapshot.aggregate, .waiting)
    }
}

/// Says exactly what the test hands it; it carries no source-specific
/// behaviour, because no rule downstream is allowed to see one.
struct StubProvider: Provider {
    let id: String
    let signals: [Signal]
    func currentSignals() -> [Signal] { signals }
}
