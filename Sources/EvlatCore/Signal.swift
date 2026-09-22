import Foundation

/// One thing a source has to say. The app knows nothing about "AI sessions";
/// it knows `Signal`. Session tracking is the first provider behind this
/// abstraction, not the only one (ROADMAP → the seam).
public struct Signal: Equatable {
    public let provider: String
    /// Unique within a provider. For sessions this is the `sessionId`.
    public let entity: String
    public let kind: Kind
    public let phase: Phase
    /// 0…1. Sessions never produce this; a filled ring only appears once a
    /// provider supplies it.
    public let progress: Double?
    /// Short name, the one shown in the list.
    public let label: String
    public let detail: String?
    public let fidelity: Fidelity
    /// The source's own word, untranslated. An unrecognised value stays
    /// **visible** here so `phase` cannot swallow it silently.
    public let rawStatus: String?
    public let updatedAt: Date

    public init(provider: String, entity: String, kind: Kind = .session,
                phase: Phase, progress: Double? = nil, label: String,
                detail: String? = nil, fidelity: Fidelity,
                rawStatus: String? = nil, updatedAt: Date) {
        self.provider = provider
        self.entity = entity
        self.kind = kind
        self.phase = phase
        self.progress = progress
        self.label = label
        self.detail = detail
        self.fidelity = fidelity
        self.rawStatus = rawStatus
        self.updatedAt = updatedAt
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
