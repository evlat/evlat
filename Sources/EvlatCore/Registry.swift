import Foundation

/// One finish, as the user can have seen it: which row, how it ended, and
/// when. The **stamp is part of the key**. With the entity alone a row that
/// went `working → review` twice between two polls would read its second
/// finish as already seen; with the stamp it is new news. Every producer's
/// `updatedAt` is the moment its phase began, so the key holds still for as
/// long as the finish does — and a merge that vetoes the report for a while
/// gets the same key back once the veto lifts (`Registry.reconcile` passes
/// the report's own stamp).
public struct Finish: Hashable {
    public let entity: String
    public let phase: Phase
    public let updatedAt: Date

    public init(entity: String, phase: Phase, updatedAt: Date) {
        self.entity = entity
        self.phase = phase
        self.updatedAt = updatedAt
    }

    /// The finish this row is, if it is one: `review` or `failed`.
    public init?(_ signal: Signal) {
        guard signal.phase == .review || signal.phase == .failed else { return nil }
        self.init(entity: signal.entity, phase: signal.phase, updatedAt: signal.updatedAt)
    }
}

/// Collects what the providers say and reduces it to a single view.
///
/// **No time-driven transitions live here, and none will.** v1 ran them on a
/// timer (`review`→`idle` after 25 s, stale-record pruning). Here no phase
/// moves on a clock at all: a finish stays until the user has seen it (an
/// input to `Snapshot`), a row's life is read by its provider from the clock
/// it already holds, and dead rows leave through the liveness check rather
/// than a pruning pass. So `Snapshot` takes signals and never a clock, which is what keeps it
/// pure.
public final class Registry {
    private var providers: [Provider] = []

    public init() {}

    public func register(_ provider: Provider) {
        providers.append(provider)
    }

    /// Takes one provider **object** out — a remote machine removed takes its
    /// rows with it. By identity, not by `id`: every machine's hook provider
    /// shares the local one's id.
    public func unregister(_ provider: AnyObject) {
        providers.removeAll { ($0 as AnyObject) === provider }
    }

    /// Asks every `Reloadable` provider to read its source again. The caller
    /// picks the moment (the bar opening); which providers answer is theirs to
    /// say, not the caller's to know.
    public func reload() {
        for provider in providers {
            (provider as? Reloadable)?.reload()
        }
    }

    /// Hands the seen finishes to every `Releasable` provider; which rows
    /// that drops is theirs to say (`Releasable`), and a provider that keeps
    /// none is not asked.
    public func release(_ finishes: Set<Finish>) {
        guard !finishes.isEmpty else { return }
        for provider in providers {
            (provider as? Releasable)?.release(finishes)
        }
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
    /// An admitted report supplies the phase and everything that moves with it
    /// (stamp, `detail`, provider), but **the name stays the baseline's**. The
    /// hook body carries no session name, so a report-owned label falls back to
    /// the folder — different from the file's name in 17 of 22 live records —
    /// and the row renamed itself the moment it turned `waiting`. `detail`
    /// deliberately follows the report: the hook keeps `cwd` fresh and the file
    /// is not written at event rate. A report that has no `cwd` yet (it only
    /// learns one from an event that carries it) keeps the baseline's.
    ///
    /// **`activity` is not admitted, it is carried**. The rule above
    /// is about the phase; a report whose phase is vetoed still knows which
    /// tool ran, and in practice that is most reports — a `working` hook next
    /// to a `busy` file is refused, and so is a `waiting` beside an `idle`
    /// file. So the row's activity is the report's on
    /// both branches, with the baseline's pid when the report has none; with no
    /// report it is the baseline's. Only its wait is tied to the phase: a row
    /// that does not wait shows no block (`shown`). This narrows "a rejected report leaves no
    /// trace" to the phase, the name, `detail` and the stamp.
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
        // `.manual` has no row in the table, and that is the rule rather than
        // a debt: **a `.manual` row stands only where it is alone.** Beside a
        // `.derived` or an `.official` row of the same entity it wins nothing
        // — not the phase, not the name. Its producer (`/signal`)
        // never meets one anyway: its entities are `signal:`-prefixed, and
        // no other producer writes that prefix (`Signal.entity`).
        guard let baseline = newest(.derived) else { return newest(.official) ?? newest(.manual) }
        guard let report = newest(.official) else { return baseline }
        let activity = carried(report.activity, baseline.activity)
        // The machine is where the thing runs, not a claim about its phase,
        // so it rides along on both branches like the activity does.
        let machine = report.machine ?? baseline.machine
        guard admits(baseline, report.phase) else {
            return baseline.with(activity: activity.map { shown($0, on: baseline.phase) })
                .with(machine: machine)
        }
        return Signal(provider: report.provider, entity: report.entity, kind: report.kind,
                      phase: report.phase, progress: report.progress, label: baseline.label,
                      detail: report.detail ?? baseline.detail,
                      source: report.source ?? baseline.source, fidelity: report.fidelity,
                      rawStatus: report.rawStatus, updatedAt: report.updatedAt,
                      activity: activity.map { shown($0, on: report.phase) },
                      usage: report.usage ?? baseline.usage, machine: machine,
                      sender: report.sender ?? baseline.sender)
    }

