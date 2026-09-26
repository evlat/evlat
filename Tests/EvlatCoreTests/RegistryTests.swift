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
                        detail: String? = nil, source: AgentSource? = nil,
                        rawStatus: String? = "said-so",
                        at offset: TimeInterval = 0,
                        activity: Signal.Activity? = nil) -> Signal {
        Signal(provider: provider, entity: entity, phase: phase,
               label: label ?? provider, detail: detail, source: source,
               fidelity: fidelity, rawStatus: rawStatus,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + offset),
               activity: activity)
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
            // than it was. Measurement could not produce a real permission prompt
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
    /// The tool a session runs in rides along with the row: from the report
    /// when it knows, from the baseline otherwise. The rule carries it and
    /// never reads it — merging is the same for every source.
    func testTheSourceRidesAlongWithTheMerge() {
        let known = merged([signal("s", .working, .derived, source: .claude)],
                           [signal("s", .waiting, .official, source: .codex)])
        XCTAssertEqual(known.first?.source, .codex)
        let unknown = merged([signal("s", .working, .derived, source: .claude)],
                             [signal("s", .waiting, .official)])
        XCTAssertEqual(unknown.first?.source, .claude)
    }

    func testAnAdmittedReportWithoutDetailKeepsTheBaselineDetail() {
        let rows = merged([signal("s", .working, .derived, provider: "file", detail: "/file/cwd")],
                          [signal("s", .waiting, .official, provider: "hook")])
        XCTAssertEqual(rows.first?.detail, "/file/cwd")
    }

    /// A vetoed report leaves the phase, the name, the detail and the stamp
    /// the baseline's. Only its `activity` crosses, because the card is not
    /// the phase: a Claude session whose `working` report is refused still
    /// has a tool to show.
    func testARejectedReportLeavesTheBaselineUntouched() {
        let baseline = signal("s", .idle, .derived, provider: "file", label: "from-file",
                              detail: "/file/cwd", activity: Signal.Activity(pid: 7))
        let reported = Signal.Activity(pid: 9, lastTool: .init(name: "Bash", subject: "ls"),
                                       toolCount: 1)
        let rows = merged([baseline],
                          [signal("s", .working, .official, provider: "hook", label: "from-hook",
                                  detail: "/hook/cwd", at: 600, activity: reported)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phase, .idle)
        XCTAssertEqual(rows.first?.label, "from-file")
        XCTAssertEqual(rows.first?.detail, "/file/cwd")
        XCTAssertEqual(rows.first?.provider, "file")
        XCTAssertEqual(rows.first?.rawStatus, "said-so")
        XCTAssertEqual(rows.first?.updatedAt, baseline.updatedAt)
        XCTAssertEqual(rows.first?.activity, reported, "the activity is the report's")
    }

    /// The case the rewrite is for: a `busy` file and a `PreToolUse` report
    /// agree, so the report is refused — and the card still gets its tool.
    func testAWorkingFileWithAToolReportCarriesTheActivity() {
        let rows = merged([signal("s", .working, .derived, activity: Signal.Activity(pid: 7))],
                          [signal("s", .working, .official,
                                  activity: Signal.Activity(pid: 7, lastTool: .init(name: "Read", subject: "a.swift"),
                                                            toolCount: 3))])
        XCTAssertEqual(rows.first?.activity?.lastTool?.name, "Read")
        XCTAssertEqual(rows.first?.activity?.toolCount, 3)
    }

    /// A report that decayed to `idle` next to an `idle` file is refused, and
    /// the reply the turn ended with stays on the row.
    func testADecayedReportKeepsItsReply() {
        let rows = merged([signal("s", .idle, .derived)],
                          [signal("s", .idle, .official, activity: Signal.Activity(lastReply: "Done."))])
        XCTAssertEqual(rows.first?.activity?.lastReply, "Done.")
    }

    /// The pid is the file's fact when the hook did not send one.
    func testAReportWithoutAPidTakesTheBaselines() {
        for report in [Phase.working, .waiting] {
            let rows = merged([signal("s", .working, .derived, activity: Signal.Activity(pid: 7))],
                              [signal("s", report, .official, activity: Signal.Activity(lastReply: "x"))])
            XCTAssertEqual(rows.first?.activity?.pid, 7, "\(report)")
            XCTAssertEqual(rows.first?.activity?.lastReply, "x", "\(report)")
        }
        let own = merged([signal("s", .working, .derived, activity: Signal.Activity(pid: 7))],
                         [signal("s", .waiting, .official, activity: Signal.Activity(pid: 9))])
        XCTAssertEqual(own.first?.activity?.pid, 9, "a pid of its own wins: `--resume` moves it")
    }

    /// A stale `waiting` report that is refused must not leave its wait on a
    /// row that is not waiting: the card would ask for an approval nobody is
    /// asking for. The turn's facts still cross.
    func testARefusedWaitLeavesNoWaitBehind() {
        let stale = Signal.Activity(lastTool: .init(name: "Bash", subject: "ls"),
                                    blockingTool: .init(name: "Bash", subject: "rm"),
                                    waitKind: .approval, toolCount: 2)
        let rows = merged([signal("s", .idle, .derived)],
                          [signal("s", .waiting, .official, activity: stale)])
        XCTAssertEqual(rows.first?.phase, .idle)
        XCTAssertNil(rows.first?.activity?.waitKind)
        XCTAssertNil(rows.first?.activity?.blockingTool)
        XCTAssertEqual(rows.first?.activity?.lastTool?.subject, "ls")
        XCTAssertEqual(rows.first?.activity?.toolCount, 2)

        let admitted = merged([signal("s", .working, .derived)],
                              [signal("s", .waiting, .official, activity: stale)])
        XCTAssertEqual(admitted.first?.activity?.waitKind, .approval, "an admitted wait keeps it")
    }

    /// No report at all: the baseline's activity is the row's.
    func testWithoutAReportTheBaselinesActivityStands() {
        let rows = merged([signal("s", .working, .derived, activity: Signal.Activity(pid: 7))])
        XCTAssertEqual(rows.first?.activity?.pid, 7)
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

    /// The single-provider world: nothing to reconcile, nothing
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
    /// all** (measured). Worse, the day the field is renamed every
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

    // MARK: - Dimmed rows (a machine that cannot be heard)

    private func remote(_ entity: String, _ phase: Phase, reachable: Bool) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: entity, fidelity: .official,
               rawStatus: "said-so", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
               machine: Signal.Machine(name: "devbox", dim: reachable ? nil
                    : Signal.Machine.Dim(reason: .disconnected, since: Date(timeIntervalSince1970: 1_790_000_000))))
    }

    /// A dimmed row is not live: it does not drive the mascot's face.
    func testADimmedRowDoesNotRaiseTheAggregate() {
        let registry = Registry()
        registry.register(StubProvider(id: "a", signals: [signal("local", .idle, .official),
                                                          remote("far", .waiting, reachable: false)]))
        XCTAssertEqual(registry.snapshot().aggregate, .idle)
        let lit = Registry()
        lit.register(StubProvider(id: "a", signals: [signal("local", .idle, .official),
                                                     remote("far", .waiting, reachable: true)]))
        XCTAssertEqual(lit.snapshot().aggregate, .waiting, "a reachable machine counts like a local row")
    }

    /// Only dimmed rows: nothing is live, so the mascot's loops leave the
    /// view tree (the idle budget), though the rows are still listed.
    func testOnlyDimmedRowsMeansNothingIsLive() {
        let snapshot = Registry.Snapshot(signals: [remote("far", .working, reachable: false)])
        XCTAssertFalse(snapshot.hasLive)
        XCTAssertEqual(snapshot.aggregate, .idle)
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["far"], "listed all the same")
        XCTAssertTrue(Registry.Snapshot(signals: [remote("far", .working, reachable: true)]).hasLive)
    }

    /// Dimmed rows sit under every live one, whatever their phase; within
    /// each part the usual order holds.
    func testDimmedRowsSortBelowLiveOnes() {
        let snapshot = Registry.Snapshot(signals: [
            remote("dim-wait", .waiting, reachable: false),
            signal("idle", .idle, .official),
            remote("dim-idle", .idle, reachable: false),
            signal("work", .working, .official),
        ])
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["work", "idle", "dim-wait", "dim-idle"])
    }

    /// The machine rides along with the merge, on both branches.
    func testTheMachineRidesAlongWithTheMerge() {
        let dim = remote("far", .working, reachable: false)
        let file = Signal(provider: "file", entity: "far", phase: .working, label: "file",
                          fidelity: .derived, rawStatus: "busy",
                          updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(merged([file], [dim]).first?.machine, dim.machine, "a refused report")
        let waiting = remote("far", .waiting, reachable: false)
        XCTAssertEqual(merged([file], [waiting]).first?.machine, waiting.machine, "an admitted one")
    }

    /// Local usage groups first, a machine's after them — even where the
    /// alphabet would put `Claude · …` before `Codex`.
    func testARemoteUsageGroupComesAfterTheLocalOnes() {
        func usage(_ group: String, machine: Signal.Machine?) -> Signal {
            Signal(provider: "u", entity: "usage:\(group):300", kind: .usage, phase: .idle,
                   progress: 0.1, label: group, fidelity: .official,
                   updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                   usage: Signal.Usage(group: group, windowMinutes: 300,
                                       resetsAt: Date(timeIntervalSince1970: 1_790_010_000)),
                   machine: machine)
        }
        let snapshot = Registry.Snapshot(signals: [
            usage("Claude · devbox", machine: Signal.Machine(name: "devbox")),
            usage("Codex", machine: nil),
            usage("Claude", machine: nil),
        ])
        XCTAssertEqual(snapshot.usage.compactMap(\.usage?.group), ["Claude", "Codex", "Claude · devbox"])
    }

    // MARK: - Outside rows

    private func outside(_ id: String, _ phase: Phase, sender: String? = nil) -> Signal {
        Signal(provider: "signal", entity: "signal:\(id)", kind: .custom, phase: phase,
               label: id, fidelity: .manual, rawStatus: phase.rawValue,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000), sender: sender)
    }

    /// An outside row is namespaced, so a sender that names itself after a
    /// session gets a row of its own beside it rather than taking it over.
    func testAnOutsideRowNeverMergesWithASession() {
        let rows = merged([signal("x", .working, .derived)], [outside("x", .failed)])
        XCTAssertEqual(Set(rows.map(\.entity)), ["x", "signal:x"])
        XCTAssertEqual(rows.first { $0.entity == "x" }?.phase, .working, "the session is untouched")
    }

    /// `.manual` stands only where it is alone. Beside a `.derived` or an
    /// `.official` row of the same entity it wins nothing — neither the
    /// phase nor the name.
    func testAManualRowStandsOnlyWhereItIsAlone() {
        let manual = signal("e", .failed, .manual, provider: "hand", label: "hand")
        XCTAssertEqual(merged([manual]).first?.provider, "hand")
        let derived = merged([signal("e", .working, .derived, provider: "file")], [manual])
        XCTAssertEqual(derived.map(\.provider), ["file"])
        let official = merged([signal("e", .waiting, .official, provider: "hook")], [manual])
        XCTAssertEqual(official.map(\.provider), ["hook"])
    }

    /// The sender rides through every place a `Signal` is rebuilt by hand:
    /// a new field that one of them forgets disappears without a word.
    func testTheSenderSurvivesEveryRebuild() {
        let row = outside("x", .working, sender: "blender")
        XCTAssertEqual(row.with(activity: Signal.Activity(pid: 1)).sender, "blender")
        XCTAssertEqual(row.with(machine: Signal.Machine(name: "devbox")).sender, "blender")
        // Both of `reconcile`'s branches: an admitted report and a refused one.
        func sent(_ phase: Phase, _ fidelity: Signal.Fidelity, _ sender: String?) -> Signal {
            Signal(provider: "p", entity: "e", phase: phase, label: "l", fidelity: fidelity,
                   rawStatus: "said-so", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                   sender: sender)
        }
        XCTAssertEqual(merged([sent(.working, .derived, nil)], [sent(.waiting, .official, "hook")]).first?.sender,
                       "hook", "admitted")
        XCTAssertEqual(merged([sent(.working, .derived, "file")], [sent(.waiting, .official, nil)]).first?.sender,
                       "file", "admitted, the report has none")
        XCTAssertEqual(merged([sent(.working, .derived, "file")], [sent(.review, .official, "hook")]).first?.sender,
                       "file", "refused")
    }

    /// An outside row is on the session line: ordered by phase like any
    /// other, counted as live, and able to raise the mascot's face.
    func testAnOutsideRowIsOnTheSessionLine() {
        let snapshot = Registry.Snapshot(signals: [outside("build", .failed)])
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["signal:build"])
        XCTAssertTrue(snapshot.hasLive)
        XCTAssertEqual(snapshot.aggregate, .failed)
        XCTAssertTrue(snapshot.usage.isEmpty)
    }
}
