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

    private func signal(_ entity: String, _ phase: Phase, _ fidelity: Signal.Fidelity,
                        provider: String = "stub", label: String? = nil,
                        at offset: TimeInterval = 0) -> Signal {
        Signal(provider: provider, entity: entity, phase: phase,
               label: label ?? provider, fidelity: fidelity,
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
    /// The last three baselines cannot be produced by the only `.derived`
    /// source there is — it speaks `busy`/`idle`, and `idle` for a word it does
    /// not know — but the rule is a total function, so what it does there is
    /// pinned too.
    func testEveryCellOfTheCompatibilityTable() {
        let cells: [(baseline: Phase, report: Phase, shown: Phase)] = [
            // A busy session can also be waiting on the user, or have failed.
            (.working, .idle, .working),
            (.working, .working, .working),
            (.working, .waiting, .waiting),
            (.working, .review, .working),
            (.working, .failed, .failed),
            // An idle session can be one that just finished, or failed.
            // `(.idle, .waiting)` rests on an assumption nobody has measured:
            // the plan takes the file to say `busy` while a permission prompt
            // is on screen. If it says `idle` instead, `waiting` becomes
            // unreachable through the merge — `phase-3`'s first measurement is
            // what settles this cell.
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

    /// An admitted report replaces the whole row, not only its phase: the
    /// source's own word is the richer one and the list shows it.
    func testAnAdmittedReportReplacesTheWholeRow() {
        let rows = merged([signal("s", .working, .derived, provider: "file", label: "from-file")],
                          [signal("s", .waiting, .official, provider: "hook", label: "from-hook")])
        XCTAssertEqual(rows.first?.label, "from-hook")
        XCTAssertEqual(rows.first?.provider, "hook")
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
}
