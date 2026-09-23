import XCTest
import AppKit
import SwiftUI
import Combine
import EvlatCore
@testable import EvlatApp

/// The open list scrolls inside the body (`006/phase-2`): the offset is held
/// to its bounds, visibility and the card follow it, and a still cursor's
/// row is read again after it moves.
@MainActor
final class ScrollTests: XCTestCase {
    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func signal(_ entity: String, _ phase: Phase = .idle) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: entity,
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func names(_ count: Int) -> [String] {
        (0..<count).map { String(format: "e%02d", $0) }
    }

    /// A controller with `count` idle rows, its panel installed and the list
    /// open. The scheduler is handed back so no switch fires on its own.
    private final class Scheduled { var items: [DispatchWorkItem] = [] }

    private func openController(rows count: Int, scheduled: Scheduled = Scheduled())
        -> (AppController, Stub) {
        let controller = AppController()
        controller.rowSwitch = RowSwitch { _, item in scheduled.items.append(item) }
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel()
        provider.signals = names(count).map { signal($0) }
        controller.refresh()
        controller.openBar()
        return (controller, provider)
    }

    // MARK: - Bounds

    /// The largest offset leaves the last row whole at the bottom, with half
    /// a gap under it, and a half row at the top: the mirror of the start.
    func testTheLargestOffsetShowsTheLastRowWhole() {
        XCTAssertEqual(AppController.maxScrollOffset(rows: 20), 20 * 30 - 225, accuracy: 0.01)
        XCTAssertEqual(AppController.maxScrollOffset(rows: 8), 15, accuracy: 0.01)
        XCTAssertEqual(AppController.maxScrollOffset(rows: 7), 0, "seven rows fit: nothing to scroll")
        XCTAssertEqual(AppController.maxScrollOffset(rows: 0), 0)

        let end = AppController.maxScrollOffset(rows: 20)
        XCTAssertTrue(AppController.isRowVisible(19, rows: 20, offset: end), "the last row is whole")
        XCTAssertTrue(AppController.isRowVisible(13, rows: 20, offset: end))
        XCTAssertFalse(AppController.isRowVisible(12, rows: 20, offset: end), "the half row is at the top")
    }

    func testTheOffsetIsHeldToItsBoundsShortenedAndResetOnClose() {
        let (controller, provider) = openController(rows: 20)
        defer { controller.panel?.close() }
        let end = AppController.maxScrollOffset(rows: 20)

        controller.scrolled(by: -10_000)   // fingers up: the list moves up
        XCTAssertEqual(controller.listScroll.offset, end, accuracy: 0.01, "held at the end")
        controller.scrolled(by: 10_000)
        XCTAssertEqual(controller.listScroll.offset, 0, "held at the start")
        controller.scrolled(by: -45)
        XCTAssertEqual(controller.listScroll.offset, 45, accuracy: 0.01)

        // Scrolled to the end, the list shortens: the offset comes back to
        // the new end, so the last row stays whole.
        controller.scrolled(by: -10_000)
        provider.signals = names(10).map { signal($0) }
        controller.refresh()
        XCTAssertEqual(controller.listScroll.offset, AppController.maxScrollOffset(rows: 10), accuracy: 0.01)
        provider.signals = names(5).map { signal($0) }
        controller.refresh()
        XCTAssertEqual(controller.listScroll.offset, 0)

        provider.signals = names(20).map { signal($0) }
        controller.refresh()
        controller.scrolled(by: -100)
        controller.closeBar()
        XCTAssertEqual(controller.listScroll.offset, 0, "a closed list starts at the top again")
        controller.scrolled(by: -100)
        XCTAssertEqual(controller.listScroll.offset, 0, "a closed bar does not scroll")
    }

