import Foundation

/// Turns hook events into phases. This is the provider the set exists for:
/// `waiting` has no other source, because a session record's vocabulary comes
/// to `busy` and `idle` and never says "this one is asking you something".
///
/// The event → phase core is v1's `SessionStore.handle` with everything else
/// removed — no bubbles, no voice lines, no motion, no subagent counters. What
/// is left is the state machine, the two guards that keep it honest
/// (`stop_hook_active`, liveness), and since `005` the detail card's facts
/// (`Signal.Activity`): the turn's last tool and tool count, the tool a block
/// is about, and the last reply.
///
/// **Subagent events are not filtered** (`discussion.md` → Karar 8c). v1 fed
/// them to nothing at all; the rule was carried here as a trap ("the mascot
/// would flicker between the main thread and its subagents") whose reason was a
/// bubble that v2 does not draw. What settles it is measurement, not the
/// reasoning: in `phase-3`'s window 43 of 53 events carried an `agent_id`,
/// every one of them a tool event, and the subagent finished without ever
/// sending a `Stop` — `SubagentStop` is not among the eleven events installed.
/// A subagent's event carries the **parent's** `session_id` and the parent's
/// pid, so `working` on a parent that is already `working` changes nothing. The
/// case against the filter is stronger still: this repo's whole workflow runs
/// through subagents, and a filtered permission prompt is the product's one
/// promise failing in its most common scenario.
///
/// **A blocking phase remembers who put it up** (`mayApply`). That every
/// subagent event lands on the parent's row is what makes the filter needless;
/// it is also what lets a sibling subagent running in parallel undo a prompt it
/// knows nothing about. The two are separate questions and this is the answer
/// to the second one, not a reopening of the first.
///
/// **Not thread-safe, by design.** Events are delivered on the main queue and
/// `currentSignals()` is called there too (`Provider`'s contract).
public final class HooksProvider: Provider {
    public static let id = "hooks"
    public var id: String { Self.id }

    /// How long a finished turn stays `review` before it reads as `idle`.
    /// v1's number, and v1 reached it with `DispatchQueue.main.asyncAfter` plus
    /// a generation token to cancel the pending block. None of that is here:
    /// the decay is **derived at read time** from the clock this provider
    /// already holds, so there is no timer to leak, no token to get wrong, and
    /// a new event resets it by moving the stamp.
    public static let reviewDecay: TimeInterval = 25

    /// How long a row with no pid lives after the last thing it heard. With
    /// no process to ask, silence is the only evidence of death: a live
    /// tunnel delivers `SessionEnd`, so what leaks is a session killed
    /// outright or one that ended while no tunnel was up. Twelve hours
    /// bounds that leak on both sides, local and remote, without a count cap.
    public static let pidlessLifetime: TimeInterval = 12 * 3600

    /// How long a remote `working` row may stay quiet before it dims. A turn
    /// that is working sends a tool event every few seconds; half an hour of
    /// nothing is a session `kill -9` took with the tunnel still up. Only
    /// `working` dims this way: `idle` and `review` are quiet by nature, and
    /// `waiting`/`failed` are blocks that never lift on silence — locally
    /// either (`blocks`).
    public static let workingSilence: TimeInterval = 30 * 60

    private let platform: Platform
    private var sessions: [String: Session] = [:]
    /// The remote computer this instance hears through its tunnel; `nil` for
    /// this Mac's own port.
    private let machine: Signal.Machine.Identity?
    /// When the tunnel last came up; `nil` while it is down. Given from
    /// outside (`setLink`) because the tunnel is the shell's; the clock is
    /// still `platform.now()`.
    private var connectedSince: Date?

    /// `machine` makes this the provider for one remote computer: its rows
    /// are namespaced, carry no pid and are live only while the machine can
    /// be heard. Without it this is the local provider, unchanged for every
    /// row that has a pid.
    public init(platform: Platform, machine: Signal.Machine.Identity? = nil) {
        self.platform = platform
        self.machine = machine
    }