    /// A wait belongs to a row that waits. A refused report is a stale one
    /// more often than not — a `waiting` whose answer never reached Evlat — and
    /// its block would otherwise ask the card for an approval nobody is asking
    /// for. The turn's facts (last tool, count, reply) are not tied to a
    /// phase and stay.
    private static func shown(_ activity: Signal.Activity, on phase: Phase) -> Signal.Activity {
        guard phase != .waiting else { return activity }
        var shown = activity
        shown.blockingTool = nil
        shown.waitKind = nil
        return shown
    }

    /// The report's activity, with the baseline's pid when it has none of its
    /// own; the baseline's when the report has no activity at all. A pid the
    /// report does have wins: `claude --resume` moves a session to a new
    /// process before the file record catches up.
    private static func carried(_ report: Signal.Activity?,
                                _ baseline: Signal.Activity?) -> Signal.Activity? {
        guard var activity = report else { return baseline }
        if activity.pid == nil { activity.pid = baseline?.pid }
        return activity
    }

    /// Which reports a baseline can be reconciled with. `failed` sits in both
    /// rows because a run can fail out of either.
    ///
    /// A baseline outside those two rows admits nothing. The vocabulary
    /// measured on the only `.derived` source there is comes to `busy` and
    /// `idle` (plus `idle` for a word it does not know), so a rule for the rest
    /// would be a guess about a baseline nobody has observed.
    ///
    /// **A baseline with no word of its own asserts nothing**, and that is the
    /// first thing checked. `.idle` used to arrive with two meanings — "the
    /// file says idle" and "nothing could be read, so idle it is" — and the
    /// second kind vetoed reports it had no business vetoing. It is not a
    /// hypothetical: a new session record exists for about 500 ms with no
    /// `status` field at all (measured), and the day that field is
    /// renamed every row would read `idle` with no hook able to correct it.
    ///
    /// Telling the two apart needs no new `Signal` field: `rawStatus` is
    /// already "the source's own word", and a row that read no word has none.
    /// The rule stays blind to provider names, as it must.
    ///
    /// What is **not** covered, deliberately: a word that was read but not
    /// recognised still lands on `.idle` and still vetoes. It is a statement
    /// from the source rather than an absence, it stays visible on the row and
    /// in `unrecognizedStatuses`, and it has been seen exactly once on this
    /// machine (`"shell"`).
    private static func admits(_ baseline: Signal, _ report: Phase) -> Bool {
        guard baseline.rawStatus != nil else { return true }
        switch baseline.phase {
        case .working: return report == .waiting || report == .failed
        case .idle: return report == .review || report == .failed
        case .waiting, .review, .failed: return false
        }
    }

    /// Where a row stands. **Not a `Phase` and not a `Signal` field**: it is
    /// derived here, from the phase and from what the user has seen, and
    /// nowhere else — the list sorts by it and the face reads only its active
    /// part, so the two cannot disagree.
    ///
    /// `waiting`, `working` and `news` are **active**; `passive` is a finish
    /// already seen, or a row with nothing to say (`idle`). The case order is
    /// the list's order.
    public enum Layer: Int, Comparable {
        case waiting, working, news, passive

        public var isActive: Bool { self != .passive }

        public static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }

