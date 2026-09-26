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

    /// The column takes the snapshot's layers: waiting, working, news with
    /// the newest finish on top, then passive rows.
    func testTheColumnFollowsTheSnapshotsLayers() {
        let model = SessionRowsModel()
        model.update(from: [signal("a", .idle), signal("b", .failed, stamp: 10),
                            signal("c", .review, stamp: 20), signal("d", .working),
                            signal("e", .waiting)])
        XCTAssertEqual(model.rows.map(\.entity), ["e", "d", "c", "b", "a"])
        let seen: Set<Finish> = [Finish(signal("c", .review, stamp: 20))!]
        model.update(from: Registry.Snapshot(signals: [signal("a", .idle), signal("b", .failed, stamp: 10),
                                                       signal("c", .review, stamp: 20)], seen: seen))
        XCTAssertEqual(model.rows.map(\.entity), ["b", "a", "c"], "a seen finish is passive")
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
    /// Three working jobs with a known progress (still rings) fill the
    /// closed rings ahead of a turning one, by entity.
    func testTheClockFollowsTheDrawnRowsOnly() {
        let model = SessionRowsModel()
        model.update(from: [outside("a", progress: 0.1), outside("b", progress: 0.2),
                            outside("c", progress: 0.3), signal("z", .working), signal("e", .idle)])
        XCTAssertEqual(model.closedRows.map(\.entity), ["signal:a", "signal:b", "signal:c"])
        XCTAssertFalse(model.isBeating, "the working row is in the count: nothing drawn beats")

        model.setOpen(true)
        XCTAssertTrue(model.isBeating, "open, the working row is drawn")
        model.setOpen(false)
        XCTAssertFalse(model.isBeating)
    }

    // MARK: - Outside rows

    private func outside(_ id: String, _ phase: Phase = .working, progress: Double? = nil,
                         label: String = "render", sender: String? = "blender",
                         stamp: TimeInterval = 0) -> Signal {
        Signal(provider: "signal", entity: "signal:\(id)", kind: .custom, phase: phase,
               progress: progress, label: label, detail: "frame 12 of 30", fidelity: .manual,
               rawStatus: phase.rawValue,
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + stamp), sender: sender)
    }

    /// The row carries whole percents: a sender stepping by a thousandth
    /// writes nothing until the percent itself moves.
    func testProgressIsWrittenOnlyWhenTheWholePercentMoves() {
        let model = SessionRowsModel()
        model.update(from: [outside("a", progress: 0.401)])
        XCTAssertEqual(model.rows.first?.progress, 40)
        var writes = 0
        let token = model.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }

        for value in [0.402, 0.403, 0.404] {
            model.update(from: [outside("a", progress: value)])
        }
        XCTAssertEqual(writes, 0, "the same percent: nothing drawn changed")
        model.update(from: [outside("a", progress: 0.41)])
        XCTAssertEqual(model.rows.first?.progress, 41)
        XCTAssertGreaterThan(writes, 0)
    }

    /// A known progress is the movement: the row does not turn on the beat,
    /// and a working outside row without one does.
    func testAWorkingRowWithProgressDoesNotBeat() {
        XCTAssertFalse(SessionRow(outside("a", progress: 0.4)).beats)
        XCTAssertTrue(SessionRow(outside("a")).beats)
        let model = SessionRowsModel()
        model.update(from: [outside("a", progress: 0.4)])
        XCTAssertFalse(model.isBeating, "nothing to turn")
        model.update(from: [outside("a")])
        XCTAssertTrue(model.isBeating)
        model.update(from: [])
    }

    /// Only an outside row carries a progress: a session's is not drawn.
    func testOnlyAnOutsideRowCarriesProgress() {
        let session = Signal(provider: "stub", entity: "s", phase: .working, progress: 0.5,
                             label: "s", fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(SessionRow(session).progress)
        XCTAssertEqual(SessionRow(outside("a", progress: 1)).progress, 100)
        XCTAssertEqual(SessionRow(outside("a", progress: 0)).progress, 0)
    }

    /// The sender is the outside row's small caps; the same name from two
    /// senders needs no number, from one sender it does.
    func testAnOutsideRowIsTaggedWithItsSender() {
        XCTAssertEqual(SessionRow(outside("a")).tag, "blender")
        XCTAssertNil(SessionRow(outside("a", sender: nil)).tag)
        let model = SessionRowsModel()
        model.update(from: [outside("a"), outside("b", sender: "ffmpeg")])
        XCTAssertEqual(model.rows.map(\.duplicate), [0, 0], "two senders: no number")
        model.update(from: [outside("a"), outside("b")])
        XCTAssertEqual(Set(model.rows.map(\.duplicate)), [0, 2])
        // A "/" in a sender cannot make two groups meet.
        model.update(from: [outside("a", label: "b/c", sender: "a"), outside("b", label: "c", sender: "a/b")])
        XCTAssertEqual(model.rows.map(\.duplicate), [0, 0])
    }

    private func remoteOutside(_ id: String, machine: String, label: String = "build",
                               sender: String? = "npm") -> Signal {
        Signal(provider: "signal", entity: "signal:\(machine):\(id)", kind: .custom, phase: .working,
               label: label, fidelity: .manual, rawStatus: "working",
               updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
               machine: Signal.Machine(name: machine), sender: sender)
    }

    /// A remote outside row answers "where" first: its tag is the
    /// machine, and the card says both — the sender, then the machine.
    func testARemoteOutsideRowIsTaggedWithItsMachine() {
        let row = SessionRow(remoteOutside("a", machine: "devbox"))
        XCTAssertEqual(row.tag, "devbox")
        XCTAssertEqual(SessionRow(remoteOutside("a", machine: "devbox", sender: nil)).tag, "devbox")
        XCTAssertEqual(SessionRow(outside("a")).tag, "blender", "a local outside row keeps its sender")
        XCTAssertEqual(RowTraits.Tag.sender.text(machine: "devbox", sender: "npm", inCard: true), "npm · devbox")
        XCTAssertEqual(RowTraits.Tag.sender.text(machine: nil, sender: "npm", inCard: true), "npm")
        XCTAssertEqual(RowTraits.Tag.sender.text(machine: "devbox", sender: nil, inCard: true), "devbox")
        XCTAssertEqual(RowTraits.Tag.machine.text(machine: "devbox", sender: "x", inCard: true), "devbox")
        XCTAssertEqual(RowTraits.Tag.evlat.text(machine: nil, sender: nil), SessionRow.jobTag)
        // A chat job's card has the mascot's face and no tag, as before remote outside rows.
        XCTAssertNil(RowTraits.Tag.evlat.text(machine: nil, sender: nil, inCard: true))
    }

    /// The number follows the drawn tag: on one machine two senders' "build"
    /// both read "DEVBOX build" and need one; on two machines they do not.
    func testRemoteOutsideRowsAreNumberedByTheDrawnTag() {
        let model = SessionRowsModel()
        model.update(from: [remoteOutside("a", machine: "devbox"),
                            remoteOutside("b", machine: "devbox", sender: "make")])
        XCTAssertEqual(Set(model.rows.map(\.duplicate)), [0, 2], "same machine: numbered")
        model.update(from: [remoteOutside("a", machine: "devbox"), remoteOutside("b", machine: "other")])
        XCTAssertEqual(model.rows.map(\.duplicate), [0, 0], "two machines: no number")
        model.update(from: [outside("a", label: "build", sender: "npm"),
                            outside("b", label: "build", sender: "make")])
        XCTAssertEqual(model.rows.map(\.duplicate), [0, 0], "local rows still told apart by sender")
    }

    /// An outside row's stamp is the moment its phase began (the provider
    /// keeps it while the phase holds): its time is known on first sight.
    func testAnOutsideRowsTimeIsKnownOnFirstSight() {
        let model = SessionRowsModel()
        model.update(from: [outside("a", stamp: 5)])
        XCTAssertEqual(model.rows.first?.enteredAt, Date(timeIntervalSince1970: 1_790_000_005))
        model.update(from: [signal("s", .working, stamp: 5)])
        XCTAssertNil(model.rows.first?.enteredAt, "a session's stamp moves on every tool event")
    }

    /// What each kind can do, as one table — the switch behind it is
    /// exhaustive, so a new kind does not compile until it has a line here.
    func testEveryKindHasItsTraits() {
        XCTAssertEqual(RowTraits.of(.session), RowTraits(mark: .tool, tag: .machine, button: .goToSession, detail: .none,
                                                         stampIsPhaseStart: false, showsProgress: false))
        XCTAssertEqual(RowTraits.of(.job), RowTraits(mark: .face, tag: .evlat, button: .backToChat, detail: .folder,
                                                     stampIsPhaseStart: true, showsProgress: false))
        XCTAssertEqual(RowTraits.of(.custom), RowTraits(mark: .none, tag: .sender, button: .none, detail: .note,
                                                        stampIsPhaseStart: true, showsProgress: true))
        XCTAssertEqual(RowTraits.of(.usage).button, .none)
        XCTAssertTrue(SessionRow(signal("l", .working)).hasTerminal)
        XCTAssertFalse(SessionRow(remote("r")).hasTerminal, "a remote session's terminal is elsewhere")
        XCTAssertFalse(SessionRow(outside("a")).hasTerminal)
    }

    /// With a progress the line says how far instead of how long, `~` for a
    /// number Evlat did not measure; the body is fitted to that form too.
    func testTheStatusLineSaysTheProgress() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(StatusLine.text(phase: .working, waitKind: nil, enteredAt: now.addingTimeInterval(-600),
                                       progress: 40, now: now, in: "en"), "working · ~40%")
        XCTAssertEqual(StatusLine.text(phase: .working, waitKind: nil, enteredAt: nil,
                                       progress: 40, now: now, in: "tr"), "çalışıyor · ~%40")
        XCTAssertEqual(StatusLine.text(phase: .review, waitKind: nil, enteredAt: now.addingTimeInterval(-600),
                                       now: now, in: "en"), "done · 10 min")
        let row = SessionRow(outside("a", label: "x", sender: nil, stamp: 0))
        let withProgress = SessionRow(outside("a", progress: 1, label: "x", sender: nil))
        for lang in ["en", "tr"] {
            let percent = ceil(("\(StatusLine.text(phase: .working, waitKind: nil, enteredAt: nil, progress: 100, now: now, in: lang))" as NSString)
                .size(withAttributes: [.font: SessionColumn.statusFont]).width)
            XCTAssertGreaterThanOrEqual(SessionColumn.namesWidth([withProgress], in: lang), percent, lang)
            XCTAssertGreaterThanOrEqual(SessionColumn.namesWidth([withProgress], in: lang),
                                        SessionColumn.namesWidth([row], in: lang), lang)
        }
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
