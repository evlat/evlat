import XCTest
import AppKit
import SwiftUI
import Combine
import EvlatCore
@testable import EvlatApp

/// The row switch's timing: with the card open, a cursor moving onto another
/// row takes the card there only if it stays a moment.
///
/// The same harness as `HoverIntentTests`: the scheduler hands its items back,
/// so each test decides when the delay "elapses" and can run an item that was
/// meant to be dropped.
@MainActor
final class RowSwitchTests: XCTestCase {
    private var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    private var selections: [String] = []

    private func makeSwitch() -> RowSwitch {
        let rowSwitch = RowSwitch { [unowned self] delay, item in
            self.scheduled.append((delay, item))
        }
        rowSwitch.onSelect = { [unowned self] entity in self.selections.append(entity) }
        return rowSwitch
    }

    override func setUp() {
        super.setUp()
        scheduled = []
        selections = []
    }

    func testStayingOnAnotherRowSwitchesAfterTheDelay() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        XCTAssertEqual(selections, [], "nothing switches on the move itself")
        let pending = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(pending.delay, RowSwitch.delay)
        pending.item.perform()
        XCTAssertEqual(selections, ["b"])
    }

    /// Passing over a row on the way to the card must not take the card with
    /// it: leaving the row drops the pending switch, even if it fires late.
    func testLeavingBeforeTheDelayKeepsTheSelection() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        let pending = try XCTUnwrap(scheduled.last)
        rowSwitch.hover(nil, selected: "a")   // onto the card
        pending.item.perform()
        XCTAssertEqual(selections, [], "a late item is dropped")
    }

    func testBackOnTheSelectedRowDropsThePendingSwitch() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        let pending = try XCTUnwrap(scheduled.last)
        rowSwitch.hover("a", selected: "a")
        pending.item.perform()
        XCTAssertEqual(selections, [])
    }

    /// Moves arrive at display rate; each one over the same row must not push
    /// the switch out.
    func testMovesOverTheSameRowDoNotRestartTheDelay() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        rowSwitch.hover("b", selected: "a")
        rowSwitch.hover("b", selected: "a")
        XCTAssertEqual(scheduled.count, 1)
        try XCTUnwrap(scheduled.first).item.perform()
        XCTAssertEqual(selections, ["b"])
    }

    /// Crossing a second row: only the last row the cursor stayed on wins.
    func testANewRowReplacesThePendingOne() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        let first = try XCTUnwrap(scheduled.last)
        rowSwitch.hover("c", selected: "a")
        let second = try XCTUnwrap(scheduled.last)
        first.item.perform()
        second.item.perform()
        XCTAssertEqual(selections, ["c"])
    }

    /// No card yet: staying on a row for the dwell brings its card up — the
    /// card opens by hover, not by a click (the user's decision).
    func testWithoutASelectionTheDwellBringsTheCardUp() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: nil)
        let pending = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(pending.delay, RowSwitch.dwell)
        XCTAssertEqual(selections, [], "not on the move itself")
        pending.item.perform()
        XCTAssertEqual(selections, ["b"])
    }

    func testPassingOverARowBringsNoCard() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: nil)
        let pending = try XCTUnwrap(scheduled.last)
        rowSwitch.hover(nil, selected: nil)   // off the rows, onto the mascot
        pending.item.perform()
        XCTAssertEqual(selections, [])
    }

    func testCancelDropsThePendingSwitch() throws {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: "a")
        let pending = try XCTUnwrap(scheduled.last)
        rowSwitch.cancel()
        pending.item.perform()
        XCTAssertEqual(selections, [])
    }
}

/// The hover intent's one shortcut: `EVLAT_SELECT` opens the bar at once,
/// and the intent has to know, or the next leave would misfire.
@MainActor
final class HoverOpenNowTests: XCTestCase {
    func testOpenNowOpensWithoutTheDelayAndDropsThePendingOpen() {
        var scheduled: [DispatchWorkItem] = []
        var changes: [Bool] = []
        let intent = HoverIntent { _, item in scheduled.append(item) }
        intent.onChange = { changes.append($0) }
        intent.pointerEntered()
        intent.openNow()
        XCTAssertTrue(intent.isOpen)
        XCTAssertEqual(changes, [true])
        scheduled.forEach { $0.perform() }
        XCTAssertEqual(changes, [true], "the pending open does not fire a second time")
        intent.openNow()
        XCTAssertEqual(changes, [true], "already open: nothing to report")
        intent.pointerExited()
        scheduled.last?.perform()
        XCTAssertEqual(changes, [true, false], "leaving still closes it")
    }