    /// The tunnel came up or went down. A repeated "up" keeps the first
    /// mark: confirming a link must not dim rows it has not reached yet.
    /// Meaningless on the local instance, and harmless there — its rows have
    /// no machine to be unreachable.
    public func setLink(connected: Bool) {
        if !connected { connectedSince = nil }
        else if connectedSince == nil { connectedSince = platform.now() }
    }

    /// What an event does to a session's phase.
    ///
    /// Kept as a value rather than folded into `handle` so the table can be
    /// read — and tested — as a table. `.none` is not "nothing happened": it is
    /// "this event says nothing about the phase", which is a different thing
    /// from `idle` and must not move the row or its stamp.
    enum Effect: Equatable {
        case set(Phase)
        case none
        case end
    }

    /// The canonical vocabulary only (Claude Code's); another source's body has
    /// already been through `AgentSource.canonical` by the time it is here.
    ///
    /// All eleven installed Claude events are covered, so the `default` branch
    /// is defensive: an event name this version does not know stays visible in
    /// the diagnostics and changes nothing here.
    static func effect(of event: HookEvent) -> Effect {
        switch event.name {
        case "SessionStart":
            return .set(.idle)
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .set(.working)
        case "PostToolUseFailure", "PermissionDenied":
            // A tool result means the permission question was answered and the
            // tool ran, so the wait is over. Without this an approved tool that
            // then failed would leave the session `waiting` for ever.
            return .set(.working)
        case "PermissionRequest":
            return .set(.waiting)
        case "Notification":
            // Only the types that actually block the user. `idle_prompt` is
            // Claude Code saying it is still there and says nothing about the
            // phase; reading it as one would drag a working session to idle.
            switch event.notificationType {
            case "permission_prompt", "elicitation_dialog",
                 "elicitation_url_dialog", "agent_needs_input":
                return .set(.waiting)
            default:
                return .none
            }
        case "Stop":
            // Set when the `Stop` hook is itself what continued the session.
            // Treating it as a real stop loops.
            return event.stopHookActive ? .none : .set(.review)
        case "StopFailure":
            return .set(.failed)
        case "SessionEnd":
            return .end
        default:
            return .none
        }
    }

    /// Phases the user cannot walk away from. They are the ones worth
    /// protecting — `working`, `idle` and `review` are corrected by the next
    /// event either way — and they are also the only two that never decay,
    /// which is why the phase alone says whether a block is standing and no
    /// separate "is blocked" flag is kept.
    private static func blocks(_ phase: Phase) -> Bool {
        phase == .waiting || phase == .failed
    }

    /// Events that speak for the **session** rather than for one actor's step,
    /// so they lift a block whoever put it up: a turn that has ended cannot
    /// still be waiting on a prompt, and a new user prompt could not have been
    /// typed while one was on screen. Without them a block whose owner goes
    /// quiet — a subagent that was killed mid-prompt — would hold the row for
    /// the rest of the turn.
    ///
    /// `SessionEnd` and `StopFailure` read the same way and are deliberately
    /// **not** listed, because neither would ever reach this set: the first
    /// removes the row before the question is asked, and the second sets a
    /// blocking phase, which is never refused.
    ///
    /// `SessionStart` is **not** listed either, and that one is open rather
    /// than settled: it would let a resumed session clear a block left by a
    /// subagent that is gone, but the same event is claimed to fire mid-turn
    /// on auto-compaction, where it would clear a block the user is still
    /// looking at. The premise is unmeasured, so the reach stays as it is
    /// (`phase-5` → `SessionStart` devri).
    private static let sessionLevel: Set<String> = ["Stop", "UserPromptSubmit"]

