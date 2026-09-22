import Foundation

/// Turns hook events into phases. This is the provider the set exists for:
/// `waiting` has no other source, because a session record's vocabulary comes
/// to `busy` and `idle` and never says "this one is asking you something".
///
/// The event → phase core is v1's `SessionStore.handle` with everything else
/// removed — no bubbles, no voice lines, no motion, no tool summaries, no
/// subagent counters. What is left is the state machine and the two guards that
/// keep it honest (`stop_hook_active`, liveness).
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

    private let platform: Platform
    private var sessions: [String: Session] = [:]

    public init(platform: Platform) {
        self.platform = platform
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

    /// One event. Called on the main queue.
    public func handle(_ event: HookEvent) {
        // No id, no row. v1 filed every anonymous event under the placeholder
        // `"unknown"`, which merged them all onto a single line; `phase-2`
        // dropped the placeholder and it is not coming back.
        guard let entity = event.sessionID else { return }
        let effect = Self.effect(of: event)
        if effect == .end {
            sessions.removeValue(forKey: entity)
            return
        }
        guard var session = sessions[entity] else {
            // An event that says nothing about the phase opens no row: there
            // would be no phase to put in it.
            guard case .set(let phase) = effect else { return }
            sessions[entity] = Session(phase: phase, since: platform.now(),
                                       word: event.name, cwd: event.cwd,
                                       pid: event.pid,
                                       startedAt: event.pid.flatMap(platform.processStartedAt))
            return
        }

        // `cwd` is remembered rather than overwritten: it arrives on some
        // events and not others, and a row that blanked its own detail every
        // other event would flicker in the list.
        if let cwd = event.cwd { session.cwd = cwd }
        // `claude --resume` in another terminal moves the session to a new
        // process. Following it matters: keeping the first pid would have the
        // next scan call a live session dead. The start time is re-read with
        // the pid, since it is the pid's fact and not the session's.
        if let pid = event.pid, pid != session.pid {
            session.pid = pid
            session.startedAt = platform.processStartedAt(pid)
        }
        if case .set(let phase) = effect {
            session.phase = phase
            // The stamp belongs to the phase. An event that assigns none must
            // not restart the decay, or a `Notification` arriving a minute into
            // an idle session would spring `review` back to life.
            session.since = platform.now()
            session.word = event.name
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
        sessions = sessions.filter { isAlive($0.value) }
        return sessions.map { entity, session in
            Signal(
                provider: Self.id,
                entity: entity,
                kind: .session,
                phase: session.shownPhase(now: now),
                label: session.label(entity: entity),
                detail: session.cwd,
                fidelity: .official,
                // The source's own word for this phase — the event name. It
                // survives the decay on purpose: `review` reading as `idle`
                // later is Evlat's inference, and the thing the source actually
                // said stays on the row.
                rawStatus: session.word,
                updatedAt: session.since
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
    /// Without a pid there is nothing to compare, and every hook installed on
    /// this machine sends one (11 of 11 Claude, 8 of 8 Codex — measured in
    /// `phase-2`). The row is kept rather than dropped, for the same reason the
    /// helper trusts an unreadable start time: losing a live session over a
    /// missing field is worse than the ghost it prevents. Such an event is
    /// visible as `pid=-` under `--capture`.
    private func isAlive(_ session: Session) -> Bool {
        guard let pid = session.pid else { return true }
        return platform.sameProcess(pid: pid, startedAt: session.startedAt)
    }

    /// What this source knows about one session. Deliberately small: no tool
    /// name, no message, no subagent set — anything stored here would have to
    /// be un-stored by a later phase.
    private struct Session {
        var phase: Phase
        /// When the phase was assigned. Both the row's stamp and the decay read
        /// it, because they are the same fact.
        var since: Date
        /// The event name that assigned the phase.
        var word: String
        var cwd: String?
        var pid: Int32?
        /// The process start time as read at first sight of this pid.
        var startedAt: Date?

        /// The phase as of now. Only `review` decays: `waiting` and `failed`
        /// are the user's business and wait for an event that says otherwise,
        /// while `working` is corrected by the next event either way.
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