    /// A row switch that fires just after the cursor left selects, and a
    /// select asks the intent to be open. On an open bar that must not
    /// cancel the close already on its way, or the bar stays up with nobody
    /// over it and no leave left to come (`/code-review`).
    func testOpenNowOnAnOpenBarKeepsAPendingClose() throws {
        var scheduled: [DispatchWorkItem] = []
        var changes: [Bool] = []
        let intent = HoverIntent { _, item in scheduled.append(item) }
        intent.onChange = { changes.append($0) }
        intent.openNow()
        intent.pointerExited()
        let close = try XCTUnwrap(scheduled.last)
        intent.openNow()
        close.perform()
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(changes, [true, false])
    }
}

/// Which slot a point is over, read from geometry: the click route and the
/// row switch both go through it.
@MainActor
final class SlotGeometryTests: XCTestCase {
    func testASlotIsItsRingPlusHalfTheGapEachSide() {
        let width = AppController.barWidth
        let top0 = AppController.slotTop(0)
        let size = AppController.indicatorSize
        let half = AppController.indicatorSpacing / 2
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 + size / 2, width: width, rows: 4), 0)
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 - half + 0.5, width: width, rows: 4), 0)
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 + size + half + 0.5, width: width, rows: 4), 1,
                       "no dead band between two rows")
        XCTAssertNil(AppController.slot(fromEdge: 10, fromTop: top0 - half - 1, width: width, rows: 4),
                     "over the mascot is no row")
        XCTAssertNil(AppController.slot(fromEdge: width + 1, fromTop: top0 + 5, width: width, rows: 4),
                     "past the drawn body is no row")
        XCTAssertEqual(AppController.slot(fromEdge: width + 1, fromTop: top0 + 5, width: 200, rows: 4), 0,
                       "the open body's name is the row too")
        let last = SessionRowsModel.slotCount - 1
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: AppController.slotTop(last) + 1,
                                          width: width, rows: 4), last)
        XCTAssertNil(AppController.slot(fromEdge: 10,
                                        fromTop: AppController.slotTop(last) + size + half + 1,
                                        width: width, rows: 4))
    }

    /// The open list holds every row, but only a row whose ring is wholly in
    /// the visible area answers to the cursor: with twenty rows the eighth is
    /// half drawn and takes no hover; past the last row is nothing.
    func testOnlyAWhollyVisibleRowIsASlot() {
        let width: CGFloat = 200
        func centre(_ index: Int) -> CGFloat {
            AppController.slotTop(index) + AppController.indicatorSize / 2
        }
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: centre(6), width: width, rows: 20), 6,
                       "the seventh row is whole")
        XCTAssertNil(AppController.slot(fromEdge: 10, fromTop: AppController.slotTop(7) + 2,
                                        width: width, rows: 20),
                     "the eighth is half drawn: no hover")
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: centre(4), width: width, rows: 8), 4,
                       "past the old four slots")
        XCTAssertNil(AppController.slot(fromEdge: 10, fromTop: centre(3), width: width, rows: 3),
                     "past the last row")

        XCTAssertTrue(AppController.isRowVisible(0, rows: 20))
        XCTAssertTrue(AppController.isRowVisible(6, rows: 20))
        XCTAssertFalse(AppController.isRowVisible(7, rows: 20))
        XCTAssertTrue(AppController.isRowVisible(6, rows: 7), "seven rows: all whole")
        XCTAssertFalse(AppController.isRowVisible(3, rows: 3))
        XCTAssertFalse(AppController.isRowVisible(-1, rows: 3))
    }

    /// The card opens level with its row, but never so low that its tallest
    /// form would leave the window: from the lower rows on, its top is held
    /// at a constant — not the measured height, which moves with each tool
    /// event and would make the top jump. The held card still spans the row.
    func testTheCardIsHeldInsideTheEnvelope() {
        let limit = BarBody.cardTopLimit
        for slot in 0..<SessionRowsModel.slotCount {
            XCTAssertEqual(BarBody.cardTop(slot: slot),
                           max(0, AppController.slotTop(slot) - BarBody.cardLead), accuracy: 0.5,
                           "the first four rows are where they were")
        }
        for slot in 0..<20 {
            let top = BarBody.cardTop(slot: slot)
            XCTAssertLessThanOrEqual(top + AppController.detailCardMaxHeight + AppController.shadowGutter,
                                     AppController.envelopeSize.height + 0.5, "slot \(slot)")
        }
        // The window grew for the usage block; the floor did not.
        XCTAssertEqual(limit, AppController.slotTop(SessionRowsModel.slotCount - 1), accuracy: 0.5)
        XCTAssertEqual(BarBody.cardTop(slot: 6), limit, accuracy: 0.5, "held")
        for slot in 0...6 {
            XCTAssertLessThanOrEqual(BarBody.cardTop(slot: slot), AppController.slotTop(slot),
                                     "the card starts no lower than its row")
        }
    }
}

