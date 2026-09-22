import Foundation

/// Collects what the providers say and reduces it to a single view.
///
/// **No time-driven transitions live here yet.** v1 has them (`review`→`idle`
/// after 25 s, stale-record pruning); this class will own them, but that is
/// `002`'s work. `Signal` carries `updatedAt` so the type can support them.
public final class Registry {
    private var providers: [Provider] = []

    public init() {}

    public func register(_ provider: Provider) {
        providers.append(provider)
    }

    /// Signals from every provider. The conflict rule is *between* providers
    /// and will land in `002` (hooks win); today there is a single provider, so
    /// nothing is merged here.
    public func signals() -> [Signal] {
        providers.flatMap { $0.currentSignals() }
    }

    /// Everything a caller needs from one scan.
    ///
    /// This type exists because the alternative kept losing: asking the
    /// registry for the aggregate and for `hasLive` separately re-reads the
    /// directory each time, so a file changing in between yields a summary that
    /// contradicts itself. Callers were inlining the reduce to avoid the second
    /// scan, which duplicated the aggregation rule at three sites — and the
    /// two copies that actually drove the UI were the ones the tests did not
    /// cover.
    public struct Snapshot: Equatable {
        /// Display order: waiting on top, then working, then recently finished,
        /// idle at the bottom. Most recent first on a tie.
        public let ordered: [Signal]
        /// The mascot's face. Highest `Phase.priority` wins; `idle` when there
        /// is nothing at all.
        public let aggregate: Phase
        /// Is anything live? **Not a phase**, a render condition: the mascot's
        /// blink and breath loops check this and leave the view tree when it is
        /// false (ROADMAP → Render yolu, idle drawing stops).
        public var hasLive: Bool { !ordered.isEmpty }

        public init(signals: [Signal]) {
            ordered = signals.sorted {
                $0.phase.priority != $1.phase.priority
                    ? $0.phase.priority > $1.phase.priority
                    : $0.updatedAt > $1.updatedAt
            }
            aggregate = signals.map(\.phase).max(by: { $0.priority < $1.priority }) ?? .idle
        }
    }

    /// One directory scan, every derived value. The only reading API callers
    /// should need.
    public func snapshot() -> Snapshot {
        Snapshot(signals: signals())
    }
}
