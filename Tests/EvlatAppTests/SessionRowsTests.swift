import XCTest
import Combine
import EvlatCore
@testable import EvlatApp

/// The collapsed strip's rows: which ones get a slot, when the model is
/// written, and who owns the beat.
///
/// Every one of these fails silently in the field. A deadband that sees the
/// stamp re-evaluates the column at event rate; a clock that restarts on a
/// list write never beats while a session is busy (`AGENTS.md` → the rhythm
/// trap); a clock left running with nothing to beat burns the idle budget.
@MainActor
final class SessionRowsTests: XCTestCase {
    private final class StubProvider: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    private func signal(_ entity: String, _ phase: Phase, stamp: TimeInterval = 0,
                        label: String? = nil, source: AgentSource? = .claude) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: label ?? "name-\(entity)",
               source: source, fidelity: .official,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + stamp))
    }

    private func row(_ entity: String, _ phase: Phase = .idle) -> SessionRow {
        SessionRow(entity: entity, label: "name-\(entity)", phase: phase, source: .claude)
    }

    // MARK: - Slots

    func testTheSlotRuleShowsFourOrThreeAndTheRest() {
        let none = SessionRowsModel.slots([])
        XCTAssertEqual(none.rows.count, 0)
        XCTAssertEqual(none.overflow, 0)

        let four = SessionRowsModel.slots((1...4).map { row("s\($0)") })
        XCTAssertEqual(four.rows.map(\.entity), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(four.overflow, 0, "four fit: no overflow slot")

        let five = SessionRowsModel.slots((1...5).map { row("s\($0)") })
        XCTAssertEqual(five.rows.map(\.entity), ["s1", "s2", "s3"],
                       "the fourth slot is given up to the overflow count")
        XCTAssertEqual(five.overflow, 2)
    }

    /// The row carries what is drawn and nothing else: no stamp.
    func testARowIsBuiltFromTheVisibleFieldsOnly() {
        let a = SessionRow(signal("s1", .working, stamp: 0))
        let b = SessionRow(signal("s1", .working, stamp: 600))
        XCTAssertEqual(a, b, "a stamp alone must not make two rows differ")
        XCTAssertEqual(a.label, "name-s1")
    }

    // MARK: - Deadband

    /// Two `working` rows whose stamps take turns being the newer one — the
    /// shape of a `PostToolUse` burst across two sessions. Nothing visible
    /// moves, so nothing is written.
    func testAlternatingStampsDoNotWriteTheRows() {
        let controller = AppController()
        let provider = StubProvider()
        controller.registry.register(provider)
        provider.signals = [signal("a", .working, stamp: 0), signal("b", .working, stamp: 1)]
        controller.refresh()
        XCTAssertEqual(controller.sessionRows.rows.map(\.entity), ["a", "b"])

        var writes = 0
        let token = controller.sessionRows.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }

        for turn in 2..<12 {
            let t = TimeInterval(turn)
            provider.signals = turn.isMultiple(of: 2)
                ? [signal("a", .working, stamp: t), signal("b", .working, stamp: t - 1)]
                : [signal("a", .working, stamp: t - 1), signal("b", .working, stamp: t)]
            controller.refresh()
        }
        XCTAssertEqual(writes, 0, "stamps moved, nothing drawn changed")
    }

    /// And a visible change does get through.
    func testAPhaseChangeIsWritten() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .idle)])
        var writes = 0
        let token = model.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }

        model.update(from: [signal("a", .review)])
        XCTAssertEqual(model.rows.map(\.phase), [.review])
        XCTAssertGreaterThan(writes, 0)
    }

    // MARK: - When a phase was entered

    /// A clock the test moves by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    /// First sight has no entry time — how long it has been in that phase is
    /// not known. An observed change stamps it from the model's clock, never
    /// from the signal's stamp, which moves on every tool event.
    func testEnteredAtIsWrittenOnlyOnAnObservedChange() {
        let clock = Clock()
        let model = SessionRowsModel(now: { clock.now })
        model.update(from: [signal("a", .working, stamp: 5)])
        XCTAssertNil(model.rows.first?.enteredAt, "first sight: not known")

        clock.now += 120
        model.update(from: [signal("a", .working, stamp: 9)])
        XCTAssertNil(model.rows.first?.enteredAt, "same phase: still not known")

        model.update(from: [signal("a", .waiting, stamp: 11)])
        XCTAssertEqual(model.rows.first?.enteredAt, clock.now)
    }

    /// `review` fading to `idle` is a change the column sees, so the idle row
    /// counts from the fade.
    func testTheReviewFadeGivesANewEntry() {
        let clock = Clock()
        let model = SessionRowsModel(now: { clock.now })
        model.update(from: [signal("a", .working)])
        clock.now += 10
        model.update(from: [signal("a", .review)])
        let done = model.rows.first?.enteredAt
        clock.now += 300
        model.update(from: [signal("a", .idle)])
        XCTAssertEqual(model.rows.first?.enteredAt, clock.now)
        XCTAssertNotEqual(model.rows.first?.enteredAt, done)
    }

    /// A `PreToolUse` burst in one phase moves the activity — the last tool,
    /// the count — and nothing the row draws. The rows are not written.
    func testAnActivityBurstInOnePhaseDoesNotWriteTheRows() {
        let controller = AppController()
        let provider = StubProvider()
        controller.registry.register(provider)
        func busy(_ n: Int) -> Signal {
            Signal(provider: "stub", entity: "a", phase: .working, label: "name-a", source: .claude,
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)),
                   activity: Signal.Activity(pid: 42, lastTool: .init(name: n.isMultiple(of: 2) ? "Bash" : "Read",
                                                                      subject: "step \(n)"),
                                             toolCount: n))
        }
        provider.signals = [busy(0)]
        controller.refresh()

        var writes = 0
        let token = controller.sessionRows.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }
        for n in 1...10 {
            provider.signals = [busy(n)]
            controller.refresh()
        }
        XCTAssertEqual(writes, 0, "tool events inside one phase draw nothing new")
    }

    /// The wait kind reaches the row, and only a waiting row carries one.
    func testTheWaitKindIsCarriedOnAWaitingRowOnly() {
        let model = SessionRowsModel()
        func with(_ phase: Phase, _ kind: Signal.Activity.WaitKind) -> Signal {
            signal("a", phase).with(activity: Signal.Activity(waitKind: kind))
        }
        model.update(from: [with(.waiting, .answer)])
        XCTAssertEqual(model.rows.first?.waitKind, .answer)
        model.update(from: [with(.working, .approval)])
        XCTAssertNil(model.rows.first?.waitKind)
    }

    // MARK: - The beat clock

    /// R6.1: with nothing to beat, there is no timer at all.
    /// The session that just finished goes to the top of the idle rows, not
    /// back to its place by entity: the order within a phase is the order the
    /// rows entered it, newest first. Only a phase change moves a row — a
    /// stamp moving on every tool event does not.
    func testTheRowThatJustChangedPhaseLeadsItsPhase() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .idle), signal("b", .idle), signal("c", .review)])
        XCTAssertEqual(model.rows.map(\.entity), ["c", "a", "b"], "first sight: by entity")

        model.update(from: [signal("a", .idle), signal("b", .idle), signal("c", .idle)])
        XCTAssertEqual(model.rows.map(\.entity), ["c", "a", "b"], "c just finished: it leads the idle rows")

        model.update(from: [signal("a", .idle, stamp: 9), signal("b", .idle, stamp: 5),
                            signal("c", .idle, stamp: 1)])
        XCTAssertEqual(model.rows.map(\.entity), ["c", "a", "b"], "stamps do not reorder")

        model.update(from: [signal("a", .idle), signal("b", .working), signal("c", .idle)])
        model.update(from: [signal("a", .idle), signal("b", .idle), signal("c", .idle)])
        XCTAssertEqual(model.rows.map(\.entity), ["b", "c", "a"], "b finished last")
    }

    func testNothingToBeatMeansNoClock() {
        let model = SessionRowsModel()
        model.update(from: [])
        XCTAssertFalse(model.isBeating)
        model.update(from: [signal("a", .idle), signal("b", .review), signal("c", .failed)])
        XCTAssertFalse(model.isBeating, "idle, review and failed are still: no clock")
        XCTAssertEqual(model.clockStarts, 0)
    }

    /// A list write under the same Bool leaves the clock alone — restarting it
    /// would push the next beat out on every write, and a busy session writes
    /// constantly.
    func testAListChangeUnderTheSameBoolDoesNotRestartTheClock() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .working)])
        XCTAssertTrue(model.isBeating)
        XCTAssertEqual(model.clockStarts, 1)

        model.update(from: [signal("a", .working), signal("b", .idle)])
        model.update(from: [signal("b", .waiting), signal("a", .working)])
        model.update(from: [signal("c", .waiting)])
        XCTAssertEqual(model.clockStarts, 1, "the Bool never changed, so neither did the clock")
        XCTAssertTrue(model.isBeating)
    }

    func testTheClockStopsWhenNothingIsLeftToBeat() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .waiting)])
        XCTAssertTrue(model.isBeating)
        model.update(from: [signal("a", .idle)])
        XCTAssertFalse(model.isBeating)
        model.update(from: [signal("a", .working)])
        XCTAssertEqual(model.clockStarts, 2, "a new beating stretch is a new clock")
    }

    private func dimmed(_ entity: String, _ phase: Phase) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: "name-\(entity)",
               source: .claude, fidelity: .official,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
               machine: Signal.Machine(name: "devbox", dim: Signal.Machine.Dim(
                   reason: .disconnected, since: Date(timeIntervalSince1970: 1_790_000_000))))
    }

    /// A dimmed row is not live, so it does not beat: a machine that went
    /// quiet in `working` must not keep the clock — and the idle budget —
    /// running.
    func testADimmedWorkingRowDoesNotBeat() {
        let model = SessionRowsModel()
        model.update(from: [dimmed("far", .working), dimmed("ask", .waiting)])
        XCTAssertEqual(model.rows.map(\.isLive), [false, false])
        XCTAssertFalse(model.rows.contains(where: \.beats))
        XCTAssertFalse(model.isBeating, "no clock for rows nobody can hear")
        XCTAssertEqual(model.clockStarts, 0)
        model.setOpen(true)
        XCTAssertFalse(model.isBeating, "not in the open list either")
    }

    /// Live rows first, whatever the dimmed one says: a dimmed `waiting` is
    /// drawn under a live `idle`.
    func testADimmedRowIsDrawnUnderTheLiveOnes() {
        let model = SessionRowsModel()
        model.update(from: [dimmed("far", .waiting), signal("near", .idle)])
        XCTAssertEqual(model.rows.map(\.entity), ["near", "far"])
    }

    // MARK: - Remote rows

    private func remote(_ entity: String, label: String = "api", machine: String = "devbox",
                        dim: Signal.Machine.Dim? = nil, stamp: TimeInterval = 0) -> Signal {
        Signal(provider: "stub", entity: entity, phase: .working, label: label,
               source: .claude, fidelity: .official,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + stamp),
               machine: Signal.Machine(name: machine, dim: dim))
    }

    /// The machine's name is drawn, so it is in the deadband: a renamed
    /// machine rewrites the row, the same machine again does not.
    func testAMachineNameChangeRewritesTheRow() {
        let model = SessionRowsModel()
        var writes = 0
        let sub = model.$rows.dropFirst().sink { _ in writes += 1 }
        defer { sub.cancel() }
        model.update(from: [remote("r", machine: "devbox")])
        XCTAssertEqual(model.rows.first?.machine, "devbox")
        model.update(from: [remote("r", machine: "devbox", stamp: 30)])
        XCTAssertEqual(writes, 1, "a stamp alone writes nothing")
        model.update(from: [remote("r", machine: "buildbox")])
        XCTAssertEqual(model.rows.first?.machine, "buildbox")
        XCTAssertEqual(writes, 2)
    }

    /// `api` on `devbox` and `api` here are two places, told apart by the
    /// machine's name; two `api`s on the same machine need a number.
    func testTheSameNameIsNumberedOnlyOnTheSameMachine() {
        let model = SessionRowsModel()
        model.update(from: [signal("local", .working, label: "api"), remote("remote:d:1")])
        XCTAssertEqual(model.rows.map(\.duplicate), [0, 0], "different machines: no number")
        model.update(from: [signal("local", .working, label: "api"),
                            remote("remote:d:1"), remote("remote:d:2")])
        let numbers = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.entity, $0.duplicate) })
        XCTAssertEqual(numbers, ["local": 0, "remote:d:1": 0, "remote:d:2": 2])
    }

    /// A dimmed row carries why and since when; a live one carries neither,
    /// so nothing moving reaches the row while it is lit.
    func testADimmedRowCarriesWhyAndSinceWhen() {
        let lost = Signal.Machine.Dim(reason: .disconnected, since: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(SessionRow(remote("r", dim: lost)).dim, lost)
        XCTAssertFalse(SessionRow(remote("r", dim: lost)).isLive)
        XCTAssertNil(SessionRow(remote("r")).dim)
        XCTAssertTrue(SessionRow(remote("r")).isLive)
        XCTAssertNil(SessionRow(signal("l", .working)).machine)
    }

    /// The status line of a dimmed row says why instead of the phase, with
    /// the time since it was lost.
    func testADimmedRowSaysWhyOnItsStatusLine() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let lost = Signal.Machine.Dim(reason: .disconnected, since: since)
        let quiet = Signal.Machine.Dim(reason: .quiet, since: since)
        XCTAssertEqual(StatusLine.text(phase: .working, waitKind: nil, enteredAt: nil, dim: lost,
                                       now: since.addingTimeInterval(5 * 60 + 30), in: "en"),
                       "no connection · 5 min")
        XCTAssertEqual(StatusLine.text(phase: .working, waitKind: nil, enteredAt: nil, dim: quiet,
                                       now: since.addingTimeInterval(40 * 60), in: "tr"),
                       "sessiz · 40 dk")
        XCTAssertEqual(StatusLine.text(phase: .waiting, waitKind: .approval, enteredAt: nil, dim: lost,
                                       now: since.addingTimeInterval(3 * 3600), in: "tr"),
                       "bağlantı yok · 3 sa", "a dimmed block says why too, not what it waited for")
    }

    /// The open body is fitted to a remote row's name with its machine, and
    /// to a dimmed row's widest status line.
    func testTheOpenBodyHoldsTheMachineName() {
        let local = SessionRow(signal("l", .idle, label: "api"))
        let far = SessionRow(remote("r"))
        XCTAssertGreaterThan(SessionColumn.namesWidth([far], in: "en"),
                             SessionColumn.namesWidth([local], in: "en"))
        let lost = SessionRow(remote("r", label: "x", dim: Signal.Machine.Dim(
            reason: .disconnected, since: Date(timeIntervalSince1970: 0))))
        for lang in ["en", "tr"] {
            let widest = StatusLine.widestForms(dim: .disconnected, in: lang)
                .map { ceil(($0 as NSString).size(withAttributes: [.font: SessionColumn.statusFont]).width) }
                .max() ?? 0
            XCTAssertGreaterThanOrEqual(SessionColumn.namesWidth([lost], in: lang), widest, lang)
        }
    }

    /// Two sessions with the same name in the same tool get a number, from the
    /// second one on; the same name in two tools does not — the mark already
    /// tells them apart. The number follows the entity, so it does not move
    /// when the rows reorder.
    func testOnlyASameNameInTheSameToolIsNumbered() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .idle, label: "evlat-v2"),
                            signal("b", .idle, label: "evlat-v2", source: .codex),
                            signal("c", .idle, label: "evlat-v2", source: .codex)])
        let byEntity = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.entity, $0) })
        XCTAssertEqual(byEntity["a"]?.source, .claude)
        XCTAssertEqual(byEntity["a"]?.duplicate, 0, "alone in its tool")
        XCTAssertEqual(byEntity["b"]?.duplicate, 0, "the first of two keeps the bare name")
        XCTAssertEqual(byEntity["c"]?.duplicate, 2)

        model.update(from: [signal("a", .idle, label: "evlat-v2"),
                            signal("b", .working, label: "evlat-v2", source: .codex),
                            signal("c", .idle, label: "evlat-v2", source: .codex)])
        XCTAssertEqual(model.rows.first?.entity, "b")
        XCTAssertEqual(model.rows.first { $0.entity == "c" }?.duplicate, 2, "reordering keeps the number")
    }

    /// A beating row is never hidden behind still ones: the model orders by
    /// phase itself, so a working session handed in last still takes a slot
    /// and starts the clock, and the count stands for idle rows.
    func testABeatingRowIsNeverBehindTheCount() {
        let model = SessionRowsModel()
        model.update(from: (1...4).map { signal("s\($0)", .idle) } + [signal("s5", .working)])
        XCTAssertEqual(model.overflow, 2)
        XCTAssertEqual(model.rows.first?.entity, "s5")
        XCTAssertTrue(model.isBeating)
    }

    /// The model holds the whole ordered list; the closed bar's three rings
    /// and count are derived from it, by the same slot rule as before.
    func testTheModelHoldsEveryRowAndTheClosedPrefixIsDerived() {
        let model = SessionRowsModel()
        model.update(from: (0..<6).map { signal("s\($0)", .idle) })
        XCTAssertEqual(model.rows.map(\.entity), (0..<6).map { "s\($0)" })
        XCTAssertEqual(model.closedRows.map(\.entity), ["s0", "s1", "s2"])
        XCTAssertEqual(model.overflow, 3)
        XCTAssertEqual(model.slotsInUse, SessionRowsModel.slotCount)

        model.update(from: (0..<4).map { signal("s\($0)", .idle) })
        XCTAssertEqual(model.closedRows.count, 4, "four fit")
        XCTAssertEqual(model.overflow, 0)
    }

    /// The clock follows what is drawn. Closed, a working row behind the
    /// count is not drawn and must not keep the clock running; open, it is.
    /// `failed` outranks `working`, so three of them fill the closed rings.
    func testTheClockFollowsTheDrawnRowsOnly() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .failed), signal("b", .failed), signal("c", .failed),
                            signal("d", .working), signal("e", .idle)])
        XCTAssertEqual(model.closedRows.map(\.entity), ["a", "b", "c"])
        XCTAssertFalse(model.isBeating, "the working row is in the count: nothing drawn beats")

        model.setOpen(true)
        XCTAssertTrue(model.isBeating, "open, the working row is drawn")
        model.setOpen(false)
        XCTAssertFalse(model.isBeating)
    }

    // MARK: - The gesture table

    /// Still phases play nothing, beating ones play a gesture shorter than the
    /// beat, and every track comes back to rest — the next gesture starts from
    /// rest whatever the animator keeps at the end.
    func testGesturesAreShortAndEndAtRest() {
        for phase in [Phase.idle, .failed] {
            XCTAssertEqual(IndicatorGesture.duration(for: phase), 0, "\(phase) is still")
        }
        for phase in [Phase.working, .waiting, .review] {
            let d = IndicatorGesture.duration(for: phase)
            XCTAssertGreaterThan(d, 0, "\(phase) gestures")
            XCTAssertLessThan(d, SessionRowsModel.beatInterval, "\(phase) is a beat, not a loop")
            XCTAssertEqual(IndicatorGesture.spin(for: phase).last?.value ?? 0, 0)
            XCTAssertEqual(IndicatorGesture.pulse(for: phase).last?.value ?? 1, 1)
            XCTAssertEqual(IndicatorGesture.glow(for: phase).last?.value ?? 0, 0)
        }
    }
}