        /// A finish is news until its key is in `seen`.
        static func of(_ signal: Signal, seen: Set<Finish>) -> Layer {
            switch signal.phase {
            case .waiting: return .waiting
            case .working: return .working
            case .review, .failed: return Finish(signal).map(seen.contains) == true ? .passive : .news
            case .idle: return .passive
            }
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
    ///
    /// **What the user has seen is an input, never state.** "Seeing" is a UI
    /// fact; the shell keeps the set and hands it in, the rule that reads it
    /// lives here and is tested without a window. No clock either.
    public struct Snapshot: Equatable {
        /// Display order: live rows first, dimmed ones (`Signal.isLive`) under
        /// them. Within each part by `Layer` — waiting, working, news,
        /// passive — news newest finish first; any other tie by `entity`:
        /// stable, never by a stamp that moves while the phase holds.
        public let ordered: [Signal]
        /// Every row's layer, by `entity`.
        public let layers: [String: Layer]
        /// The live rows' news, newest finish first. A dimmed row's finish is
        /// not here: nobody can currently hear it, so it paints nothing.
        public let news: [Finish]
        /// The mascot's face: the highest `Phase.priority` among **live,
        /// active** rows, the newest finish between two pieces of news; `idle`
        /// when there is none. A dimmed row is one nobody can currently hear,
        /// so its last word — a `working` from a machine whose tunnel dropped
        /// — must not keep the face busy; a passive one has already been heard.
        public let aggregate: Phase
        /// Is anything live? **Not a phase**, a render condition: the mascot's
        /// blink and breath loops check this and leave the view tree when it is
        /// false (idle drawing stops; `AGENTS.md` → Architecture). It is "any
        /// live, active row": an idle session or a seen finish lets the mascot
        /// sleep. A usage signal never enters it: a limit being read is not
        /// something live, and letting it in would keep the mascot's loops
        /// running on an idle machine for as long as a window is known. A
        /// dimmed row does not enter it either, for the same budget: it is
        /// listed, not live.
        public let hasLive: Bool
        /// The usage windows, apart from the session line: this Mac's groups
        /// first, then remote machines'; within each by group, then by window
        /// length, then by `entity` — deterministic, never by stamp.
        public let usage: [Signal]

        public init(signals: [Signal], seen: Set<Finish> = []) {
            // Split on `kind`, never on the provider's name: a usage source
            // nobody has written yet lands here too, and none of them reaches
            // the order, the aggregate or `hasLive`.
            let sessionLine = signals.filter { $0.kind != .usage }
            var layers: [String: Layer] = [:]
            for signal in sessionLine { layers[signal.entity] = Layer.of(signal, seen: seen) }
            self.layers = layers
            // A session's stamp stays out of the order: the hook refreshes it
            // on every `PostToolUse`, so sorting by it reshuffled the rows at
            // event rate. A finish's stamp is the moment it finished and holds
            // still, so news and the passive rows — seen finishes and quiet
            // sessions, which no event moves — are ordered by it, newest
            // first. Liveness is read from
            // `isLive` and nothing else, never from the provider's name: the
            // rules below agree by reading the same derived value.
            ordered = sessionLine.sorted {
                if $0.isLive != $1.isLive { return $0.isLive }
                let a = layers[$0.entity] ?? .passive, b = layers[$1.entity] ?? .passive
                if a != b { return a < b }
                if a == .news || a == .passive, $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.entity < $1.entity
            }
            let active = ordered.filter { $0.isLive && layers[$0.entity]?.isActive == true }
            news = active.compactMap { layers[$0.entity] == .news ? Finish($0) : nil }
            // Priority first, then the newest stamp: only news ties with a
            // different phase, and there the newest finish speaks.
            aggregate = active.max {
                $0.phase.priority != $1.phase.priority
                    ? $0.phase.priority < $1.phase.priority
                    : $0.updatedAt < $1.updatedAt
            }?.phase ?? .idle
            hasLive = !active.isEmpty
            // A usage row missing its field is a provider's mistake; it sorts
            // last rather than being dropped, so the mistake stays visible.
            usage = signals.filter { $0.kind == .usage }.sorted {
                let a = ($0.usage == nil ? 1 : 0, $0.machine == nil ? 0 : 1,
                         $0.usage?.group ?? "", $0.usage?.windowMinutes ?? 0)
                let b = ($1.usage == nil ? 1 : 0, $1.machine == nil ? 0 : 1,
                         $1.usage?.group ?? "", $1.usage?.windowMinutes ?? 0)
                return a != b ? a < b : $0.entity < $1.entity
            }
        }
    }

    /// One directory scan, every derived value. The only reading API callers
    /// should need.
    public func snapshot(seen: Set<Finish> = []) -> Snapshot {
        Snapshot(signals: signals(), seen: seen)
    }
}
