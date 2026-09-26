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

    @MainActor private struct Rig {
        let controller: AppController
        let provider: Stub
        let panel: BarPanel
        let timers: Timers

        func set(_ phase: Phase) {
            provider.signals = [Signal(provider: "stub", entity: "s", phase: phase, label: "s",
                                       fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))]
            controller.refresh()
        }

        /// The body's hover area as AppKit holds it.
        func bodyRect() throws -> NSRect {
            let view = try XCTUnwrap(panel.contentView)
            view.updateTrackingAreas()
            let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
            return try XCTUnwrap(owned.first).rect
        }
    }

    private func rig(_ mode: BodyPresence.Mode, edge: BarPanel.Edge = .right) -> Rig {
        let controller = AppController()
        let timers = Timers()
        controller.peekSchedule = { delay, item in timers.pending.append((delay, item)) }
        controller.bodyMode = mode
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel(edge: edge)
        controller.refresh()
        return Rig(controller: controller, provider: provider, panel: panel, timers: timers)
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

    func testTheLeftStripSitsOnTheLeftEdge() throws {
        let rig = rig(.smart, edge: .left)
        defer { rig.panel.close() }
        XCTAssertEqual(try rig.bodyRect(),
                       NSRect(x: 0, y: 0, width: BodyPresence.sliverWidth, height: BodyPresence.triggerLength))
    }

    func testTheSliverTakesNoMascotClick() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let bounds = try XCTUnwrap(rig.panel.contentView).bounds
        let point = CGPoint(x: bounds.maxX - 2,
                            y: bounds.minY + AppController.mascotTopInset + AppController.mascotSize / 2)
        XCTAssertEqual(rig.panel.onClick?(point), false)
        XCTAssertFalse(rig.controller.isChatOpen, "an unseen mascot opens no balloon")
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

    // MARK: - Latch and peek

    func testAFinishLatchesUntilTheBarOpens() throws {
        let rig = rig(.smart)
        defer { rig.panel.close() }
        let controller = rig.controller
        rig.set(.review)
        XCTAssertEqual(controller.latch, .review)
        XCTAssertEqual(controller.peekPhase, .review)
        XCTAssertEqual(controller.barState.presence.level, .peek)
        XCTAssertEqual(try rig.bodyRect().width, BodyPresence.peekWidth, accuracy: 0.5)
        XCTAssertEqual(rig.timers.pending.count, 1)
        XCTAssertEqual(rig.timers.pending[0].delay, AppController.reviewPeek)

        rig.set(.idle)
        XCTAssertNil(controller.peekPhase, "a new phase ends the peek")
        XCTAssertEqual(controller.barState.presence.level, .sliver)
        XCTAssertEqual(controller.barState.presence.dot, .review, "the latch outlives the phase")

        controller.refresh()
        XCTAssertEqual(rig.timers.pending.count, 1, "the poll sets nothing up again")

        controller.openBar()
        XCTAssertNil(controller.latch)
        controller.closeBar()
        XCTAssertNil(controller.barState.presence.dot)
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
        XCTAssertEqual(rig.controller.latch, .failed)
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
        XCTAssertNil(rig.controller.latch)
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertTrue(rig.timers.pending.isEmpty)
        rig.set(.idle)
        rig.controller.closeBar()
        XCTAssertEqual(rig.controller.barState.presence.level, .sliver)
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
}