/// Selection, the card's model, and what the click path does to focus.
@MainActor
final class SelectionTests: XCTestCase {
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

    private func hook(_ name: String, _ session: String, tool: String? = nil,
                      command: String? = nil) -> HookEvent {
        var json: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/tmp/\(session)"]
        if let tool { json["tool_name"] = tool }
        if let command { json["tool_input"] = ["command": command] }
        return HookEvent(json: json)
    }

    // MARK: - DetailModel

    func testNoSelectionWritesNothing() {
        let controller = AppController()
        let provider = Stub()
        provider.signals = [signal("a"), signal("b")]
        controller.registry.register(provider)
        var writes = 0
        let token = controller.detail.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(writes, 0, "no card: the card's model is not touched")
        XCTAssertNil(controller.detail.detail)
    }

    func testTheSelectedSessionsToolUpdatesTheCardAndAnotherDoesNot() throws {
        let controller = AppController()
        controller.registry.register(controller.hooks)
        controller.hooks.handle(hook("UserPromptSubmit", "s-a"))
        controller.hooks.handle(hook("UserPromptSubmit", "s-b"))
        controller.refresh()
        controller.select("s-a")
        XCTAssertEqual(controller.barState.selected, "s-a")
        XCTAssertEqual(controller.detail.detail?.entity, "s-a")

        controller.hooks.handle(hook("PreToolUse", "s-a", tool: "Bash", command: "make bundle"))
        controller.refresh()
        let tool = try XCTUnwrap(controller.detail.detail?.activity?.lastTool)
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.subject, "make bundle")

