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

    /// No card, nothing to follow: the list without a selection is hover only.
    func testWithoutASelectionNothingIsScheduled() {
        let rowSwitch = makeSwitch()
        rowSwitch.hover("b", selected: nil)
        XCTAssertEqual(scheduled.count, 0)
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

/// The hover intent's one shortcut: a click on a closed bar's ring opens it
/// at once, and the intent has to know, or the next leave would misfire.
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
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 + size / 2, width: width), 0)
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 - half + 0.5, width: width), 0)
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: top0 + size + half + 0.5, width: width), 1,
                       "no dead band between two rows")
        XCTAssertNil(AppController.slot(fromEdge: 10, fromTop: top0 - half - 1, width: width),
                     "over the mascot is no row")
        XCTAssertNil(AppController.slot(fromEdge: width + 1, fromTop: top0 + 5, width: width),
                     "past the drawn body is no row")
        XCTAssertEqual(AppController.slot(fromEdge: width + 1, fromTop: top0 + 5, width: 200), 0,
                       "the open body's name is the row too")
        let last = SessionRowsModel.slotCount - 1
        XCTAssertEqual(AppController.slot(fromEdge: 10, fromTop: AppController.slotTop(last) + 1,
                                          width: width), last)
        XCTAssertNil(AppController.slot(fromEdge: 10,
                                        fromTop: AppController.slotTop(last) + size + half + 1,
                                        width: width))
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

        controller.hooks.handle(hook("PreToolUse", "s-a", tool: "Bash", command: "make paket"))
        controller.refresh()
        let tool = try XCTUnwrap(controller.detail.detail?.activity?.lastTool)
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.subject, "make paket")

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
            for key in DetailCard.keys {
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
                                                 card: AppController.cardHoverRect(drawn),
                                                 flipped: true, edge: .right)
        let card = try XCTUnwrap(rects.card)
        XCTAssertEqual(card.maxX, rects.body.minX, accuracy: 0.5, "no hole between card and body")
        XCTAssertEqual(card.minX, drawn.minX, accuracy: 0.5)

        // A point in the gap, level with the second row: hover area, no row.
        let gap = NSPoint(x: rects.body.minX - AppController.detailCardGap / 2,
                          y: AppController.slotTop(1) + 5)
        XCTAssertTrue(card.contains(gap))
        XCTAssertNil(AppController.slot(fromEdge: bounds.maxX - gap.x, fromTop: gap.y,
                                        width: openWidth))

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

    /// A click on a ring selects its session and opens the list, and the
    /// whole path leaves the app inactive and the panel not key.
    func testClickingARingSelectsWithoutActivating() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let wasActive = app.isActive
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        panel.show()
        provider.signals = [signal("a"), signal("b")]
        controller.refresh()

        let view = try XCTUnwrap(panel.contentView)
        let bounds = view.bounds
        // The second ring's centre, in the flipped view.
        let inView = NSPoint(x: bounds.maxX - AppController.barWidth / 2,
                             y: AppController.slotTop(1) + AppController.indicatorSize / 2)
        let inWindow = view.convert(inView, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow,
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(controller.barState.selected, "b")
        XCTAssertTrue(controller.barState.isOpen, "a ring on the closed bar opens it at once")
        XCTAssertEqual(app.isActive, wasActive, "the click must not activate the app")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }

    func testEvlatSelectIsReadFromTheEnvironment() {
        XCTAssertEqual(AppController.forcedSelection(["EVLAT_SELECT": "first"]), .first)
        XCTAssertEqual(AppController.forcedSelection(["EVLAT_SELECT": " abc "]), .entity("abc"))
        XCTAssertNil(AppController.forcedSelection(["EVLAT_SELECT": ""]))
        XCTAssertNil(AppController.forcedSelection([:]))
    }
}