    /// May this event move the session off the phase it is in?
    ///
    /// The rule: **a blocking phase remembers who put it up, and only that
    /// actor — or an event about the session itself — may lift it.** The actor
    /// is already in the event: `agent_id` for a subagent, its absence for the
    /// main thread. Without this, sibling subagent B's routine `PostToolUse`
    /// paints the parent `working` while the user is still blocked on A's
    /// prompt, and A's prompt does not come again.
    ///
    /// **Putting a block up is never refused, only lifting one.** If A's prompt
    /// kept the row while B's arrived, answering A would read as `working` with
    /// B still holding the user. The newest blocking event owns the block, the
    /// same way `since` and `word` follow the last event that set a phase.
    ///
    /// The unmeasured limit of one owner: while A and B both wait, answering
    /// only B lifts the row, because A's ownership was overwritten. Modelling
    /// both would take a set of owners; the phase that blocks is the same
    /// either way, so what is lost is one row's accuracy after a partial
    /// answer, not the block itself.
    private static func mayApply(_ phase: Phase, from event: HookEvent,
                                 to session: Session) -> Bool {
        guard blocks(session.phase), !blocks(phase) else { return true }
        if sessionLevel.contains(event.name) { return true }
        return event.agentID == session.blockedBy
    }

    /// Which kind of wait a blocking event puts up, and on which tool, as a
    /// pair: both are written where `blockedBy` is, so all three share the
    /// block's lifetime. `keep` is the tool already on the block — a
    /// permission notification follows the request that named the tool and
    /// names none itself.
    private static func wait(for phase: Phase, from event: HookEvent,
                             keep: Signal.Activity.Tool?) -> (Signal.Activity.Tool?, Signal.Activity.WaitKind?) {
        guard phase == .waiting else { return (nil, nil) }
        switch event.name {
        case "PermissionRequest":
            return (tool(of: event), .approval)
        case "Notification" where event.notificationType == "permission_prompt":
            return (keep, .approval)
        default:
            return (keep, .answer)
        }
    }

    private static func tool(of event: HookEvent) -> Signal.Activity.Tool? {
        event.toolName.map { Signal.Activity.Tool(name: $0, subject: event.toolSubject) }
    }

    /// The turn's facts. Written **whether or not the phase was accepted**:
    /// `mayApply` guards the phase, and a sibling subagent's tool is still a
    /// tool this turn ran. What it cannot touch is the block's own tool, which
    /// is written with the phase.
    private static func record(_ event: HookEvent, in session: inout Session) {
        switch event.name {
        case "PreToolUse":
            // Subagents' tools included: they are part of the parent's turn.
            session.lastTool = tool(of: event)
            session.toolCount += 1
        case "UserPromptSubmit":
            session.toolCount = 0
            session.countIsPartial = false
            session.lastTool = nil
            session.lastReply = nil
        case "Stop" where !event.stopHookActive:
            session.lastReply = event.lastReply
        default:
            break
        }
    }