        var writes = 0
        let token = controller.detail.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }
        controller.hooks.handle(hook("PreToolUse", "s-b", tool: "Read"))
        controller.refresh()
        XCTAssertEqual(writes, 0, "another session's tool does not reach the card")
        XCTAssertEqual(controller.detail.detail?.activity?.lastTool?.name, "Bash")
    }

    func testTheSelectionFollowsItsRowAndDropsWithIt() {
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel()
        defer { controller.panel?.close() }
        provider.signals = [signal("a"), signal("b")]
        controller.refresh()
        controller.select("b")
        XCTAssertEqual(controller.barState.selectedSlot, 1)

        // "b" starts working and leads the column: the card moves with it.
        provider.signals = [signal("a"), signal("b", .working)]
        controller.refresh()
        XCTAssertEqual(controller.barState.selectedSlot, 0)

        provider.signals = [signal("a")]
        controller.refresh()
        XCTAssertNil(controller.barState.selected, "the selected session left: the card closes")
        XCTAssertNil(controller.barState.selectedSlot)
    }

    func testClosingTheBarClearsTheSelection() {
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel()
        defer { controller.panel?.close() }
        provider.signals = [signal("a")]
        controller.refresh()
        controller.select("a")
        XCTAssertTrue(controller.barState.isOpen, "selecting opens the list")
        controller.closeBar()
        XCTAssertNil(controller.barState.selected)
    }

    // MARK: - The card's body

    func testTheCardBodyComesFromTheActivity() {
        typealias A = Signal.Activity
        let bash = A.Tool(name: "Bash", subject: "rm -rf build")
        let edit = A.Tool(name: "Edit", subject: "BarPanel.swift")
        // Waiting: the tool that put the block up, not a sibling's later one.
        XCTAssertEqual(CardBody.pick(A(lastTool: edit, blockingTool: bash, waitKind: .approval)),
                       .tool(bash))
        // Done: the last reply.
        XCTAssertEqual(CardBody.pick(A(lastTool: edit, lastReply: "All green.")), .reply("All green."))
        // Working: the last tool.
        XCTAssertEqual(CardBody.pick(A(lastTool: edit)), .tool(edit))
        // Nothing known: the title alone.
        XCTAssertEqual(CardBody.pick(nil), .none)
        XCTAssertEqual(CardBody.pick(A(pid: 42)), .none)
    }

    /// A seen session's card says "idle", the row's word; a seen outside
    /// job's keeps its own ("failed").
    func testAPassiveSessionsCardSaysIdleAndAJobsKeepsItsWord() {
        let model = DetailModel()
        model.resolveHost = { _ in .notFound }
        model.update(row: SessionRow(entity: "s", label: "api", phase: .review, source: .claude,
                                     passive: true), signal: nil)
        XCTAssertEqual(model.detail?.phase, .idle)
        XCTAssertEqual(StatusLine.statusKey(phase: model.detail!.phase, waitKind: nil), "status.idle")
        model.update(row: SessionRow(entity: "signal:x", label: "x", phase: .failed, kind: .custom,
                                     passive: true), signal: nil)
        XCTAssertEqual(model.detail?.phase, .failed)
    }

    func testTheFooterSaysTimeAndAPartialCount() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entered = now.addingTimeInterval(-125)
        XCTAssertEqual(DetailCard.footer(enteredAt: entered, activity: .init(toolCount: 12), now: now, in: "tr"),
                       "2 dk · 12 araç")
        XCTAssertEqual(DetailCard.footer(enteredAt: nil,
                                         activity: .init(toolCount: 3, countIsPartial: true),
                                         now: now, in: "en"),
                       "~3 tools")
        XCTAssertEqual(DetailCard.footer(enteredAt: nil, activity: .init(toolCount: 1), now: now, in: "en"),
                       "1 tool")
        XCTAssertNil(DetailCard.footer(enteredAt: nil, activity: .init(pid: 1), now: now, in: "en"),
                     "nothing known: no footer")
    }

    func testEveryKeyTheCardAsksForExists() {
        for lang in ["en", "tr"] {
            for key in DetailCard.keys + AnswerView.keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    // MARK: - The gap between the list and the card

    /// The card stands apart from the body, and the gap between them is still
    /// the bar: the card's hover area reaches the body's, so a cursor crossing
    /// from a row to the card is never outside both (the relay reports no
    /// leave), and in the gap it is over no row, which drops a pending switch
    /// before it fires.
    func testCrossingTheGapToTheCardLeavesNothingAndSwitchesNothing() throws {
        let bounds = NSRect(origin: .zero, size: AppController.envelopeSize)
        let openWidth: CGFloat = 150
        let drawn = NSRect(x: bounds.maxX - openWidth - AppController.detailCardGap
                               - AppController.detailCardWidth,
                           y: AppController.slotTop(1) - 16,
                           width: AppController.detailCardWidth, height: 140)
        let rects = BarHostingView.trackingRects(in: bounds, inset: 18, visibleWidth: openWidth,
                                                 visibleLength: AppController.barLength(slots: 4),
                                                 card: AppController.cardHoverRect(drawn, edge: .right),
                                                 flipped: true, edge: .right)
        let card = try XCTUnwrap(rects.card)
        XCTAssertEqual(card.maxX, rects.body.minX, accuracy: 0.5, "no hole between card and body")
        XCTAssertEqual(card.minX, drawn.minX, accuracy: 0.5)

        // A point in the gap, level with the second row: hover area, no row.
        let gap = NSPoint(x: rects.body.minX - AppController.detailCardGap / 2,
                          y: AppController.slotTop(1) + 5)
        XCTAssertTrue(card.contains(gap))
        XCTAssertNil(AppController.slot(fromEdge: bounds.maxX - gap.x, fromTop: gap.y,
                                        width: openWidth, rows: 4))

        // The way there: body → gap/card is one "inside".
        let relay = BarHostingView.PointerRelay()
        var leaves = 0
        relay.handler = { if case .exited = $0 { leaves += 1 } }
        relay.entered(.body)
        relay.entered(.card)
        relay.exited(.body)
        XCTAssertEqual(leaves, 0)

        // And a row brushed on the diagonal toward the card does not take it.
        var scheduled: [DispatchWorkItem] = []
        var selections: [String] = []
        let rowSwitch = RowSwitch { _, item in scheduled.append(item) }
        rowSwitch.onSelect = { selections.append($0) }
        rowSwitch.hover("b", selected: "a")
        rowSwitch.hover(nil, selected: "a")   // the gap
        scheduled.forEach { $0.perform() }
        XCTAssertEqual(selections, [])
    }

    // MARK: - Clicks and focus

    /// The first click on a window of an inactive app is swallowed unless the
    /// view accepts it — and this app is never active.
    func testTheHostingViewAcceptsTheFirstClick() throws {
        let panel = BarPanel(edge: .right, size: AppController.envelopeSize,
                             trackingInset: 18, content: EmptyView())
        let view = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(panel.canBecomeKey)
    }

    /// A click on a ring takes nothing: the card comes by hover (the
    /// user's decision). The one click the bar takes, `[Go to session]`'s,
    /// goes through the real view and leaves Evlat inactive and the panel
    /// not key — only the target is activated.
    func testOnlyTheGoButtonTakesAClickAndItActivatesNothingOfOurs() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let wasActive = app.isActive
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        panel.show()
        var activated: [SessionHost.App] = []
        let target = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
        controller.detail.resolveHost = { _ in .app(target) }
        controller.detail.activate = { activated.append($0); return true }
        provider.signals = [signal("a"), signal("b")]
        controller.refresh()

        let view = try XCTUnwrap(panel.contentView)
        let bounds = view.bounds
        func click(_ inView: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                                                         location: view.convert(inView, to: nil),
                                                         modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
        }
        // The second ring's centre, in the flipped view.
        try click(NSPoint(x: bounds.maxX - AppController.barWidth / 2,
                          y: AppController.slotTop(1) + AppController.indicatorSize / 2))
        XCTAssertNil(controller.barState.selected, "a ring takes no click")
        XCTAssertFalse(controller.barState.isOpen)

        controller.select("b")
        let button = CGRect(x: 40, y: AppController.slotTop(1) + 120, width: 230, height: 28)
        controller.goButtonFrameChanged(button)
        try click(NSPoint(x: button.midX, y: button.midY))
        XCTAssertEqual(controller.detail.pressed, .go, "the press is drawn first")
        XCTAssertEqual(activated, [], "and what it does follows")
        RunLoop.main.run(until: Date().addingTimeInterval(AppController.pressFeedback + 0.1))
        XCTAssertNil(controller.detail.pressed)
        XCTAssertEqual(activated, [target])
        XCTAssertFalse(controller.barState.isOpen, "gone to the session: the list and card close")
        XCTAssertEqual(app.isActive, wasActive, "the click must not activate the app")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }

    /// The cursor over the open list: its row is marked at once, and its
    /// card comes after the dwell — driven by the controller's own route,
    /// with the scheduler handed in.
    func testHoverMarksTheRowAtOnceAndBringsTheCardAfterTheDwell() throws {
        var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        let controller = AppController()
        controller.rowSwitch = RowSwitch { scheduled.append(($0, $1)) }
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        provider.signals = [signal("a"), signal("b")]
        controller.refresh()
        controller.openBar()

        let frame = panel.frame
        func overRow(_ slot: Int) -> CGPoint {
            CGPoint(x: frame.maxX - AppController.barWidth / 2,
                    y: frame.maxY - AppController.slotTop(slot) - AppController.indicatorSize / 2)
        }
        controller.pointerMoved(overRow(1))
        XCTAssertEqual(controller.barState.hovered, "b", "marked at once")
        XCTAssertNil(controller.barState.selected, "the card waits for the dwell")
        let dwell = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(dwell.delay, RowSwitch.dwell)
        dwell.item.perform()
        XCTAssertEqual(controller.barState.selected, "b")

        // With the card up, another row takes it after the shorter switch.
        controller.pointerMoved(overRow(0))
        XCTAssertEqual(controller.barState.hovered, "a")
        let move = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(move.delay, RowSwitch.delay)
        move.item.perform()
        XCTAssertEqual(controller.barState.selected, "a")

        controller.closeBar()
        XCTAssertNil(controller.barState.hovered, "the list and the mark go together")
        XCTAssertNil(controller.barState.selected)
    }

    /// The column reorders under a cursor that does not move: the mark and
    /// the pending switch are re-read for the session now under it, not left
    /// on the one that moved away.
    func testARowMovingFromUnderAStillCursorTakesTheMarkAndTheSwitchWithIt() throws {
        var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        let controller = AppController()
        controller.rowSwitch = RowSwitch { scheduled.append(($0, $1)) }
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        provider.signals = [signal("a"), signal("b")]
        controller.refresh()
        controller.openBar()

        let frame = panel.frame
        let cursor = CGPoint(x: frame.maxX - AppController.barWidth / 2,
                             y: frame.maxY - AppController.slotTop(1) - AppController.indicatorSize / 2)
        controller.mouseLocation = { cursor }
        controller.pointerMoved(cursor)
        XCTAssertEqual(controller.barState.hovered, "b")
        let stale = try XCTUnwrap(scheduled.last)

        // "b" starts working and leads the column; "a" is now under the cursor.
        provider.signals = [signal("a"), signal("b", .working)]
        controller.refresh()
        XCTAssertEqual(controller.barState.hovered, "a", "the mark stays under the cursor")
        stale.item.perform()
        XCTAssertNil(controller.barState.selected, "the switch for the row that left is dropped")
        let fresh = try XCTUnwrap(scheduled.last)
        fresh.item.perform()
        XCTAssertEqual(controller.barState.selected, "a")
    }

    /// A selected row pushed below the visible area has nothing on screen for
    /// the card to hang from: the card closes, as it does for a row that left.
    func testASelectedRowThatIsNoLongerVisibleClosesItsCard() {
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel()
        defer { controller.panel?.close() }
        let names = (0..<12).map { String(format: "e%02d", $0) }
        provider.signals = names.map { signal($0) }
        controller.refresh()
        controller.select("e00")
        XCTAssertEqual(controller.barState.selectedSlot, 0)

        // Eight others start working and lead the list: "e00" drops to the
        // ninth row, past the visible area.
        provider.signals = names.enumerated().map { index, name in
            signal(name, (1...8).contains(index) ? .working : .idle)
        }
        controller.refresh()
        XCTAssertEqual(controller.sessionRows.rows.firstIndex { $0.entity == "e00" }, 8)
        XCTAssertNil(controller.barState.selected, "not visible: the card closes")
        XCTAssertNil(controller.barState.selectedSlot)
    }

    /// The fifth row and beyond are reachable now: hover over a row past the
    /// old four slots brings its card.
    func testARowPastTheOldSlotsTakesTheCard() throws {
        var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        let controller = AppController()
        controller.rowSwitch = RowSwitch { scheduled.append(($0, $1)) }
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        provider.signals = (0..<20).map { signal(String(format: "e%02d", $0)) }
        controller.refresh()
        controller.openBar()
        let frame = panel.frame
        controller.pointerMoved(CGPoint(x: frame.maxX - AppController.barWidth / 2,
                                        y: frame.maxY - AppController.slotTop(6)
                                            - AppController.indicatorSize / 2))
        XCTAssertEqual(controller.barState.hovered, "e06")
        try XCTUnwrap(scheduled.last).item.perform()
        XCTAssertEqual(controller.barState.selectedSlot, 6)

        controller.pointerMoved(CGPoint(x: frame.maxX - AppController.barWidth / 2,
                                        y: frame.maxY - AppController.slotTop(7) - 2))
        XCTAssertNil(controller.barState.hovered, "the half row takes no hover")
    }

    func testEvlatSelectIsReadFromTheEnvironment() {
        XCTAssertEqual(AppController.forcedSelection(["EVLAT_SELECT": "first"]), .first)
        XCTAssertEqual(AppController.forcedSelection(["EVLAT_SELECT": " abc "]), .entity("abc"))
        XCTAssertNil(AppController.forcedSelection(["EVLAT_SELECT": ""]))
        XCTAssertNil(AppController.forcedSelection([:]))
    }
}
