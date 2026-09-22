import Foundation

/// Collects what the providers say and reduces it to a single view.
///
/// **No time-driven transitions live here, and none will.** v1 ran them on a
/// timer (`review`→`idle` after 25 s, stale-record pruning); in v2 the decay
/// belongs to the provider, derived at read time from the clock it already
/// holds, and dead rows leave through the liveness check rather than a pruning
/// pass. So `Snapshot` takes signals and never a clock, which is what keeps it
/// pure.
public final class Registry {
    private var providers: [Provider] = []

    public init() {}

    public func register(_ provider: Provider) {
        providers.append(provider)
    }

    /// One row per `entity`, merged across every provider.
    ///
    /// Two sources describe the same session: a file record discovers it, a
    /// hook reports what it is doing. Left unmerged the list simply doubles.
    ///
    /// The rule below reads `fidelity` and **never the provider's name**. A
    /// rule that branches on the source is a finding in this repo, and the
    /// reason is concrete: Codex ships no file record at all, so a rule phrased
    /// as "the file owns the list, the hook only refines it" would make Codex
    /// invisible the day it arrives.
    public func signals() -> [Signal] {
        // First-appearance order, so the same inputs always produce the same
        // list; display order is `Snapshot`'s job either way.
        var order: [String] = []
        var rows: [String: [Signal]] = [:]
        for signal in providers.flatMap({ $0.currentSignals() }) {
            if rows[signal.entity] == nil { order.append(signal.entity) }
            rows[signal.entity, default: []].append(signal)
        }
        return order.compactMap { rows[$0].flatMap(Self.reconcile) }
    }

    /// Reduces one entity's rows to the single line the bar shows.
    ///
    /// A `.derived` row is Evlat's own reading of an undocumented file: it
    /// proves the session exists and is alive, but its vocabulary is coarse —
    /// `waiting` has never been seen in one. An `.official` row is the source's
    /// own word: richer, and in practice the only place `waiting` comes from,
    /// but it can outlive the event that would have corrected it. Evlat was
    /// closed while the session finished, or an event simply never arrived, and
    /// the last thing the source said is still `working`.
    ///
    /// So the report is accepted only where the two can be true at once;
    /// otherwise the baseline stands. A **dead** session is not this rule's
    /// job and never reaches it: its file row is already gone on liveness, and
    /// a source that keeps no file drops its own row through the same check.
    /// What is left here is the live process whose report went stale.
    ///
    /// With no baseline the report passes untouched, and that branch is the
    /// whole of what a source without a file record gets.
    private static func reconcile(_ rows: [Signal]) -> Signal? {
        // Freshness breaks a tie only WITHIN one fidelity. Across fidelities it
        // decides nothing, deliberately: the file is rewritten while a prompt
        // is on screen, so it is *newer* than the hook's `waiting` exactly when
        // that `waiting` is the one thing worth showing.
        func newest(_ fidelity: Signal.Fidelity) -> Signal? {
            rows.filter { $0.fidelity == fidelity }.max { $0.updatedAt < $1.updatedAt }
        }
        // `.manual` has no producer and no row in the table, so it is a tail
        // rather than a participant: it answers only when nothing else
        // describes this entity at all. Whatever first writes it has to give
        // it a row of its own instead of inheriting this.
        guard let baseline = newest(.derived) else { return newest(.official) ?? newest(.manual) }
        guard let report = newest(.official) else { return baseline }
        return admits(baseline.phase, report.phase) ? report : baseline
    }

    /// Which reports a baseline can be reconciled with. `failed` sits in both
    /// rows because a run can fail out of either.
    ///
    /// A baseline outside those two rows admits nothing. The vocabulary
    /// measured on the only `.derived` source there is comes to `busy` and
    /// `idle` (plus `idle` for a word it does not know), so a rule for the rest
    /// would be a guess about a baseline nobody has observed.
    ///
    /// **Open, and known:** that parenthesis is the weak spot. `.idle` arrives
    /// both as "the file says idle" and as the fallback for a status word — or
    /// a whole field — that could not be read, and the second kind vetoes a
    /// report it has no business vetoing. Telling them apart needs a `Signal`
    /// that can say "I don't know", which is a change this set deliberately
    /// did not make before measuring; `002`'s hook provider closes it.
    private static func admits(_ baseline: Phase, _ report: Phase) -> Bool {
        switch baseline {
        case .working: return report == .waiting || report == .failed
        case .idle: return report == .review || report == .failed
        case .waiting, .review, .failed: return false
        }
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