    /// One event. Called on the main queue.
    public func handle(_ event: HookEvent) {
        // No id, no row. v1 filed every anonymous event under the placeholder
        // `"unknown"`, which merged them all onto a single line; `phase-2`
        // dropped the placeholder and it is not coming back.
        guard let sessionID = event.sessionID else { return }
        let entity = machine.map { "remote:\($0.id):\(sessionID)" } ?? sessionID
        // A remote number means nothing on this Mac. `LocalAPI` already strips
        // it from a tunneled request; this is the second lock, so no remote
        // row can ever ask `processStartedAt` about a local stranger.
        let pid = machine == nil ? event.pid : nil
        let effect = Self.effect(of: event)
        if effect == .end {
            sessions.removeValue(forKey: entity)
            return
        }
        guard var session = sessions[entity] else {
            // An event that says nothing about the phase opens no row: there
            // would be no phase to put in it.
            guard case .set(let phase) = effect else { return }
            let (blockingTool, waitKind) = Self.wait(for: phase, from: event, keep: nil)
            var session = Session(phase: phase, since: platform.now(),
                                  word: event.name, source: event.source,
                                  cwd: event.cwd,
                                  pid: pid,
                                  startedAt: pid.flatMap(platform.processStartedAt),
                                  // The owner is recorded where the row is
                                  // opened too: a subagent's prompt is often
                                  // the first event of a session.
                                  blockedBy: Self.blocks(phase) ? event.agentID : nil,
                                  blockingTool: blockingTool, waitKind: waitKind,
                                  // A row opened mid-turn missed the turn's
                                  // start; `UserPromptSubmit` below clears it.
                                  countIsPartial: true)
            Self.record(event, in: &session)
            sessions[entity] = session
            return
        }

        // `cwd` is remembered rather than overwritten: it arrives on some
        // events and not others, and a row that blanked its own detail every
        // other event would flicker in the list.
        if let cwd = event.cwd { session.cwd = cwd }
        // Any event is proof of life, one that says nothing about the phase
        // included; `since` stays the phase's stamp.
        session.lastSeen = platform.now()
        // `claude --resume` in another terminal moves the session to a new
        // process. Following it matters: keeping the first pid would have the
        // next scan call a live session dead. The start time is re-read with
        // the pid, since it is the pid's fact and not the session's.
        if let pid, pid != session.pid {
            session.pid = pid
            session.startedAt = platform.processStartedAt(pid)
        }
        Self.record(event, in: &session)
        // The phase is what the guard refuses, not the event: the whereabouts
        // above are kept either way, because a row that sat out a prompt with a
        // stale `cwd` would be wrong about which project is blocked.
        if case .set(let phase) = effect, Self.mayApply(phase, from: event, to: session) {
            session.phase = phase
            // The stamp belongs to the phase. An event that assigns none must
            // not restart the decay, or a `Notification` arriving a minute into
            // an idle session would spring `review` back to life.
            session.since = platform.now()
            session.word = event.name
            // A phase that does not block clears the ownership with it, and
            // the block's tool and kind go the same way.
            session.blockedBy = Self.blocks(phase) ? event.agentID : nil
            (session.blockingTool, session.waitKind) =
                Self.wait(for: phase, from: event, keep: session.blockingTool)
        }
        sessions[entity] = session
    }

    public func currentSignals() -> [Signal] {
        let now = platform.now()
        // Dead rows are **removed**, not filtered out of the answer: this
        // dictionary is the only state the provider keeps, and a session that
        // `kill -9` took never sends `SessionEnd` to clear it (v1's own known
        // bug — the row lived as long as the app did). Hiding it instead would
        // grow the dictionary for the lifetime of the process.
        sessions = sessions.filter { isAlive($0.value, now: now) }
        return sessions.map { entity, session in
            let phase = session.shownPhase(now: now)
            return Signal(
                provider: Self.id,
                entity: entity,
                kind: .session,
                phase: phase,
                // The fallback is the session's own id, not the namespaced
                // key: a remote row without a `cwd` reads like a local one.
                label: session.label(entity: machine.map {
                    String(entity.dropFirst("remote:\($0.id):".count))
                } ?? entity),
                detail: session.cwd,
                source: session.source,
                fidelity: .official,
                // The source's own word for this phase — the event name. It
                // survives the decay on purpose: `review` reading as `idle`
                // later is Evlat's inference, and the thing the source actually
                // said stays on the row.
                rawStatus: session.word,
                // The stamp stays the phase's: the card's facts change at event
                // rate and must not look like a fresher state.
                updatedAt: session.since,
                activity: session.activity,
                machine: machine.map {
                    Signal.Machine(name: $0.name, reachable: reachable(session, phase: phase, now: now))
                }
            )
        }
        .sorted { $0.entity < $1.entity }  // deterministic; display order is the Registry's job
    }

    /// Is the process that sent these events still the same process?
    ///
    /// The shared helper, with this source's own origin for `startedAt`: it
    /// keeps no file record, so it compares what it read at **first sight**
    /// against what it reads now. A file-backed source hands over the start
    /// time its record *claims* instead — one comparison, two origins
    /// (`Platform.sameProcess`).
    ///
    /// Without a pid there is nothing to compare. Every hook installed on
    /// this machine sends one (11 of 11 Claude, 8 of 8 Codex — measured in
    /// `phase-2`), but a remote machine's rows never do. Such a row is trusted
    /// for as long as it keeps talking, for the same reason the helper trusts
    /// an unreadable start time — losing a live session over a missing field
    /// is worse than the ghost it prevents — and dropped after
    /// `pidlessLifetime` of silence, so the ghost is bounded. Such an event is
    /// visible as `pid=-` under `--capture`.
    private func isAlive(_ session: Session, now: Date) -> Bool {
        guard let pid = session.pid else {
            return now.timeIntervalSince(session.lastSeen) < Self.pidlessLifetime
        }
        return platform.sameProcess(pid: pid, startedAt: session.startedAt)
    }

