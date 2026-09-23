import XCTest
@testable import EvlatApp

/// The hover's timing: when the bar opens and when it lets go.
///
/// No wall clock. The scheduler is injected and hands its work items back, so
/// each test decides when a delay "elapses" — and can run an item that was
/// meant to be dropped, which is the only way to show that it is dropped.
/// `DispatchWorkItem.perform()` runs a cancelled item anyway; only the intent's
/// own generation check stands between a stale item and the bar.
@MainActor
final class HoverIntentTests: XCTestCase {
    private var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    private var changes: [Bool] = []

    private func makeIntent() -> HoverIntent {
        let intent = HoverIntent { [unowned self] delay, item in
            self.scheduled.append((delay, item))
        }
        intent.onChange = { [unowned self] open in self.changes.append(open) }
        return intent
    }

    override func setUp() {
        super.setUp()
        scheduled = []
        changes = []
    }

    func testEnteringOpensAfterTheOpeningDelay() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        XCTAssertFalse(intent.isOpen, "nothing opens on the entering event itself")
        let pending = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(pending.delay, HoverIntent.openDelay)
        pending.item.perform()
        XCTAssertTrue(intent.isOpen)
        XCTAssertEqual(changes, [true])
    }

    /// A cursor on its way across the screen brushes the bar. Passing through
    /// must not unfold it.
    func testABriefPassDoesNotOpen() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        let open = try XCTUnwrap(scheduled.last)
        intent.pointerExited()
        // The stale item fires anyway, the way a late `asyncAfter` would.
        open.item.perform()
        XCTAssertFalse(intent.isOpen, "a pass shorter than the delay leaves the bar closed")
        XCTAssertEqual(changes, [])
    }

    /// Slipping off the edge of an open bar and straight back must not fold
    /// it: the tolerance exists for exactly that wobble.
    func testReturningWithinTheToleranceKeepsItOpen() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        try XCTUnwrap(scheduled.last).item.perform()

        intent.pointerExited()
        let close = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(close.delay, HoverIntent.closeTolerance)
        intent.pointerEntered()
        close.item.perform()
        XCTAssertTrue(intent.isOpen, "back inside the tolerance: still open")
        XCTAssertEqual(changes, [true])
    }

    func testLeavingClosesAfterTheTolerance() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        try XCTUnwrap(scheduled.last).item.perform()
        intent.pointerExited()
        try XCTUnwrap(scheduled.last).item.perform()
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(changes, [true, false])
    }

    /// Moves arrive at display rate while the cursor is over the bar and each
    /// one says "inside". If each restarted the delay, a moving cursor would
    /// never open the bar.
    func testMovingInsideDoesNotPushTheOpeningOut() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        intent.pointerEntered()
        intent.pointerEntered()
        XCTAssertEqual(scheduled.count, 1, "one pending open, not one per move")
        try XCTUnwrap(scheduled.first).item.perform()
        XCTAssertTrue(intent.isOpen)
    }

    /// The tracking area is rebuilt when the window grows, and AppKit may
    /// announce the cursor again. An open bar ignores it.
    func testEnteringAnOpenBarSchedulesNothing() throws {
        let intent = makeIntent()
        intent.pointerEntered()
        try XCTUnwrap(scheduled.last).item.perform()
        let before = scheduled.count
        intent.pointerEntered()
        XCTAssertEqual(scheduled.count, before)
        XCTAssertEqual(changes, [true])
    }
}