    /// The model is written only when the offset moves: a push against a
    /// bound publishes nothing.
    func testTheOffsetIsWrittenOnlyWhenItMoves() {
        let scroll = ListScroll()
        var writes = 0
        let token = scroll.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }
        XCTAssertFalse(scroll.set(-20, max: 100))
        XCTAssertTrue(scroll.set(40, max: 100))
        XCTAssertFalse(scroll.set(40, max: 100))
        XCTAssertTrue(scroll.set(500, max: 100))
        XCTAssertEqual(scroll.offset, 100)
        XCTAssertEqual(writes, 2)
    }

    // MARK: - Visibility, slots and the card

    /// Half a row down, the eighth ring is whole and the first is not.
    func testVisibilityAndSlotsFollowTheOffset() {
        let half = AppController.rowPitch / 2
        XCTAssertFalse(AppController.isRowVisible(7, rows: 20))
        XCTAssertTrue(AppController.isRowVisible(7, rows: 20, offset: half), "the eighth row is whole")
        XCTAssertFalse(AppController.isRowVisible(0, rows: 20, offset: half), "the first is cut")
        XCTAssertFalse(AppController.isRowVisible(8, rows: 20, offset: half))

        // The point where the first ring was is over the second row a row down.
        let y = AppController.slotTop(0) + AppController.indicatorSize / 2
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: y, width: 200, rows: 20,
                                          offset: AppController.rowPitch), 1)
        XCTAssertNil(AppController.slot(fromEdge: 10, fromTop: AppController.listTop + 2, width: 200,
                                        rows: 20, offset: half),
                     "the cut first row takes no hover")
    }

    /// The card's top moves with its row, point for point, and is still held
    /// inside the envelope.
    func testTheCardTopFollowsTheOffset() {
        let lead = BarBody.cardLead
        XCTAssertEqual(BarBody.cardTop(slot: 8, offset: 180),
                       AppController.slotTop(8) - 180 - lead, accuracy: 0.01)
        XCTAssertEqual(BarBody.cardTop(slot: 19, offset: AppController.maxScrollOffset(rows: 20)),
                       BarBody.cardTopLimit, accuracy: 0.01, "the lowest row's card is held")
        XCTAssertEqual(BarBody.cardTop(slot: 3, offset: 0), BarBody.cardTop(slot: 3), accuracy: 0.01)
    }

    func testTheSelectedRowScrolledOutOfSightClosesItsCard() {
        let (controller, _) = openController(rows: 20)
        defer { controller.panel?.close() }
        controller.select("e02")
        XCTAssertEqual(controller.barState.selectedSlot, 2)

        controller.scrolled(by: -60)   // two rows: "e02" is at the top, whole
        XCTAssertEqual(controller.barState.selected, "e02", "still whole: the card stays")
        XCTAssertEqual(controller.barState.selectedSlot, 2, "the slot is the row's, not the screen's")

        controller.scrolled(by: -10)
        XCTAssertNil(controller.barState.selected, "cut at the top: the card closes")
        XCTAssertNil(controller.barState.selectedSlot)
    }

    /// The list moves under a cursor that does not: its row is read again,
    /// the mark moves, and the switch is for the row now under it.
    func testAStillCursorsRowIsReadAgainAfterScrolling() throws {
        let scheduled = Scheduled()
        let (controller, _) = openController(rows: 20, scheduled: scheduled)
        defer { controller.panel?.close() }
        let frame = try XCTUnwrap(controller.panel?.frame)
        let cursor = CGPoint(x: frame.maxX - AppController.barWidth / 2,
                             y: frame.maxY - AppController.slotTop(3) - AppController.indicatorSize / 2)
        controller.mouseLocation = { cursor }
        controller.pointerMoved(cursor)
        XCTAssertEqual(controller.barState.hovered, "e03")

        controller.scrolled(by: -2 * AppController.rowPitch)
        XCTAssertEqual(controller.barState.hovered, "e05", "the row now under the cursor")
        try XCTUnwrap(scheduled.items.last).perform()
        XCTAssertEqual(controller.barState.selected, "e05")
    }

    /// A row selected while out of sight (`EVLAT_SELECT`) is scrolled into
    /// view rather than selected and dropped at once.
    func testSelectingAHiddenRowScrollsItIntoView() {
        let (controller, _) = openController(rows: 20)
        defer { controller.panel?.close() }
        controller.select("e12")
        XCTAssertEqual(controller.barState.selected, "e12")
        XCTAssertEqual(controller.barState.selectedSlot, 12)
        XCTAssertEqual(controller.listScroll.offset, 13 * AppController.rowPitch - 225, accuracy: 0.01,
                       "just far enough: the row at the bottom")

        controller.select("e01")
        XCTAssertEqual(controller.listScroll.offset, AppController.rowPitch, accuracy: 0.01,
                       "back up: the row at the top")
        controller.select("e03")
        XCTAssertEqual(controller.listScroll.offset, AppController.rowPitch, accuracy: 0.01,
                       "a visible row moves nothing")
    }

    /// At the start only the bottom fades, in the middle both, at the end
    /// only the top; a list that fits fades nowhere.
    func testTheFadesFollowTheOffset() {
        let end = AppController.maxScrollOffset(rows: 20)
        let start = SessionColumn.fades(offset: 0, maxOffset: end)
        XCTAssertEqual(start.top, 0)
        XCTAssertEqual(start.bottom, 1)
        let middle = SessionColumn.fades(offset: end / 2, maxOffset: end)
        XCTAssertEqual(middle.top, 1)
        XCTAssertEqual(middle.bottom, 1)
        let last = SessionColumn.fades(offset: end, maxOffset: end)
        XCTAssertEqual(last.top, 1)
        XCTAssertEqual(last.bottom, 0)
        let nearStart = SessionColumn.fades(offset: 6, maxOffset: end)
        XCTAssertEqual(nearStart.top, 0.25, accuracy: 0.01, "the top fade grows in, it does not pop")

        let eight = AppController.maxScrollOffset(rows: 8)
        XCTAssertEqual(SessionColumn.fades(offset: 0, maxOffset: eight).bottom, 1, "a short list's bottom is whole")
        XCTAssertEqual(SessionColumn.fades(offset: eight, maxOffset: eight).top, 1)
        let fits = SessionColumn.fades(offset: 0, maxOffset: AppController.maxScrollOffset(rows: 7))
        XCTAssertEqual(fits.top, 0)
        XCTAssertEqual(fits.bottom, 0)
    }

    // MARK: - Where a scroll is taken

    /// Only over the open list: not over the mascot, the summary, the card's
    /// side or a closed bar — those go on to SwiftUI.
    func testAScrollIsTakenOnlyOverTheOpenList() throws {
        let (controller, _) = openController(rows: 20)
        defer { controller.panel?.close() }
        let bounds = try XCTUnwrap(controller.panel?.contentView?.bounds)
        let x = bounds.maxX - AppController.barWidth / 2
        let list = CGPoint(x: x, y: AppController.slotTop(2) + 5)
        XCTAssertTrue(controller.scroll(at: list, deltaY: -12, precise: true))
        XCTAssertEqual(controller.listScroll.offset, 12, accuracy: 0.01)

        XCTAssertFalse(controller.scroll(at: CGPoint(x: x, y: AppController.mascotTopInset + 5),
                                         deltaY: -12, precise: true), "the mascot")
        XCTAssertFalse(controller.scroll(at: CGPoint(x: x, y: AppController.summaryTop(rows: 20) + 4),
                                         deltaY: -12, precise: true), "the summary line")
        XCTAssertFalse(controller.scroll(at: CGPoint(x: bounds.maxX - controller.barState.openWidth - 4,
                                                     y: list.y),
                                         deltaY: -12, precise: true), "past the body, toward the card")
        XCTAssertEqual(controller.listScroll.offset, 12, accuracy: 0.01)

        // A notched wheel speaks in lines.
        XCTAssertTrue(controller.scroll(at: list, deltaY: -1, precise: false))
        XCTAssertEqual(controller.listScroll.offset, 12 + AppController.lineScroll, accuracy: 0.01)

        controller.closeBar()
        XCTAssertFalse(controller.scroll(at: list, deltaY: -12, precise: true), "closed: nothing to scroll")
    }

    /// The hosting view hands the wheel to its closure and falls back to
    /// SwiftUI when it is declined.
    func testTheHostingViewHandsTheWheelOver() throws {
        let panel = BarPanel(edge: .right, size: AppController.envelopeSize,
                             trackingInset: 18, content: EmptyView())
        defer { panel.close() }
        var seen: [(CGPoint, CGFloat, Bool)] = []
        panel.onScroll = { point, dy, precise in seen.append((point, dy, precise)); return true }
        let view = try XCTUnwrap(panel.contentView)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: -7, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        let wasActive = NSApplication.shared.isActive
        view.scrollWheel(with: event)
        XCTAssertEqual(NSApplication.shared.isActive, wasActive, "a scroll activates nothing")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.1 ?? 0, event.scrollingDeltaY, accuracy: 0.01)
        XCTAssertEqual(seen.first?.2, event.hasPreciseScrollingDeltas)
    }

    // MARK: - EVLAT_SCROLL

    func testEvlatScrollIsReadFromTheEnvironment() {
        XCTAssertEqual(AppController.forcedScroll(["EVLAT_SCROLL": "120"]), 120)
        XCTAssertEqual(AppController.forcedScroll(["EVLAT_SCROLL": " 37.5 "]), 37.5)
        XCTAssertNil(AppController.forcedScroll(["EVLAT_SCROLL": "end"]), "unreadable: ignored")
        XCTAssertNil(AppController.forcedScroll(["EVLAT_SCROLL": "inf"]))
        XCTAssertNil(AppController.forcedScroll(["EVLAT_SCROLL": ""]))
        XCTAssertNil(AppController.forcedScroll([:]))
    }
}