    /// Can a remote row be taken as current? Derived at read time, three
    /// conditions: the tunnel is up; the row has been heard from since it came
    /// up — a session that ended while the tunnel was down sent its
    /// `SessionEnd` to nobody; and it is not a `working` row gone quiet
    /// (`workingSilence`).
    private func reachable(_ session: Session, phase: Phase, now: Date) -> Bool {
        guard let connectedSince, session.lastSeen >= connectedSince else { return false }
        return phase != .working || now.timeIntervalSince(session.lastSeen) < Self.workingSilence
    }

    /// What this source knows about one session. Deliberately small: the
    /// card's facts are stored already reduced (a tool's name and one-line
    /// subject, a capped reply), never the raw input or a transcript, and
    /// there is no subagent set.
    private struct Session {
        var phase: Phase
        /// When the phase was assigned. Both the row's stamp and the decay read
        /// it, because they are the same fact.
        var since: Date
        /// When any event last reached this row, a phaseless one included.
        /// What pidless liveness and remote reachability read; the row's
        /// stamp is still `since`.
        var lastSeen: Date
        /// The event name that assigned the phase.
        var word: String
        /// Which agent the session runs in: the source of the event that
        /// opened the row. A session does not change tools.
        let source: AgentSource
        var cwd: String?
        var pid: Int32?
        /// The process start time as read at first sight of this pid.
        var startedAt: Date?
        /// Who put up a blocking phase: the `agent_id` of the subagent whose
        /// event set it, or `nil` for the main thread — whose identity **is**
        /// the absence of one. Only read while `phase` blocks, so there is no
        /// third "nobody" case to tell apart from the main thread.
        var blockedBy: String?
        /// The tool the block is about, and what it waits for. Written only
        /// where `blockedBy` is, so they leave with the block.
        var blockingTool: Signal.Activity.Tool?
        var waitKind: Signal.Activity.WaitKind?
        var lastTool: Signal.Activity.Tool?
        var lastReply: String?
        var toolCount = 0
        var countIsPartial: Bool

        init(phase: Phase, since: Date, word: String, source: AgentSource, cwd: String?,
             pid: Int32?, startedAt: Date?, blockedBy: String?,
             blockingTool: Signal.Activity.Tool?, waitKind: Signal.Activity.WaitKind?,
             countIsPartial: Bool) {
            self.phase = phase
            self.since = since
            self.lastSeen = since
            self.word = word
            self.source = source
            self.cwd = cwd
            self.pid = pid
            self.startedAt = startedAt
            self.blockedBy = blockedBy
            self.blockingTool = blockingTool
            self.waitKind = waitKind
            self.countIsPartial = countIsPartial
        }

        var activity: Signal.Activity {
            Signal.Activity(pid: pid, lastTool: lastTool, blockingTool: blockingTool,
                            waitKind: waitKind, lastReply: lastReply,
                            toolCount: toolCount, countIsPartial: countIsPartial)
        }

        /// The phase as of now. Only `review` decays: `waiting` and `failed`
        /// are the user's business and wait for an event from whoever put them
        /// up (`mayApply`), while `working` is corrected by the next event
        /// either way.
        func shownPhase(now: Date) -> Phase {
            guard phase == .review, now.timeIntervalSince(since) >= HooksProvider.reviewDecay else {
                return phase
            }
            return .idle
        }

        /// The same fallback the file record uses, so the two rows do not
        /// disagree about what the session is called. The file's own `name` is
        /// the one thing a hook body does not carry.
        func label(entity: String) -> String {
            guard let cwd, !cwd.isEmpty else { return entity }
            let last = (cwd as NSString).lastPathComponent
            return last.isEmpty ? entity : last
        }
    }
}
