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

    private func signal(_ entity: String, _ phase: Phase, stamp: TimeInterval = 0) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: "name-\(entity)",
               fidelity: .official,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + stamp))
    }

    private func row(_ entity: String, _ phase: Phase = .idle) -> SessionRow {
        SessionRow(entity: entity, label: "name-\(entity)", phase: phase)
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
        XCTAssertEqual(model.rows, [row("a", .review)])
        XCTAssertGreaterThan(writes, 0)
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
