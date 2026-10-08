import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The presence rule wired to the bar: `AppController.applyPresence()` is the
/// one writer of the hover area, the mascot's visibility and the drawn level,
/// so these hold the controller, not the rule (`BodyPresenceTests` holds the
/// rule's tables).
@MainActor
final class BodyPresenceWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    /// The peek timers the controller asked for, fired by hand.
    private final class Timers {
        var pending: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        func fire(_ index: Int) { pending[index].item.perform() }
    }

    /// The controller's clock, moved by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    @MainActor private struct Rig {
        let controller: AppController
        let provider: Stub
        let panel: BarPanel
        let timers: Timers
        let clock: Clock

        func set(_ phase: Phase) {
            provider.signals = [Signal(provider: "stub", entity: "s", phase: phase, label: "s",
                                       fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))]
            controller.refresh()
        }

        /// Several rows at once, by entity.
        func set(_ rows: [(String, Phase)]) {
            provider.signals = rows.map {
                Signal(provider: "stub", entity: $0.0, phase: $0.1, label: $0.0,
                       fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
            }
            controller.refresh()
        }

        /// Several rows with their stamps: a finish's key is its stamp, so a
        /// row that finishes again must say when.
        func set(_ rows: [(String, Phase, TimeInterval)], dim: Set<String> = []) {
            provider.signals = rows.map { Self.row($0.0, $0.1, at: $0.2, dim: dim.contains($0.0)) }
            controller.refresh()
        }

        static func row(_ entity: String, _ phase: Phase, at stamp: TimeInterval, dim: Bool = false) -> Signal {
            Signal(provider: "stub", entity: entity, phase: phase, label: entity,
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: stamp),
                   machine: dim ? Signal.Machine(name: "m", dim: .init(reason: .disconnected,
                                                                       since: Date(timeIntervalSince1970: 0)))
                                : nil)
        }

        /// The bar open for `seconds`, then closed.
        func look(for seconds: TimeInterval) {
            controller.openBar()
            clock.now += seconds
            controller.closeBar()
        }

        /// The body's hover area as AppKit holds it.
        func bodyRect() throws -> NSRect {
            let view = try XCTUnwrap(panel.contentView)
            view.updateTrackingAreas()
            let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
            return try XCTUnwrap(owned.first).rect
        }
    }

    /// `before` is what the providers hold at the first scan.
    private func rig(_ mode: BodyPresence.Mode, edge: BarPanel.Edge = .right,
                     before: [Signal] = [], prepare: (AppController, Clock) -> Void = { _, _ in }) -> Rig {
        let controller = AppController()
        let clock = Clock()
        controller.now = { clock.now }
        let timers = Timers()
        controller.peekSchedule = { delay, item in timers.pending.append((delay, item)) }
        controller.bodyMode = mode
        let provider = Stub()
        provider.signals = before
        controller.registry.register(provider)
        prepare(controller, clock)
        let panel = controller.installPanel(edge: edge)
        controller.refresh()
        return Rig(controller: controller, provider: provider, panel: panel, timers: timers, clock: clock)
    }

    // MARK: - Always: today's bar

    func testAlwaysKeepsTodaysHoverArea() throws {
        let rig = rig(.always)
        defer { rig.panel.close() }
        let state = rig.controller.barState
        let closed = try rig.bodyRect()
        XCTAssertEqual(closed.width, AppController.barWidth, accuracy: 0.5)
        XCTAssertEqual(closed.height, state.length, accuracy: 0.5)
        rig.controller.openBar()
        let open = try rig.bodyRect()
        XCTAssertEqual(open.width, state.openWidth, accuracy: 0.5)
        XCTAssertEqual(open.height, state.openLength, accuracy: 0.5)
        rig.controller.closeBar()
        XCTAssertEqual(try rig.bodyRect(), closed)
        XCTAssertEqual(state.presence.level, .full)
        XCTAssertTrue(rig.controller.mascot.isShown)
    }

    // MARK: - Hidden: the trigger strip

    func testSmartClosesToTheTriggerStrip() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        rig.controller.openBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
        XCTAssertEqual(try rig.bodyRect().width, rig.controller.barState.openWidth, accuracy: 0.5)
        rig.controller.closeBar()
        let strip = try rig.bodyRect()
        XCTAssertEqual(strip.width, BodyPresence.sliverWidth, accuracy: 0.5, "not the 54 pt body")
        XCTAssertEqual(strip.height, BodyPresence.triggerLength, accuracy: 0.5)
        XCTAssertEqual(strip.maxX, try XCTUnwrap(rig.panel.contentView).bounds.maxX, accuracy: 0.5)
        XCTAssertFalse(rig.controller.mascot.isShown)
        XCTAssertFalse(rig.controller.mascot.isAwake)
    }

    /// The edge's input reaches the bar through the one writer: under
    /// Smart a clear edge is the whole body, with the mascot shown; Tucked
    /// ignores it.
    func testAClearEdgeBringsSmartOutAndLeavesTuckedIn() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.controller.edgeClear = true
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
        XCTAssertEqual(try rig.bodyRect().width, AppController.barWidth, accuracy: 0.5)
        XCTAssertTrue(rig.controller.mascot.isShown)
        rig.controller.bodyMode = .tucked
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertFalse(rig.controller.mascot.isShown)
        rig.controller.bodyMode = .smart
        rig.controller.edgeClear = false
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertEqual(try rig.bodyRect().width, BodyPresence.sliverWidth, accuracy: 0.5)
    }

    func testTheLeftStripSitsOnTheLeftEdge() throws {
        let rig = rig(.smart, edge: .left)
        defer { rig.panel.close() }
        XCTAssertEqual(try rig.bodyRect(),
                       NSRect(x: 0, y: AppController.headroom, width: BodyPresence.sliverWidth,
                              height: BodyPresence.triggerLength))
    }

    func testTheSliverTakesNoMascotClick() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let bounds = try XCTUnwrap(rig.panel.contentView).bounds
        let point = CGPoint(x: bounds.maxX - 2,
                            y: bounds.minY + AppController.headroom + AppController.mascotTopInset + AppController.mascotSize / 2)
        XCTAssertEqual(rig.panel.onClick?(point), false)
        XCTAssertFalse(rig.controller.isChatOpen, "an unseen mascot opens no balloon")
    }

    /// With the chat switched off a file dragged to the strip brings no
    /// body out and no catching pose; on, the same drag does both.
    func testSwitchedOffADragBringsNoBody() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let bounds = try XCTUnwrap(rig.panel.contentView).bounds
        let strip = CGPoint(x: bounds.maxX - 2, y: bounds.minY + AppController.headroom + 10)
        rig.controller.setChatEnabled(false)
        XCTAssertFalse(rig.controller.drag(.over(point: strip, screen: .zero)))
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver, "the hidden body stays in")
        XCTAssertFalse(rig.controller.mascot.catching)
        rig.controller.setChatEnabled(true)
        XCTAssertTrue(rig.controller.drag(.over(point: strip, screen: .zero)))
        XCTAssertEqual(rig.controller.barState.presence.level, .full, "on, the file brings it out")
        _ = rig.controller.drag(.left)
    }

    func testTheBalloonBringsTheWholeBody() throws {
        let rig = rig(.smart)
        defer {
            rig.controller.closeChat()
            rig.controller.chatPanel?.close()
            rig.panel.close()
        }
        rig.controller.openChat()
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
        XCTAssertTrue(rig.controller.mascot.isShown)
        XCTAssertEqual(try rig.bodyRect().width, AppController.barWidth, accuracy: 0.5)
        rig.controller.closeChat()
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
    }

    /// The setup is out like the balloon: the whole body, whatever the mode.
    func testTheSetupBringsTheWholeBodyToo() throws {
        let rig = rig(.smart)
        defer {
            rig.controller.closeSetup()
            rig.controller.setupPanel?.close()
            rig.panel.close()
        }
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        rig.controller.openSetup()
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
        XCTAssertTrue(rig.controller.mascot.isShown)
        XCTAssertEqual(try rig.bodyRect().width, AppController.barWidth, accuracy: 0.5)
        rig.controller.closeSetup()
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
    }

    /// News is quiet beside the setup, as beside the balloon: a finish that
    /// came meanwhile was in sight, and closing the setup does not tell it.
    func testAFinishUnderTheSetupIsNotToldWhenItCloses() {
        let rig = rig(.smart)
        defer {
            rig.controller.closeSetup()
            rig.controller.setupPanel?.close()
            rig.panel.close()
        }
        rig.controller.openSetup()
        rig.set([("a", .review, 1)])
        rig.controller.closeSetup()
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        XCTAssertEqual(rig.controller.barState.presence.dot, .review)
    }

    // MARK: - The edge, read

    /// A fake reading of the edge: hands out what it is told, in order
    /// (`true` covered, `false` clear, `nil` nothing known), and keeps what
    /// it was asked. No test reads the user's windows.
    private final class EdgeReadings {
        var queue: [Bool?] = []
        var asked: [EdgeCover.Strip] = []
        func read(_ strip: EdgeCover.Strip) -> Bool? {
            asked.append(strip)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    /// A rig whose edge is read by `readings`, with the cursor far away.
    private func edgeRig(_ mode: BodyPresence.Mode, _ readings: EdgeReadings,
                         edge: BarPanel.Edge = .right) -> Rig {
        rig(mode, edge: edge) { controller, _ in
            controller.edgeReader = readings.read
            controller.mouseLocation = { CGPoint(x: -10_000, y: -10_000) }
        }
    }

    /// Polls once per reading handed in.
    private func poll(_ rig: Rig, _ readings: EdgeReadings, _ values: Bool?...) {
        for value in values {
            readings.queue.append(value)
            rig.controller.pollEdge()
        }
    }

    /// Nothing reads the edge until it is polled, and a live reader is
    /// never the default: a controller built in a test reads nothing.
    func testNoReaderIsLiveByDefault() {
        XCTAssertNil(AppController().edgeReader(EdgeCover.Strip(window: 1, edge: .right, headroom: 0,
                                                                width: 54, length: 100, pid: 1)))
    }

    /// The first reading applies at once; after it one reading moves
    /// nothing and two that agree do — both ways.
    func testTwoReadingsThatAgreeMoveTheBody() throws {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        let state = rig.controller.barState
        poll(rig, readings, true)
        XCTAssertEqual(state.presence.level, .sliver)
        poll(rig, readings, false)
        XCTAssertEqual(state.presence.level, .sliver, "one reading moves nothing")
        poll(rig, readings, false)
        XCTAssertEqual(state.presence.level, .full, "two that agree do")
        XCTAssertTrue(rig.controller.mascot.isShown)
        XCTAssertEqual(try rig.bodyRect().width, AppController.barWidth, accuracy: 0.5)
        poll(rig, readings, true)
        XCTAssertEqual(state.presence.level, .full)
        poll(rig, readings, true)
        XCTAssertEqual(state.presence.level, .sliver)
        XCTAssertFalse(rig.controller.mascot.isShown)
    }

    /// What the reader is asked for: the bar's own window, its edge, and the
    /// length the full body takes under Smart — the closed body's, never
    /// shorter than the trigger strip, so no window lies under the
    /// near-clear fill of an edge read clear.
    func testTheReaderIsAskedForTheBarsClosedBody() throws {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings, edge: .left)
        defer { rig.panel.close() }
        rig.set(.working)
        poll(rig, readings, true)
        let strip = try XCTUnwrap(readings.asked.last)
        XCTAssertEqual(strip.window, rig.panel.windowNumber)
        XCTAssertEqual(strip.edge, .left)
        XCTAssertEqual(strip.headroom, AppController.headroom)
        XCTAssertEqual(strip.width, AppController.barWidth)
        XCTAssertEqual(strip.length, max(rig.controller.barState.length, BodyPresence.triggerLength),
                       accuracy: 0.5)
        XCTAssertEqual(strip.pid, ProcessInfo.processInfo.processIdentifier)
    }

    /// With no session the closed body is shorter than the trigger strip;
    /// the strip is what is read, as it is what the full body covers.
    func testAShortBodyIsReadOverTheTriggerStrip() throws {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        XCTAssertLessThan(rig.controller.barState.length, BodyPresence.triggerLength, "the premise")
        poll(rig, readings, false)
        let strip = try XCTUnwrap(readings.asked.last)
        XCTAssertEqual(strip.length, BodyPresence.triggerLength, accuracy: 0.5)
        XCTAssertEqual(try rig.bodyRect().height, BodyPresence.triggerLength, accuracy: 0.5)
    }

    /// The cursor holds nothing while the body is already out: the open bar
    /// closes onto the clear edge it was read, not into the sliver.
    func testTheOpenBarIsNotHeldByTheCursor() throws {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        let frame = rig.panel.frame
        poll(rig, readings, true)
        rig.controller.openBar()
        rig.controller.mouseLocation = { CGPoint(x: frame.maxX - 10, y: frame.maxY - AppController.headroom - 20) }
        poll(rig, readings, false, false)
        XCTAssertTrue(rig.controller.edgeClear)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
    }

    /// Docked to another edge, what was read was the old edge's: the next
    /// reading is applied as it is, with no second to wait for.
    func testAMoveToAnotherEdgeTakesTheNextReadingAtOnce() {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        poll(rig, readings, false)
        XCTAssertTrue(rig.controller.edgeClear)
        rig.controller.dock(.left)
        XCTAssertEqual(readings.asked.count, 1, "nothing is read at the move")
        poll(rig, readings, true)
        XCTAssertFalse(rig.controller.edgeClear)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
    }

    /// A jump of one reading, seen in use, is swallowed; a reading that
    /// tells nothing breaks no pair.
    func testAOneReadingJumpIsSwallowed() {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        let state = rig.controller.barState
        poll(rig, readings, true, false, true, false, true)
        XCTAssertEqual(state.presence.level, .sliver)
        XCTAssertFalse(rig.controller.edgeClear)
        poll(rig, readings, false, nil, false)
        XCTAssertEqual(state.presence.level, .full, "nil is not counted")
    }

    /// Until a reading tells something, nothing is applied, and the first
    /// that does is applied at once.
    func testTheFirstReadingThatTellsIsApplied() {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        poll(rig, readings, nil, nil)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        poll(rig, readings, false)
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
    }

    /// The body does not come out under a still cursor — it would open at
    /// the cursor's first move; once the cursor leaves, the next agreeing
    /// reading brings it out. Going in is never held.
    func testTheBodyDoesNotComeOutUnderTheCursor() throws {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        let frame = rig.panel.frame
        let state = rig.controller.barState
        poll(rig, readings, true)
        // Over the whole closed body, under the sliver's strip.
        rig.controller.mouseLocation = {
            CGPoint(x: frame.maxX - 30, y: frame.maxY - AppController.headroom - BodyPresence.triggerLength + 5)
        }
        poll(rig, readings, false, false, false)
        XCTAssertEqual(state.presence.level, .sliver, "held while the cursor is there")
        rig.controller.mouseLocation = { CGPoint(x: frame.maxX - 60, y: frame.maxY - AppController.headroom - 20) }
        poll(rig, readings, false)
        XCTAssertEqual(state.presence.level, .full, "beside it, the next reading brings it out")
        rig.controller.mouseLocation = { CGPoint(x: frame.maxX - 10, y: frame.maxY - AppController.headroom - 20) }
        poll(rig, readings, true, true)
        XCTAssertEqual(state.presence.level, .sliver, "going in is never held")
    }

    /// Entering Smart reads at once and applies what it reads; leaving it
    /// forgets the edge, so Tucked is in whatever the edge was.
    func testEnteringSmartReadsAtOnce() {
        let readings = EdgeReadings()
        let rig = edgeRig(.tucked, readings)
        defer { rig.panel.close() }
        readings.queue = [false]
        rig.controller.bodyMode = .smart
        XCTAssertEqual(readings.asked.count, 1)
        XCTAssertEqual(rig.controller.barState.presence.level, .full, "no second reading waited for")
        rig.controller.bodyMode = .tucked
        XCTAssertFalse(rig.controller.edgeClear)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        readings.queue = [true]
        rig.controller.bodyMode = .smart
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
    }

    /// Only Smart reads the edge: polled under the others, open or closed,
    /// the reader is never asked.
    func testTheOtherModesNeverReadTheEdge() {
        for mode in [BodyPresence.Mode.always, .tucked, .hidden] {
            let readings = EdgeReadings()
            let rig = edgeRig(mode, readings)
            poll(rig, readings, false, false)
            rig.controller.openBar()
            poll(rig, readings, false, false)
            rig.controller.closeBar()
            XCTAssertTrue(readings.asked.isEmpty, "\(mode) read the edge")
            XCTAssertFalse(rig.controller.edgeClear)
            rig.panel.close()
        }
    }

    /// The open bar does not stop the reading: it closes onto the edge as
    /// it is now.
    func testTheOpenBarStillReads() {
        let readings = EdgeReadings()
        let rig = edgeRig(.smart, readings)
        defer { rig.panel.close() }
        poll(rig, readings, true)
        rig.controller.openBar()
        poll(rig, readings, false, false)
        XCTAssertEqual(readings.asked.count, 3)
        XCTAssertTrue(rig.controller.edgeClear)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .full)
    }

    // MARK: - Peek

    /// A finish peeks, then the sliver shows what the open bar would: once
    /// the phase is back to idle, nothing of the finish is left.
    func testAFinishPeeksAndLeavesNothingBehind() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let controller = rig.controller
        rig.set(.review)
        XCTAssertEqual(controller.peekPhase, .review)
        XCTAssertEqual(controller.barState.presence.level, .peek)
        XCTAssertEqual(try rig.bodyRect().width, BodyPresence.peekWidth, accuracy: 0.5)
        XCTAssertEqual(rig.timers.pending.count, 1)
        XCTAssertEqual(rig.timers.pending[0].delay, AppController.reviewPeek)

        rig.set(.idle)
        XCTAssertNil(controller.peekPhase, "a new phase ends the peek")
        XCTAssertEqual(controller.barState.presence.level, .sliver)
        XCTAssertNil(controller.barState.presence.dot, "no finish outlives the phase")

        controller.refresh()
        XCTAssertEqual(rig.timers.pending.count, 1, "the poll sets nothing up again")
    }

    func testThePeekEndsOnItsTimer() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set(.failed)
        XCTAssertEqual(rig.controller.barState.presence.level, .peek)
        XCTAssertEqual(rig.timers.pending.last?.delay, AppController.failedPeek)
        rig.timers.fire(0)
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertEqual(rig.controller.barState.presence.dot, .failed)
        XCTAssertFalse(rig.controller.mascot.isShown)
    }

    func testANewFinishCancelsTheOldPeek() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set(.review)
        rig.set(.failed)
        XCTAssertEqual(rig.timers.pending.count, 2)
        rig.timers.fire(0)
        XCTAssertEqual(rig.controller.peekPhase, .failed, "the review's timer is stale")
        rig.timers.fire(1)
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertEqual(rig.controller.barState.presence.dot, .failed)
    }

    func testAForcedFailurePeeksToo() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.controller.mascot.override = .failed
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.peekPhase, .failed)
        XCTAssertEqual(rig.controller.barState.presence.level, .peek)
        XCTAssertTrue(rig.controller.mascot.isShown)
    }

    func testAFinishOnTheOpenBarIsNotNews() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set(.working)
        rig.controller.openBar()
        rig.set(.review)
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        rig.set(.idle)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertNil(rig.controller.barState.presence.dot)
    }

    /// Opening's own scan can be what brings the finish in: seen by opening,
    /// it must not peek out again when the bar closes.
    func testAFinishTheOpeningScanBringsInDoesNotPeekOnClose() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set(.working)
        rig.provider.signals = [Signal(provider: "stub", entity: "s", phase: .review, label: "s",
                                       fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))]
        rig.controller.openBar()
        XCTAssertNil(rig.controller.peekPhase)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver, "no peek for a finish just seen")
        for index in rig.timers.pending.indices { rig.timers.fire(index) }
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver, "the stale timer changes nothing")
    }

    /// A switch to Smart brings no finish from before it.
    func testASwitchToSmartBringsNoOldFinish() {
        let rig = rig(.always)
        defer { rig.panel.close() }
        rig.set(.failed)
        rig.set(.idle)
        rig.controller.bodyMode = .smart
        XCTAssertNil(rig.controller.barState.presence.dot)
    }

    func testWaitingPeeksUntilAnswered() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set(.waiting)
        XCTAssertEqual(rig.controller.barState.presence.level, .peek)
        XCTAssertEqual(rig.controller.barState.presence.glow, .waiting)
        XCTAssertTrue(rig.timers.pending.isEmpty, "waiting has no timer")
        rig.set(.working)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertEqual(rig.controller.barState.presence.dot, .working)
    }

    // MARK: - One row's finish

    /// A job done beside sessions still working is news, and news outranks
    /// work: the aggregate becomes the finish and it is told, briefly.
    func testOneRowFinishingBesideWorkIsTheAggregate() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .working), ("job", .working)])
        rig.set([("a", .working), ("job", .review)])
        XCTAssertEqual(rig.controller.mascot.phase, .review, "news outranks work")
        XCTAssertEqual(rig.controller.peekPhase, .review)
        XCTAssertEqual(rig.controller.barState.presence.level, .peek)
        XCTAssertEqual(rig.timers.pending.last?.delay, AppController.reviewPeek)
        rig.timers.fire(rig.timers.pending.count - 1)
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
    }

    /// With the peek off, the dot takes the finish's colour.
    func testWithoutThePeekTheDotTellsARowFinish() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.controller.bodyToggles.peekDone = false
        rig.set([("a", .working), ("job", .working)])
        rig.set([("a", .working), ("job", .review)])
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
        XCTAssertEqual(rig.controller.barState.presence.dot, .review)
    }

    /// A row first seen already finished is news like any other finish:
    /// beside work it becomes the aggregate and is told.
    func testARowFirstSeenFinishedIsNewsBesideWork() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .working)])
        rig.set([("a", .working), ("old", .review)])
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    // MARK: - News: told once, from one place

    /// Beside a failure already told, a newer review is the one told, and
    /// the newest finish is what the dot shows after.
    func testANewerReviewBesideAFailureIsTheOneTold() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .failed, 1)])
        XCTAssertEqual(rig.controller.peekPhase, .failed)
        rig.timers.fire(rig.timers.pending.count - 1)
        rig.set([("a", .failed, 1), ("b", .review, 2)])
        XCTAssertEqual(rig.controller.peekPhase, .review)
        XCTAssertEqual(rig.timers.pending.last?.delay, AppController.reviewPeek)
        rig.timers.fire(rig.timers.pending.count - 1)
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertEqual(rig.controller.barState.presence.dot, .review, "the newest finish")
        XCTAssertEqual(rig.controller.mascot.phase, .review)
    }

    /// The first scan's finishes are old: active, but not told.
    func testTheFirstScansNewsIsActiveButNotTold() {
        let rig = rig(.smart, before: [Rig.row("old", .review, at: 1)])
        defer { rig.panel.close() }
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        XCTAssertTrue(rig.controller.mascot.hasLive)
    }

    /// A row whose phase moves on and finishes again is new news.
    func testTheSameRowFinishingAgainIsToldAgain() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .review, 1)])
        rig.set([("a", .working, 2)])
        let told = rig.timers.pending.count
        rig.set([("a", .review, 3)])
        XCTAssertEqual(rig.timers.pending.count, told + 1)
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    /// A finish that came while the balloon was out was seen there: closing
    /// the balloon does not tell it, the dot shows it.
    func testAFinishUnderTheBalloonIsNotToldWhenItCloses() {
        let rig = rig(.smart)
        defer {
            rig.controller.closeChat()
            rig.controller.chatPanel?.close()
            rig.panel.close()
        }
        rig.controller.openChat()
        rig.set([("a", .review, 1)])
        rig.controller.closeChat()
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        XCTAssertEqual(rig.controller.barState.presence.dot, .review)
    }

    /// The veto flutter: the merge holds a finish back while the file says
    /// `busy`, then lets it through with the same stamp. Not new news, and a
    /// seen one stays seen.
    func testAVetoFlutterNeitherRetellsNorRevivesAFinish() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .review, 1)])
        let told = rig.timers.pending.count
        rig.set([("a", .working, 0)])
        rig.set([("a", .review, 1)])
        XCTAssertEqual(rig.timers.pending.count, told, "not told again")
        rig.look(for: 2)
        XCTAssertEqual(rig.controller.mascot.phase, .idle)
        rig.set([("a", .working, 0)])
        rig.set([("a", .review, 1)])
        XCTAssertEqual(rig.controller.mascot.phase, .idle, "seen stays seen")
        XCTAssertFalse(rig.controller.mascot.hasLive)
    }

    // MARK: - Seen

    /// A second's look at the open bar sees its news: the finish goes
    /// passive, the face falls back and the mascot may sleep.
    func testALookOfASecondSeesTheNews() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("a", .working, 0), ("b", .review, 1)])
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        rig.look(for: 1.2)
        XCTAssertEqual(rig.controller.mascot.phase, .working)
        rig.set([("a", .idle, 2), ("b", .review, 1)])
        XCTAssertEqual(rig.controller.mascot.phase, .idle)
        XCTAssertFalse(rig.controller.mascot.hasLive, "nothing active: the mascot sleeps")
    }

    /// A glance is not a look: under a second the news stays news.
    func testAGlanceSeesNothing() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("b", .review, 1)])
        rig.look(for: 0.5)
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        XCTAssertTrue(rig.controller.mascot.hasLive)
    }

    /// Nothing moves on the open bar because it was seen: the order changes
    /// only once it closes.
    func testTheOpenBarDoesNotReorderWhatItShows() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("z", .review, 1), ("b", .idle, 0)])
        rig.controller.openBar()
        rig.clock.now += 5
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), ["z", "b"])
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), ["b", "z"])
    }

    /// A dimmed finish is on the open bar too: seen there, it is not told
    /// when its machine is heard again.
    func testADimmedFinishSeenOnTheBarIsNotToldWhenItComesBack() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        rig.set([("r", .review, 1)], dim: ["r"])
        rig.look(for: 2)
        let told = rig.timers.pending.count
        rig.set([("r", .review, 1)])
        XCTAssertEqual(rig.timers.pending.count, told)
        XCTAssertEqual(rig.controller.mascot.phase, .idle)
    }

    // MARK: - Release

    /// A seen outside row stays on the bar, passive, for an hour after it
    /// ended, then goes at a closed bar's scan; a seen session stays.
    func testASeenSignalRowStaysAnHourThenGoes() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let controller = rig.controller
        controller.registry.register(controller.signals)
        guard case .success(let done) = SignalReport.parse(json: ["id": "job", "ttl": 60, "phase": "done"]) else {
            return XCTFail("fixture refused")
        }
        _ = controller.signals.apply(done)
        rig.set([("s", .review, 1)])
        rig.look(for: 2)
        XCTAssertEqual(Set(controller.sessionRows.rows.map(\.entity)), ["s", "signal:job"])
        rig.look(for: 0.2)
        XCTAssertEqual(Set(controller.sessionRows.rows.map(\.entity)), ["s", "signal:job"],
                       "seen is not gone: the recent past stays")
        rig.clock.now += AppController.keptPassiveAge
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(controller.sessionRows.rows.map(\.entity), ["s"], "the session stays")
        XCTAssertEqual(controller.signals.count, 0)
    }

    /// Only the newest seen outside rows are kept: an older one is pushed
    /// out once more than `keptPassive` have been seen.
    func testOnlyTheNewestSeenRowsAreKept() {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let controller = rig.controller
        controller.registry.register(controller.signals)
        for index in 0...AppController.keptPassive {
            guard case .success(let done) = SignalReport.parse(json: ["id": "job\(index)", "ttl": 60,
                                                                      "phase": "done"]) else {
                return XCTFail("fixture refused")
            }
            _ = controller.signals.apply(done)
            rig.clock.now += 1
        }
        controller.refresh()
        rig.look(for: 2)
        controller.refresh()
        let left = controller.sessionRows.rows.map(\.entity)
        XCTAssertEqual(left.count, AppController.keptPassive)
        XCTAssertFalse(left.contains("signal:job0"), "the oldest went")
    }

    // MARK: - A chat's finish

    /// A chat left unseen by the last run: a store with it in the index.
    private func unseenChat(_ controller: AppController, _ clock: Clock, id: String, directory: URL) {
        let entry = ChatIndex.Entry(id: id, sessionID: "S-\(id)", title: "T",
                                    folder: directory.appendingPathComponent("chats/\(id)").path,
                                    isWorkspace: true, createdAt: clock.now - 3600,
                                    lastActivity: clock.now - 3600, lastReply: "Done.",
                                    started: true, unseen: .review)
        try? ChatIndex(entries: [entry]).encoded().write(to: directory.appendingPathComponent(ChatStore.indexName))
        let store = ChatStore(root: directory, platform: .unknown,
                              locator: AgentLocator(name: "claude", environment: ["EVLAT_CLAUDE": "/nonexistent"]),
                              now: { clock.now })
        controller.chats = store
        controller.registry.register(store.provider)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func unseen(_ id: String, in directory: URL) throws -> Phase? {
        try ChatIndex.decode(Data(contentsOf: directory.appendingPathComponent(ChatStore.indexName)))
            .entries.first { $0.id == id }?.unseen
    }

    /// The store is loaded before the first scan: an old unseen chat is
    /// active but not told. Seen at one close, it goes at the next, and the
    /// index forgets it was unseen — a chat keeps no recent past on the bar.
    func testASeenChatGoesAtTheNextCloseAndIsWrittenDown() throws {
        let directory = try temporaryDirectory()
        let id = "0C9E7D1A-8E57-4B9B-8D0F-7F2B4E6A1C33"
        let rig = rig(.smart) { self.unseenChat($0, $1, id: id, directory: directory) }
        defer { rig.panel.close() }
        let entity = ChatSession.entity(id)
        XCTAssertNil(rig.controller.peekPhase, "an old finish is not told at launch")
        XCTAssertEqual(rig.controller.mascot.phase, .review)
        rig.look(for: 2)
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), [entity], "kept at the close it was seen")
        XCTAssertEqual(try unseen(id, in: directory), .review)
        rig.look(for: 0.2)
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), [])
        XCTAssertNil(try unseen(id, in: directory))
    }

    /// The balloon drawing a chat's end is seeing it: passive at once, gone
    /// at the next close of the bar.
    func testTheBalloonSeesAChatsEnd() throws {
        let directory = try temporaryDirectory()
        let id = "0C9E7D1A-8E57-4B9B-8D0F-7F2B4E6A1C33"
        let rig = rig(.smart) { self.unseenChat($0, $1, id: id, directory: directory) }
        defer {
            rig.controller.closeChat()
            rig.controller.chatPanel?.close()
            rig.panel.close()
        }
        rig.controller.openChat(chat: id)
        rig.controller.closeChat()
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.mascot.phase, .idle)
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), [ChatSession.entity(id)])
        rig.look(for: 0.2)
        XCTAssertEqual(rig.controller.sessionRows.rows.map(\.entity), [])
        XCTAssertNil(try unseen(id, in: directory))
    }
}
