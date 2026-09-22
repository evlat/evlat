import XCTest
@testable import EvlatCore

/// The rule that reduces two sources' rows for one entity to a single line.
///
/// Entirely headless, and the providers are **stubs on purpose**: the rule has
/// to hold for sources that do not exist yet, so a test that leaned on
/// `SessionsProvider` would be testing the wrong thing.
final class RegistryTests: XCTestCase {
    /// Says exactly what the test hands it. It carries no source-specific
    /// behaviour, because the rule is not allowed to see one.
    private struct StubProvider: Provider {
        let id: String
        let signals: [Signal]
        func currentSignals() -> [Signal] { signals }
    }

    /// `rawStatus` defaults to a word rather than to `nil`, because absence is
    /// **not** neutral here: a baseline with no word of its own asserts nothing
    /// and admits everything (see the tests at the bottom). Every cell of the
    /// table below is about a baseline that did say something.
    private func signal(_ entity: String, _ phase: Phase, _ fidelity: Signal.Fidelity,
                        provider: String = "stub", label: String? = nil,
                        detail: String? = nil, rawStatus: String? = "said-so",
                        at offset: TimeInterval = 0) -> Signal {
        Signal(provider: provider, entity: entity, phase: phase,
               label: label ?? provider, detail: detail, fidelity: fidelity, rawStatus: rawStatus,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + offset))
    }

    /// One registry per call, one provider per group. The assertions read
    /// `snapshot().ordered` because that is what the callers actually see.
    private func merged(_ groups: [Signal]...) -> [Signal] {
        let registry = Registry()
        for (index, signals) in groups.enumerated() {
            registry.register(StubProvider(id: "stub-\(index)", signals: signals))
        }
        return registry.snapshot().ordered
    }

    // MARK: - The compatibility table

    /// Every cell, written out rather than computed: an expectation derived
    /// from the rule itself would pass whatever the rule happened to say.
    ///
    /// Two of the last three baselines cannot be produced by the only
    /// `.derived` source there is: it maps `busy`, `idle` and `waiting`
    /// (`SessionsProvider.phase(for:)`) and draws `idle` for a word it does not
    /// know, so `review` and `failed` are out of its reach. `waiting` is within
    /// reach but has never been seen in a session file. The rule is a total
    /// function either way, so what it does on all three is pinned here.
    func testEveryCellOfTheCompatibilityTable() {
        let cells: [(baseline: Phase, report: Phase, shown: Phase)] = [
            // A busy session can also be waiting on the user, or have failed.
            (.working, .idle, .working),
            (.working, .working, .working),
            (.working, .waiting, .waiting),
            (.working, .review, .working),
            (.working, .failed, .failed),
            // An idle session can be one that just finished, or failed.
            // `(.idle, .waiting)` stays a veto, and the reason is now narrower
            // than it was. `phase-3` could not produce a real permission prompt
            // (an autonomous agent blocks on one), so what the file says while
            // a prompt is on screen is still **unknown**. What was measured is
            // that the file is not written by tool events at all — 53 events,
            // zero writes — so a prompt arriving mid-turn finds the record
            // still saying `busy`, and that is the `(.working, .waiting)` cell
            // above, which admits. An `idle` file next to a `waiting` hook is
            // the other story: a report that outlived its correction. It loses.
            (.idle, .idle, .idle),
            (.idle, .working, .idle),
            (.idle, .waiting, .idle),
            (.idle, .review, .review),
            (.idle, .failed, .failed),
            // Outside the two rows above nothing is admitted.
            (.waiting, .idle, .waiting),
            (.waiting, .working, .waiting),
            (.waiting, .waiting, .waiting),
            (.waiting, .review, .waiting),
            (.waiting, .failed, .waiting),
            (.review, .idle, .review),
            (.review, .working, .review),
            (.review, .waiting, .review),
            (.review, .review, .review),
            (.review, .failed, .review),
            (.failed, .idle, .failed),
            (.failed, .working, .failed),
            (.failed, .waiting, .failed),
            (.failed, .review, .failed),
            (.failed, .failed, .failed),
        ]

        for cell in cells {
            let rows = merged([signal("s", cell.baseline, .derived, provider: "file")],
                              [signal("s", cell.report, .official, provider: "report")])
            XCTAssertEqual(rows.count, 1,
                           "derived \(cell.baseline) + official \(cell.report): one entity, one row")
            XCTAssertEqual(rows.first?.phase, cell.shown,
                           "derived \(cell.baseline) + official \(cell.report)")
        }
    }

    /// An admitted report gives the row its phase and everything that moves
    /// with it, but **not its name**. The hook body carries no session name,
    /// so a report-owned label falls back to the folder, and on this machine
    /// that differed from the file's name in 17 of 22 live records: the row
    /// would rename itself the moment it turned `waiting`. `detail` does come
    /// from the report, because the hook keeps `cwd` fresh and the file is not
    /// written at event rate.
    func testAnAdmittedReportKeepsTheBaselineName() {
        let rows = merged([signal("s", .working, .derived, provider: "file", label: "from-file",
                                  detail: "/file/cwd")],
                          [signal("s", .waiting, .official, provider: "hook", label: "from-hook",
                                  detail: "/hook/cwd")])
        XCTAssertEqual(rows.first?.label, "from-file", "the name does not move with the phase")
        XCTAssertEqual(rows.first?.provider, "hook")
        XCTAssertEqual(rows.first?.phase, .waiting)
        XCTAssertEqual(rows.first?.detail, "/hook/cwd")
        XCTAssertEqual(rows.first?.fidelity, .official)
    }

    /// A report that has not learnt a `cwd` yet does not blank the file's.
    func testAnAdmittedReportWithoutDetailKeepsTheBaselineDetail() {
        let rows = merged([signal("s", .working, .derived, provider: "file", detail: "/file/cwd")],
                          [signal("s", .waiting, .official, provider: "hook")])
        XCTAssertEqual(rows.first?.detail, "/file/cwd")
    }

    /// The guard on the behaviour that did not change: a vetoed report leaves
    /// no trace on the row, not even a borrowed field.
    func testARejectedReportLeavesTheBaselineUntouched() {
        let baseline = signal("s", .idle, .derived, provider: "file", label: "from-file",
                              detail: "/file/cwd")
        let rows = merged([baseline],
                          [signal("s", .working, .official, provider: "hook", label: "from-hook",
                                  detail: "/hook/cwd", at: 600)])
        XCTAssertEqual(rows, [baseline])
    }

    /// With no baseline there is no other name to take: Codex keeps its own.
    func testAnOfficialRowWithoutADerivedTwinKeepsItsOwnName() {
        let rows = merged([signal("codex-1", .working, .official, provider: "codex",
                                  label: "codex-name")])
        XCTAssertEqual(rows.map(\.label), ["codex-name"])
    }

    // MARK: - One row per entity

    func testTheSameSessionFromTwoSourcesIsOneRow() {
        let rows = merged([signal("s-1", .working, .derived), signal("s-2", .idle, .derived)],
                          [signal("s-1", .waiting, .official)])
        XCTAssertEqual(rows.count, 2, "two sessions were described, not three")
        XCTAssertEqual(rows.map(\.entity).sorted(), ["s-1", "s-2"])
    }

    func testDistinctEntitiesAreNotMerged() {
        let rows = merged([signal("s-1", .working, .derived)],
                          [signal("s-2", .waiting, .official)])
        XCTAssertEqual(rows.map(\.entity), ["s-2", "s-1"], "waiting sorts above working")
    }

    /// Within one phase the order is by `entity`, never by stamp: the hook
    /// refreshes its stamp on every `PostToolUse`, so an order that read it
    /// would reshuffle the bar at event rate.
    func testSwappingStampsDoesNotReorderRowsOfOnePhase() {
        let before = merged([signal("s-a", .working, .official, at: 0),
                             signal("s-b", .working, .official, at: 600)])
        let after = merged([signal("s-a", .working, .official, at: 600),
                            signal("s-b", .working, .official, at: 0)])
        XCTAssertEqual(before.map(\.entity), after.map(\.entity))
        XCTAssertEqual(after.map(\.entity), ["s-a", "s-b"])
    }

    // MARK: - A row without a twin

    /// Codex keeps no file record, and neither will signals posted from
    /// outside: this branch is the only thing that keeps them visible at all.
    func testAnOfficialRowWithoutADerivedTwinPasses() {
        let rows = merged([signal("codex-1", .waiting, .official, provider: "codex")])
        XCTAssertEqual(rows.map(\.phase), [.waiting])
        XCTAssertEqual(rows.first?.provider, "codex")
    }

    /// The single-provider world of `001`: nothing to reconcile, nothing
    /// changed.
    func testADerivedRowWithoutAnOfficialTwinPasses() {
        let rows = merged([signal("s-1", .working, .derived), signal("s-2", .idle, .derived)])
        XCTAssertEqual(rows.map(\.entity), ["s-1", "s-2"])
        XCTAssertEqual(rows.map(\.phase), [.working, .idle])
    }

    // MARK: - Freshness never crosses fidelity

    /// Direction one: a newer report that cannot be true alongside the file
    /// still loses. This is the report that outlived its correction — Evlat was
    /// closed while the session finished, so `working` is the last thing the
    /// source ever said and the file knows better. A session that is actually
    /// dead never gets this far; liveness drops it inside the provider.
    func testANewerIncompatibleReportDoesNotBeatTheBaseline() {
        let rows = merged([signal("s", .idle, .derived, at: 0)],
                          [signal("s", .working, .official, at: 600)])
        XCTAssertEqual(rows.map(\.phase), [.idle])
    }

    /// Direction two, and the reason this set exists: a file rewritten during a
    /// permission prompt is newer than the hook's `waiting` and must not erase
    /// it.
    func testANewerBaselineDoesNotSwallowACompatibleReport() {
        let rows = merged([signal("s", .working, .derived, at: 600)],
                          [signal("s", .waiting, .official, at: 0)])
        XCTAssertEqual(rows.map(\.phase), [.waiting])
    }

    /// Within one fidelity the timestamp is the tie-break — and only there.
    func testTheNewestDerivedRowWins() {
        let rows = merged([signal("s", .idle, .derived, at: 0)],
                          [signal("s", .working, .derived, at: 600)])
        XCTAssertEqual(rows.map(\.phase), [.working])
    }

    func testTheNewestOfficialRowWins() {
        let rows = merged([signal("s", .review, .official, at: 600)],
                          [signal("s", .failed, .official, at: 0)])
        XCTAssertEqual(rows.map(\.phase), [.review])
    }

    /// The mascot's face follows the merged list, not the raw one: an
    /// overruled `failed` report must not light the bar up.
    func testTheAggregateIsComputedAfterMerging() {
        let registry = Registry()
        registry.register(StubProvider(id: "file", signals: [signal("s", .idle, .derived)]))
        registry.register(StubProvider(id: "hook", signals: [signal("s", .working, .official)]))
        XCTAssertEqual(registry.snapshot().aggregate, .idle)
    }

    func testNoProvidersMeansNoRows() {
        XCTAssertFalse(Registry().snapshot().hasLive)
    }

    // MARK: - A baseline that never read a word

    /// `.idle` used to arrive with two different meanings: "the file says idle"
    /// and "nothing could be read, so idle it is". The second kind vetoed
    /// reports it had no business vetoing — and it happens in a real window:
    /// a new session record exists for ~500 ms with **no `status` field at
    /// all** (`phase-3`, measured). Worse, the day the field is renamed every
    /// row reads idle and no hook can ever correct it.
    ///
    /// The two are told apart without adding a field to `Signal`: a row whose
    /// `rawStatus` is nil never read a word, so it asserts nothing.
    func testABaselineWithNoWordOfItsOwnAdmitsAnyReport() {
        for report in Phase.allCases {
            let rows = merged([signal("s", .idle, .derived, provider: "file", rawStatus: nil)],
                              [signal("s", report, .official, provider: "hook")])
            XCTAssertEqual(rows.first?.phase, report,
                           "a baseline with no word cannot veto \(report)")
        }
    }

    /// The other half of the same rule, and the one that keeps the veto
    /// load-bearing: a file that really did say `idle` still overrules a hook
    /// left `working` because Evlat was closed while the session finished.
    func testABaselineThatDidReadAWordStillVetoes() {
        let rows = merged([signal("s", .idle, .derived, provider: "file", rawStatus: "idle")],
                          [signal("s", .working, .official, provider: "hook")])
        XCTAssertEqual(rows.first?.phase, .idle)
    }

    /// Alone, a wordless baseline is still the row: "asserts nothing" is about
    /// the veto, not about existing.
    func testAWordlessBaselineAloneIsStillTheRow() {
        let rows = merged([signal("s", .idle, .derived, provider: "file", rawStatus: nil)])
        XCTAssertEqual(rows.map(\.provider), ["file"])
    }
}
