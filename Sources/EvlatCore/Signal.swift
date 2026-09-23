import Foundation

/// One thing a source has to say. The app knows nothing about "AI sessions";
/// it knows `Signal`. Session tracking is the first provider behind this
/// abstraction, not the only one (ROADMAP → the seam).
public struct Signal: Equatable {
    public let provider: String
    /// What is being described, and the key rows are merged on. It identifies
    /// the **thing**, not the provider's view of it: the same session reaches
    /// Evlat from a file record and from a hook, and `Registry` reduces those
    /// to one row. For sessions it is the `sessionId`, which both sources see.
    public let entity: String
    public let kind: Kind
    public let phase: Phase
    /// 0…1. Sessions never produce this; a filled ring only appears once a
    /// provider supplies it.
    public let progress: Double?
    /// Short name, the one shown in the list.
    public let label: String
    public let detail: String?
    /// The tool the thing runs in, when it runs in one: which agent a session
    /// belongs to. Drawn, never decided on — a rule that branches on it is the
    /// finding `AgentSource` warns about. `nil` for signals that are not an
    /// agent's.
    public let source: AgentSource?
    public let fidelity: Fidelity
    /// The source's own word, untranslated. An unrecognised value stays
    /// **visible** here so `phase` cannot swallow it silently.
    ///
    /// Its absence carries weight too, and `Registry.admits` reads it: a row
    /// with no word never read one, so its `phase` is a fallback rather than a
    /// claim and it overrules nobody. A provider that has a word must therefore
    /// put it here, even one it does not understand.
    public let rawStatus: String?
    public let updatedAt: Date
    /// What the thing is doing, for the detail card: the facts behind the
    /// phase rather than the phase itself. `detail` stays the working
    /// directory; this is the card.
    ///
    /// **Not a phase, and not a new state.** It adds no `Phase` value, changes
    /// no priority and draws nothing on the bar, so the "three places" rule
    /// (priority, indicator language, mascot table) is not triggered. It also
    /// travels **independently of whether the phase was admitted**
    /// (`Registry.reconcile`): a report whose phase is vetoed still knows which
    /// tool ran.
    public let activity: Activity?

    public init(provider: String, entity: String, kind: Kind = .session,
                phase: Phase, progress: Double? = nil, label: String,
                detail: String? = nil, source: AgentSource? = nil, fidelity: Fidelity,
                rawStatus: String? = nil, updatedAt: Date, activity: Activity? = nil) {
        self.provider = provider
        self.entity = entity
        self.kind = kind
        self.phase = phase
        self.progress = progress
        self.label = label
        self.detail = detail
        self.source = source
        self.fidelity = fidelity
        self.rawStatus = rawStatus
        self.updatedAt = updatedAt
        self.activity = activity
    }

    /// The same signal with another activity. `Registry.reconcile` needs it on
    /// both of its branches: the phase decides which row stands, the activity
    /// is carried either way.
    public func with(activity: Activity?) -> Signal {
        Signal(provider: provider, entity: entity, kind: kind, phase: phase, progress: progress,
               label: label, detail: detail, source: source, fidelity: fidelity,
               rawStatus: rawStatus, updatedAt: updatedAt, activity: activity)
    }

    /// The card's data. Each field is `nil` when the source never said it;
    /// nothing is invented to fill one.
    ///
    /// **Kept small on purpose.** A tool's raw input is never stored — `Write`
    /// carries the whole file — only its one-line subject; the last reply is
    /// already cut to `HookEvent.replyLimit`. None of this is printed by
    /// `--list`, `NSLog` or the hook diagnostics.
    public struct Activity: Equatable {
        /// The agent's process, for finding its terminal. A file record knows
        /// it even when no hook has spoken yet.
        public var pid: Int32?
        /// The most recent tool the turn started, whoever in it started it.
        public var lastTool: Tool?
        /// The tool the user is being asked about. Taken from the event that
        /// put the block up, and it lives exactly as long as the block: a
        /// sibling subagent's tool moves `lastTool`, never this.
        public var blockingTool: Tool?
        /// What a block is waiting for. `nil` while nothing blocks.
        public var waitKind: WaitKind?
        /// The first paragraph of the turn's final reply, capped.
        public var lastReply: String?
        /// Tools started in the current turn, subagents' included. `nil` when
        /// the source does not count.
        public var toolCount: Int?
        /// The count began mid-turn, so it is a lower bound (`Fidelity`'s
        /// honesty: the card marks it rather than presenting it as the total).
        public var countIsPartial: Bool

        public init(pid: Int32? = nil, lastTool: Tool? = nil, blockingTool: Tool? = nil,
                    waitKind: WaitKind? = nil, lastReply: String? = nil,
                    toolCount: Int? = nil, countIsPartial: Bool = false) {
            self.pid = pid
            self.lastTool = lastTool
            self.blockingTool = blockingTool
            self.waitKind = waitKind
            self.lastReply = lastReply
            self.toolCount = toolCount
            self.countIsPartial = countIsPartial
        }

        /// A tool by its canonical name, with its one-line subject.
        public struct Tool: Equatable {
            public let name: String
            public let subject: String?

            public init(name: String, subject: String?) {
                self.name = name
                self.subject = subject
            }
        }

        /// Which answer a block expects: a yes/no on a tool, or words.
        public enum WaitKind: String, Equatable {
            case approval, answer
        }
    }

    public enum Kind: String, Equatable { case session, usage, job, custom }

    /// How solid a number is (codenotch's `Fidelity`). The UI never presents a
    /// guess as if a vendor had published it.
    public enum Fidelity: String, Equatable {
        /// The source's own documented output.
        case official
        /// Derived by Evlat, or read from an undocumented format.
        case derived
        /// Entered by hand.
        case manual
    }
}

/// The state machine. v1's five values carry over unchanged
/// (`SessionStore.Phase`).
///
/// **No sixth value was added**, and that is deliberate: every new value
/// changes the mascot's expression table, the bar's indicator language and the
/// aggregator priority all at once. An unrecognised source word stays visible
/// in `Signal.rawStatus` instead of polluting `Phase`. "Is any session live" is
/// likewise not a phase but a `Registry.hasLive` question.
public enum Phase: String, CaseIterable, Equatable {
    case idle, working, waiting, review, failed

    /// The mascot has one face and there are N sessions: this decides which
    /// one wins. Anything that blocks the user always comes forward.
    public var priority: Int {
        switch self {
        case .failed: return 4
        case .waiting: return 3
        case .working: return 2
        case .review: return 1
        case .idle: return 0
        }
    }
}
