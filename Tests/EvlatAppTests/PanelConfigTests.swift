import XCTest
import AppKit
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The panel's **configuration** is tested in code, not by eye.
///
/// The split is deliberate: the machine-verifiable half of "it never steals
/// focus" lives here (`canBecomeKey`, `styleMask`, `level`,
/// `collectionBehavior`). The end-to-end half — that clicking the bar really
/// leaves the frontmost app focused — belongs to the user and is NOT faked with
/// a synthetic click: *posting* a `CGEvent` needs Accessibility permission
/// (building one and handing it to a view, as `ScrollTests` does, does not), and
/// permission-free design is this project's contract.
@MainActor
final class PanelConfigTests: XCTestCase {
    /// `NSApp` is **nil** inside a test bundle: it is an implicitly unwrapped
    /// global that is not set up until `NSApplication.shared` is touched
    /// (measured — the suite crashed with signal 5). Panels should not be built
    /// without an application object either.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private static let collapsed = CGSize(width: 56, height: 220)
    private static let expanded = CGSize(width: 220, height: 220)
    private static let gutter: CGFloat = 18

    private func makePanel(edge: BarPanel.Edge = .right) -> BarPanel {
        BarPanel(edge: edge, size: Self.collapsed, expandedSize: Self.expanded,
                 trackingInset: Self.gutter, content: EmptyView())
    }

    // MARK: - Hover: the panel grows leftward

    /// The gutter is on the side away from the docked edge; trimming the
    /// wrong side would hover over the shadow and drop real bar.
    func testTheTrackingRectDropsTheGutterOnTheInnerSide() {
        let bounds = NSRect(x: 0, y: 0, width: 72, height: 260)
        let right = BarHostingView.trackingRect(in: bounds, inset: 18, edge: .right)
        XCTAssertEqual(right, NSRect(x: 18, y: 0, width: 54, height: 260))
        let left = BarHostingView.trackingRect(in: bounds, inset: 18, edge: .left)
        XCTAssertEqual(left, NSRect(x: 0, y: 0, width: 54, height: 260))
    }

    /// A window wider than the drawn bar hovers only over the bar: the
    /// transparent room kept for the open body must not open it.
    func testTheTrackingRectFollowsTheVisibleWidth() {
        let bounds = NSRect(x: 0, y: 0, width: 218, height: 200)
        let closed = BarHostingView.trackingRect(in: bounds, inset: 18, visible: 54, edge: .right)
        XCTAssertEqual(closed, NSRect(x: 164, y: 0, width: 54, height: 200))
        let open = BarHostingView.trackingRect(in: bounds, inset: 18, visible: 200, edge: .right)
        XCTAssertEqual(open, NSRect(x: 18, y: 0, width: 200, height: 200))
    }

    /// Setting the visible width rebuilds the one area of ours at that width.
    func testTheTrackingAreaTakesTheVisibleWidth() throws {
        let panel = BarPanel(edge: .right, size: Self.expanded, trackingInset: Self.gutter,
                             content: EmptyView())
        let view = try XCTUnwrap(panel.contentView)
        panel.setVisibleWidth(54)
        view.updateTrackingAreas()
        let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
        XCTAssertEqual(owned.count, 1)
        let rect = try XCTUnwrap(owned.first).rect
        XCTAssertEqual(rect.maxX, Self.expanded.width, accuracy: 0.5)
        XCTAssertEqual(rect.width, 54, accuracy: 0.5)
    }

    /// The open body is as wide as its names, between a floor and a cap: a
    /// fixed width left most of it empty (the user's screenshot).
    /// Under a short name the status line is the wider of the two, at its
    /// widest form, so the body does not move as the minutes pass.
    func testTheOpenBodyHugsItsNames() {
        let short = SessionColumn.namesWidth(["a"])
        let medium = SessionColumn.namesWidth(["oturum-detayi-v2", "bateri"])
        let long = SessionColumn.namesWidth([String(repeating: "w", count: 80)])
        XCTAssertEqual(short, SessionColumn.statusWidth(phase: .idle, waitKind: nil),
                       "a short name: the status line sets the width")
        XCTAssertLessThan(short, medium)
        XCTAssertEqual(long, SessionColumn.nameMaxWidth, "a long name is cut, not the body stretched")
        XCTAssertEqual(SessionColumn.openWidth(namesWidth: 0), SessionColumn.minOpenWidth,
                       accuracy: 0.5, "no names keep the floor")
        XCTAssertEqual(SessionColumn.openWidth(namesWidth: long), AppController.expandedBarWidth,
                       accuracy: 0.5, "the window is as wide as the widest body")
        let fitted = SessionColumn.openWidth(namesWidth: medium)
        XCTAssertGreaterThan(fitted, SessionColumn.minOpenWidth)
        XCTAssertLessThan(fitted, AppController.expandedBarWidth)
    }

    /// The bar opens INTO the screen. Its screen-side edge — and with it the
    /// mascot and the gaze anchor, both read off `maxX` — must not move.
    func testExpandingKeepsTheRightEdgeWhereItWas() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = makePanel(edge: .right)
        panel.reposition(on: screen)
        let before = panel.frame

        panel.setExpanded(true)
        XCTAssertTrue(panel.isExpanded)
        XCTAssertEqual(panel.frame.width, Self.expanded.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, before.maxX, accuracy: 0.5,
                       "the bar grows leftward; the edge stays put")
        XCTAssertEqual(panel.frame.midY, before.midY, accuracy: 0.5)

        panel.setExpanded(false)
        XCTAssertEqual(panel.frame.width, Self.collapsed.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, before.maxX, accuracy: 0.5)
    }

    // MARK: - Length: the body hugs its content

    /// An empty bar is the mascot with room around it; each slot adds one ring
    /// and its spacing; the count takes a slot like a ring. A fixed length
    /// left the lower half of the bar empty.
    func testTheBarLengthFollowsTheSlotsInUse() {
        let empty = AppController.barLength(slots: 0)
        XCTAssertEqual(empty, AppController.mascotTopInset * 2 + AppController.mascotSize,
                       accuracy: 0.5)
        let one = AppController.barLength(slots: 1)
        XCTAssertEqual(one - empty,
                       AppController.indicatorTopGap + AppController.indicatorSize, accuracy: 0.5)
        let two = AppController.barLength(slots: 2)
        XCTAssertEqual(two - one,
                       AppController.indicatorSize + AppController.indicatorSpacing, accuracy: 0.5)
        XCTAssertEqual(AppController.anchorLength,
                       AppController.barLength(slots: SessionRowsModel.slotCount), accuracy: 0.5)
    }

    /// The margins are measured from the body, not the window: the flare
    /// takes the same amount off both ends, and what is left above the mascot
    /// equals what is left under the last slot.
    func testTheBodyLeavesTheSameRoomAtBothEnds() {
        let top = AppController.mascotTopInset - AppController.barFlare
        XCTAssertEqual(top, AppController.bodyMargin, accuracy: 0.5)
        for slots in 0...SessionRowsModel.slotCount {
            let length = AppController.barLength(slots: slots)
            var content = AppController.mascotSize
            if slots > 0 {
                content += AppController.indicatorTopGap
                    + CGFloat(slots) * AppController.indicatorSize
                    + CGFloat(slots - 1) * AppController.indicatorSpacing
            }
            let bottom = length - AppController.mascotTopInset - content - AppController.barFlare
            XCTAssertEqual(bottom, top, accuracy: 0.5, "\(slots) slots")
        }
        XCTAssertGreaterThanOrEqual(top, (AppController.barWidth - AppController.mascotSize) / 2,
                                    "no closer to the end than to the sides")
    }

    /// The count's slot is part of the column the length is fitted to.
    func testTheCountTakesASlot() {
        let model = SessionRowsModel()
        XCTAssertEqual(model.slotsInUse, 0)
        let signals = (0..<6).map { index in
            Signal(provider: "stub", entity: "e\(index)", phase: .idle, label: "s\(index)",
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        }
        model.update(from: signals)
        XCTAssertEqual(model.slotsInUse, SessionRowsModel.slotCount,
                       "three rings and the count")
    }

    // MARK: - The envelope: one window, never resized

    /// The window is built once, big enough for the widest open list with the
    /// card beside it and the card's shadow, and long enough for the tallest
    /// card with its shadow — so no interaction has to resize it.
    func testTheEnvelopeHoldsTheWidestListAndTheTallestCard() {
        let envelope = AppController.envelopeSize
        XCTAssertEqual(envelope.width,
                       AppController.expandedBarWidth + AppController.detailCardGap
                           + AppController.detailCardWidth + AppController.shadowGutter,
                       accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(envelope.height, AppController.anchorLength,
                                    "a full bar still fits")
        XCTAssertGreaterThanOrEqual(envelope.height,
                                    AppController.detailCardMaxHeight + 2 * AppController.shadowGutter,
                                    "the tallest card fits, its shadow too")
        XCTAssertEqual(AppController.slotTop(0),
                       AppController.mascotTopInset + AppController.mascotSize
                           + AppController.indicatorTopGap, accuracy: 0.5)
    }

    /// The whole list did not grow the window; the usage block did, once: the
    /// envelope is the longest open body — seven and a half rows, the summary
    /// and a full block — with the shadow's room, and no more. Every open list
    /// fits inside it. Growing it past that would put the window's foot at the
    /// Dock. One machine's usage group takes the block from six lines to
    /// nine, and the envelope grows by exactly those three lines.
    func testTheEnvelopeFollowsTheBlocksNineLines() {
        XCTAssertEqual(UsageBlockModel.maxLines, 9)
        XCTAssertEqual(AppController.openLength(rows: 1000, usageLines: 9)
                           - AppController.openLength(rows: 1000, usageLines: 6),
                       3 * AppController.usageLineHeight, accuracy: 0.5)
    }

    /// Under the head, the longest open body and its shadow and no more; over
    /// it, the headroom a tall card rises into.
    func testTheEnvelopeGrewOnceForTheLongestOpenBody() {
        XCTAssertEqual(AppController.envelopeSize.height,
                       AppController.headroom
                           + AppController.openLength(rows: 1000, usageLines: UsageBlockModel.maxLines)
                           + AppController.shadowGutter,
                       accuracy: 0.5)
        XCTAssertLessThanOrEqual(AppController.openLength(rows: 1000),
                                 AppController.envelopeSize.height)
    }

    /// The open body hugs the list up to seven and a half rows, and the
    /// summary line under it; no sessions, no list and no summary.
    func testTheOpenLengthFollowsTheRowsUpToSevenAndAHalf() {
        let pitch = AppController.indicatorSize + AppController.indicatorSpacing
        XCTAssertEqual(AppController.openLength(rows: 0), AppController.barLength(slots: 0),
                       accuracy: 0.5, "no sessions: the head alone")
        let one = AppController.openLength(rows: 1)
        let seven = AppController.openLength(rows: 7)
        let eight = AppController.openLength(rows: 8)
        XCTAssertEqual(seven - one, 6 * pitch, accuracy: 0.5)
        XCTAssertEqual(eight - seven, pitch / 2, accuracy: 0.5, "the eighth row is half drawn")
        XCTAssertEqual(AppController.openLength(rows: 20), eight, accuracy: 0.5, "and no more")
        XCTAssertEqual(AppController.listHeight(rows: 20), 7.5 * pitch, accuracy: 0.5)
        XCTAssertGreaterThan(one, AppController.barLength(slots: 1), "room for the summary")
        // The same room closes the far end as opens the head.
        XCTAssertEqual(one - AppController.summaryTop(rows: 1) - AppController.summaryHeight,
                       AppController.mascotTopInset, accuracy: 0.5)
    }

    /// `refresh` keeps both lengths; the hover area takes the one drawn.
    func testTheHoverAreaTakesTheOpenLengthWhileOpen() throws {
        final class Stub: Provider {
            let id = "stub"
            var signals: [Signal] = []
            func currentSignals() -> [Signal] { signals }
        }
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        let panel = controller.installPanel()
        defer { panel.close() }
        let view = try XCTUnwrap(panel.contentView)
        func bodyHeight() throws -> CGFloat {
            view.updateTrackingAreas()
            let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
            return try XCTUnwrap(owned.first).rect.height
        }
        provider.signals = (0..<20).map { index in
            Signal(provider: "stub", entity: "e\(index)", phase: .idle, label: "s\(index)",
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        }
        controller.refresh()
        XCTAssertEqual(controller.barState.length, AppController.anchorLength, accuracy: 0.5,
                       "closed: three rings and the count, as before")
        XCTAssertEqual(controller.barState.openLength, AppController.openLength(rows: 20), accuracy: 0.5)
        XCTAssertEqual(try bodyHeight(), controller.barState.length, accuracy: 0.5)

        controller.openBar()
        XCTAssertEqual(try bodyHeight(), controller.barState.openLength, accuracy: 0.5)
        provider.signals.removeLast(15)
        controller.refresh()
        XCTAssertEqual(try bodyHeight(), AppController.openLength(rows: 5), accuracy: 0.5,
                       "a shorter list while open")
        controller.closeBar()
        XCTAssertEqual(try bodyHeight(), AppController.barLength(slots: 4), accuracy: 0.5,
                       "closed: three rings and the count")
    }

    /// The head is where today's full bar put it: the envelope's extra length
    /// hangs below, so the mascot and the gaze anchor (read off `maxX`/`maxY`)
    /// land on the same screen point as the 4-slot window did.
    func testTheEnvelopeKeepsTheHeadWhereTheFullBarHadIt() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let full = BarPanel(edge: .right,
                            size: CGSize(width: AppController.expandedBarWidth + AppController.shadowGutter,
                                         height: AppController.anchorLength),
                            anchorLength: AppController.anchorLength,
                            trackingInset: Self.gutter, content: EmptyView())
        full.reposition(on: screen)
        let envelope = BarPanel(edge: .right, size: AppController.envelopeSize,
                                anchorLength: AppController.anchorLength,
                                trackingInset: Self.gutter, content: EmptyView())
        envelope.reposition(on: screen)
        XCTAssertEqual(envelope.frame.maxY, full.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(envelope.frame.maxX, full.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(envelope.frame.maxY, screen.frame.midY + AppController.anchorLength / 2,
                       accuracy: 0.5)
        XCTAssertEqual(envelope.frame.size.height, AppController.envelopeSize.height, accuracy: 0.5)
    }

    /// Sessions arriving and leaving, the bar opening and closing: the window
    /// frame is the same throughout. The body's length is drawn instead.
    func testTheWindowFrameNeverChanges() throws {
        final class Stub: Provider {
            let id = "stub"
            var signals: [Signal] = []
            func currentSignals() -> [Signal] { signals }
        }
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel()
        let panel = try XCTUnwrap(controller.panel)
        let before = panel.frame
        XCTAssertEqual(before.size, AppController.envelopeSize)

        provider.signals = (0..<4).map { index in
            Signal(provider: "stub", entity: "e\(index)", phase: .idle, label: "s\(index)",
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        }
        controller.refresh()
        XCTAssertEqual(controller.barState.length, AppController.barLength(slots: 4), accuracy: 0.5)
        XCTAssertEqual(panel.frame, before, "four sessions arrived")

        controller.openBar()
        XCTAssertEqual(panel.frame, before, "opened")
        controller.closeBar()
        XCTAssertEqual(panel.frame, before, "closed")

        provider.signals = []
        controller.refresh()
        XCTAssertEqual(controller.barState.length, AppController.barLength(slots: 0), accuracy: 0.5)
        XCTAssertEqual(panel.frame, before, "the sessions left")
        panel.close()
    }

    // MARK: - Two tracking areas: the drawn body and the card

    /// The body's rectangle is what is drawn: its width from the docked edge
    /// and its length from the head. The envelope below a short bar and the
    /// shadow gutter beside it are not hover.
    func testTheBodyRectIsTheDrawnBody() {
        let bounds = NSRect(x: 0, y: 0, width: 477, height: 394)
        let rects = BarHostingView.trackingRects(in: bounds, inset: 18, visibleWidth: 54,
                                                 visibleLength: 120, card: nil,
                                                 flipped: true, edge: .right)
        XCTAssertEqual(rects.body, NSRect(x: 423, y: 0, width: 54, height: 120))
        XCTAssertNil(rects.card, "no card, only the body")
        let unflipped = BarHostingView.trackingRects(in: bounds, inset: 18, visibleWidth: 54,
                                                     visibleLength: 120, card: nil,
                                                     flipped: false, edge: .right)
        XCTAssertEqual(unflipped.body, NSRect(x: 423, y: 274, width: 54, height: 120),
                       "unflipped, the head is at maxY")
        let card = NSRect(x: 100, y: 60, width: 260, height: 150)
        let both = BarHostingView.trackingRects(in: bounds, inset: 18, visibleWidth: 199,
                                                visibleLength: 230, card: card,
                                                flipped: true, edge: .right)
        XCTAssertEqual(both.body, NSRect(x: 278, y: 0, width: 199, height: 230))
        XCTAssertEqual(both.card, card)
    }

    /// The body rect is laid out from the top, which is only right because
    /// the hosting view is flipped. If it ever were not, hover would sit at
    /// the envelope's bottom and die silently.
    func testTheHostingViewIsFlipped() throws {
        let panel = BarPanel(edge: .right, size: AppController.envelopeSize,
                             trackingInset: Self.gutter, content: EmptyView())
        XCTAssertTrue(try XCTUnwrap(panel.contentView).isFlipped)
    }

    /// One area per drawn part: the body alone, then body and card.
    func testTheTrackingAreasFollowTheBodyAndTheCard() throws {
        let panel = BarPanel(edge: .right, size: AppController.envelopeSize,
                             trackingInset: Self.gutter, content: EmptyView())
        let view = try XCTUnwrap(panel.contentView)
        func owned() -> [NSTrackingArea] {
            view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
        }
        panel.setVisibleWidth(54)
        panel.setVisibleLength(120)
        view.updateTrackingAreas()
        XCTAssertEqual(owned().count, 1)
        let body = try XCTUnwrap(owned().first).rect
        XCTAssertEqual(body.height, 120, accuracy: 0.5)
        XCTAssertEqual(body.minY, 0, accuracy: 0.5)
        XCTAssertEqual(body.maxX, AppController.envelopeSize.width, accuracy: 0.5)

        panel.setCardRect(NSRect(x: 100, y: 60, width: 260, height: 150))
        XCTAssertEqual(owned().count, 2)
        panel.setCardRect(nil)
        XCTAssertEqual(owned().count, 1)
    }

    /// The two areas reach `HoverIntent` as one "inside": crossing from the
    /// body onto the card is not a leave, leaving both is.
    func testTwoAreasReportOneInside() {
        let relay = BarHostingView.PointerRelay()
        var events: [String] = []
        relay.handler = { pointer in
            switch pointer {
            case .entered: events.append("in")
            case .exited: events.append("out")
            case .moved: break
            }
        }
        relay.entered(.body)
        relay.entered(.card)
        relay.exited(.body)
        XCTAssertEqual(events, ["in"], "body → card is not a leave")
        relay.exited(.card)
        XCTAssertEqual(events, ["in", "out"])

        // An exit never goes missing: one without a matching enter (an area
        // installed under the cursor) still closes.
        relay.exited(.body)
        XCTAssertEqual(events, ["in", "out", "out"])

        // The card going away under the cursor is leaving it.
        relay.entered(.card)
        relay.keep([.body])
        XCTAssertEqual(events, ["in", "out", "out", "in", "out"])
    }

    /// With an anchor the head sits where a bar of the anchor's length,
    /// centred on the edge, would start — whatever the bar's own length.
    func testTheAnchorPlacesTheHead() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = BarPanel(edge: .right, size: CGSize(width: 56, height: 86),
                             anchorLength: 200, trackingInset: Self.gutter,
                             content: EmptyView())
        panel.reposition(on: screen)
        XCTAssertEqual(panel.frame.maxY, screen.frame.midY + 100, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 86, accuracy: 0.5)
    }

    /// A screen change while open lays the bar out at the size it has, not at
    /// the collapsed one it was built with.
    func testRepositioningAnExpandedPanelKeepsItsSize() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = makePanel(edge: .right)
        panel.setExpanded(true)
        panel.reposition(on: screen)
        XCTAssertEqual(panel.frame.width, Self.expanded.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, screen.visibleFrame.maxX, accuracy: 0.5)
    }

    /// Growing the window is not a reason to take focus.
    func testExpandingDoesNotTakeFocus() {
        let app = NSApplication.shared
        let wasActive = app.isActive
        let panel = makePanel()
        panel.show()
        panel.setExpanded(true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(app.isActive, wasActive, "opening the bar must not activate the app")
        panel.close()
    }

    /// The area that notices the cursor: always active (the app is
    /// `.accessory` and never becomes active, so the default would never
    /// fire), and on the visible bar — not on the transparent shadow gutter,
    /// where the cursor sees nothing to hover over.
    func testTheTrackingAreaCoversTheBarAndNotTheGutter() throws {
        let panel = makePanel()
        let view = try XCTUnwrap(panel.contentView)

        func area() throws -> NSTrackingArea {
            let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
            XCTAssertEqual(owned.count, 1, "exactly one area of ours, however often it is rebuilt")
            return try XCTUnwrap(owned.first)
        }

        view.updateTrackingAreas()
        let collapsed = try area()
        XCTAssertTrue(collapsed.options.contains(.activeAlways))
        XCTAssertTrue(collapsed.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(collapsed.options.contains(.mouseMoved))
        XCTAssertEqual(collapsed.rect.minX, Self.gutter, accuracy: 0.5)
        XCTAssertEqual(collapsed.rect.maxX, Self.collapsed.width, accuracy: 0.5)

        // An area left at the collapsed size would put the newly revealed
        // strip outside it: the cursor moving onto the open bar would read as
        // leaving, and the bar would fold under it.
        panel.setExpanded(true)
        view.updateTrackingAreas()
        let expanded = try area()
        XCTAssertEqual(expanded.rect.minX, Self.gutter, accuracy: 0.5)
        XCTAssertEqual(expanded.rect.maxX, Self.expanded.width, accuracy: 0.5)
    }

    func testPanelNeverTakesFocus() {
        let panel = makePanel()
        XCTAssertFalse(panel.canBecomeKey, "clicking the bar must not take keyboard focus")
        XCTAssertFalse(panel.canBecomeMain, "the bar cannot become the main window")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "without nonactivatingPanel a click brings the app forward")
        XCTAssertTrue(panel.styleMask.contains(.borderless))
    }

    func testPanelFloatsAboveAndFollowsSpaces() {
        let panel = makePanel()
        XCTAssertEqual(panel.level, .statusBar,
                       "the bar behaves like a system strip; v1's .floating was for the mascot")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces),
                      "must show on every space")
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "must stay above a full-screen app too")
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.hidesOnDeactivate,
                       "the bar must not vanish when Evlat goes to the background")
    }

    func testPanelIsTransparent() {
        let panel = makePanel()
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
    }

    /// `BarPanel` is the sole owner of the window size. With the default
    /// `sizingOptions`, `NSHostingView` resizes the window to its content and
    /// AppKit pins that to the top-left corner (measured in v1). A bar that
    /// unfolds leftward on hover hits the same wall.
    func testHostingViewDoesNotResizeTheWindow() throws {
        let panel = makePanel()
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        XCTAssertEqual(hosting.sizingOptions, [])
    }

    func testRightEdgePanelSitsOnTheUsableRightEdge() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = makePanel(edge: .right)
        panel.reposition(on: screen)
        XCTAssertEqual(panel.frame.maxX, screen.visibleFrame.maxX, accuracy: 0.5,
                       "the right edge sits above the Dock (visibleFrame)")
        // Centring reads the full frame: off visibleFrame the bar would drift
        // vertically whenever the Dock appeared or hid.
        XCTAssertEqual(panel.frame.midY, screen.frame.midY, accuracy: 0.5)
    }

    func testAccessoryPolicyKeepsItOutOfTheDock() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        XCTAssertEqual(app.activationPolicy(), .accessory,
                       "no Dock icon and no Cmd-Tab entry")
    }

    /// Showing the panel must not activate the app. `orderFrontRegardless`
    /// exists for exactly this; `makeKeyAndOrderFront` would bring Evlat
    /// forward.
    func testShowingThePanelDoesNotActivateTheApp() {
        let app = NSApplication.shared
        let wasActive = app.isActive
        let panel = makePanel()
        panel.show()
        XCTAssertEqual(app.isActive, wasActive,
                       "showing the bar must not change the app's active state")
        XCTAssertTrue(panel.isVisible)
        panel.close()
    }

    // MARK: - Placement: pure, on the main screen, either edge

    /// A 1440×900 screen with a 25 pt menu bar; the Dock where the test puts it.
    private static let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private static let dockBottom = NSRect(x: 0, y: 80, width: 1440, height: 795)
    private static let noDock = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private static let dockRight = NSRect(x: 0, y: 0, width: 1360, height: 875)
    private static let dockLeft = NSRect(x: 80, y: 0, width: 1360, height: 875)
    private static let size = AppController.envelopeSize

    private func origin(_ edge: BarPanel.Edge, visible: NSRect) -> NSPoint {
        BarPanel.origin(edge: edge, visibleFrame: visible, frame: Self.screenFrame,
                        size: Self.size, anchorLength: AppController.anchorLength,
                        headroom: AppController.headroom)
    }

    /// Either bar sits against the usable part of its edge, and its head is
    /// where a full bar centred on the whole screen would start.
    func testTheBarHugsTheUsableEdgeOnEitherSide() {
        let right = origin(.right, visible: Self.dockBottom)
        XCTAssertEqual(right.x + Self.size.width, Self.dockBottom.maxX, accuracy: 0.5)
        let left = origin(.left, visible: Self.dockBottom)
        XCTAssertEqual(left.x, Self.dockBottom.minX, accuracy: 0.5)
        for point in [right, left] {
            // The head, under the headroom.
            XCTAssertEqual(point.y + Self.size.height - AppController.headroom,
                           Self.screenFrame.midY + AppController.anchorLength / 2, accuracy: 0.5)
        }
    }

    /// The Dock at the bottom coming and going moves neither bar: along the
    /// edge the whole frame is read, not `visibleFrame`.
    func testTheDockAtTheBottomMovesNeitherBar() {
        for edge in [BarPanel.Edge.right, .left] {
            XCTAssertEqual(origin(edge, visible: Self.dockBottom), origin(edge, visible: Self.noDock),
                           "\(edge)")
        }
    }

    /// Only the Dock on the bar's own edge pushes it; the other bar stays.
    func testOnlyTheDockOnItsOwnEdgePushesTheBar() {
        XCTAssertEqual(origin(.right, visible: Self.dockRight).x + Self.size.width,
                       Self.dockRight.maxX, accuracy: 0.5, "the right bar leans on the Dock")
        XCTAssertEqual(origin(.left, visible: Self.dockRight), origin(.left, visible: Self.noDock),
                       "the left bar does not move for a Dock on the right")
        XCTAssertEqual(origin(.left, visible: Self.dockLeft).x, Self.dockLeft.minX, accuracy: 0.5,
                       "the left bar leans on a Dock on the left")
        XCTAssertEqual(origin(.right, visible: Self.dockLeft), origin(.right, visible: Self.noDock))
    }

    /// The main screen — the first, the menu bar's — whatever else is
    /// attached: a secondary screen to the lower left has a negative origin,
    /// and neither it nor the focus decides where the bar goes.
    func testTheBarGoesOnTheMainScreenBesideASecondaryOne() throws {
        let secondary = NSRect(x: -1920, y: -300, width: 1920, height: 1080)
        let screens = [(frame: Self.screenFrame, visibleFrame: Self.dockBottom),
                       (frame: secondary, visibleFrame: secondary)]
        for edge in [BarPanel.Edge.right, .left] {
            let point = try XCTUnwrap(BarPanel.origin(edge: edge, screens: screens, size: Self.size,
                                                      anchorLength: AppController.anchorLength,
                                                      headroom: AppController.headroom))
            XCTAssertEqual(point, origin(edge, visible: Self.dockBottom), "\(edge)")
            XCTAssertTrue(Self.screenFrame.contains(NSRect(origin: point, size: Self.size)), "\(edge)")
        }
        XCTAssertNil(BarPanel.origin(edge: .right, screens: [], size: Self.size,
                                     anchorLength: AppController.anchorLength),
                     "no screen: nothing to place on")
    }

    /// A panel whose origin is on no screen goes back to the main one.
    func testRepositionBringsABrokenOriginBackToTheMainScreen() throws {
        let main = try XCTUnwrap(NSScreen.screens.first)
        for edge in [BarPanel.Edge.right, .left] {
            let panel = BarPanel(edge: edge, size: Self.size, anchorLength: AppController.anchorLength,
                                 trackingInset: Self.gutter, content: EmptyView())
            panel.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
            panel.reposition()
            XCTAssertEqual(panel.frame.origin,
                           BarPanel.origin(edge: edge, visibleFrame: main.visibleFrame, frame: main.frame,
                                           size: Self.size, anchorLength: AppController.anchorLength),
                           "\(edge)")
        }
    }

    // MARK: - The left edge: the mirror of the right

    /// Distance in from the docked edge, and back: one helper for every
    /// hit test, the gaze anchor and the card's hover area.
    func testTheDistanceFromTheEdgeMirrors() {
        let rect = NSRect(x: 100, y: 0, width: 400, height: 300)
        XCTAssertEqual(BarPanel.Edge.right.inset(of: 470, in: rect), 30)
        XCTAssertEqual(BarPanel.Edge.left.inset(of: 130, in: rect), 30)
        XCTAssertEqual(BarPanel.Edge.right.x(atInset: 30, in: rect), 470)
        XCTAssertEqual(BarPanel.Edge.left.x(atInset: 30, in: rect), 130)
        XCTAssertTrue(BarPanel.Edge.left.isLeft)
        XCTAssertFalse(BarPanel.Edge.right.isLeft)
    }

    /// The eyes' centre is half a bar in from whichever edge the bar is on.
    func testTheGazeAnchorIsHalfABarInFromTheEdge() {
        let frame = NSRect(x: 0, y: 100, width: 477, height: 394)
        let left = AppController.gazeAnchor(frame: frame, edge: .left)
        XCTAssertEqual(left.x, AppController.barWidth / 2, accuracy: 0.5)
        let right = AppController.gazeAnchor(frame: frame, edge: .right)
        XCTAssertEqual(right.x, frame.maxX - AppController.barWidth / 2, accuracy: 0.5)
        for anchor in [left, right] {
            XCTAssertEqual(anchor.y, frame.maxY - AppController.headroom - AppController.mascotTopInset - AppController.mascotSize / 2,
                           accuracy: 0.5)
        }
    }

    /// On the left the hover areas start at the window's left edge; the
    /// gutter is on the right.
    func testTheTrackingAreasSitOnTheLeftEdge() throws {
        let panel = BarPanel(edge: .left, size: AppController.envelopeSize,
                             trackingInset: Self.gutter, content: EmptyView())
        let view = try XCTUnwrap(panel.contentView)
        panel.setVisibleWidth(54)
        panel.setVisibleLength(120)
        view.updateTrackingAreas()
        let owned = view.trackingAreas.filter { $0.owner is BarHostingView.PointerRelay }
        let body = try XCTUnwrap(owned.first).rect
        XCTAssertEqual(body, NSRect(x: 0, y: 0, width: 54, height: 120))
    }

    /// The gap between body and card is hover on the body's side of the
    /// card: right of it on the right edge, left of it on the left.
    func testTheCardsHoverGapIsOnTheBodysSide() {
        let card = NSRect(x: 200, y: 60, width: AppController.detailCardWidth, height: 140)
        let gap = AppController.detailCardGap
        let right = AppController.cardHoverRect(card, edge: .right)
        XCTAssertEqual(right.minX, card.minX, accuracy: 0.5)
        XCTAssertEqual(right.maxX, card.maxX + gap, accuracy: 0.5)
        let left = AppController.cardHoverRect(card, edge: .left)
        XCTAssertEqual(left.minX, card.minX - gap, accuracy: 0.5)
        XCTAssertEqual(left.maxX, card.maxX, accuracy: 0.5)
        XCTAssertEqual(left.height, card.height)
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    private func controller(edge: BarPanel.Edge, rows: Int) -> AppController {
        let controller = AppController()
        let provider = Stub()
        controller.registry.register(provider)
        controller.installPanel(edge: edge)
        provider.signals = (0..<rows).map { index in
            Signal(provider: "stub", entity: "e\(index)", phase: .idle, label: "s\(index)",
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
        }
        controller.refresh()
        return controller
    }

    /// On a left panel the row under the cursor and the list a scroll
    /// counts over are measured from the left edge.
    func testRowsAndScrollingAreReadFromTheLeftEdge() throws {
        let controller = controller(edge: .left, rows: 4)
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        XCTAssertEqual(controller.barState.edge, .left)
        controller.openBar()
        let frame = panel.frame
        let y = frame.maxY - AppController.headroom - AppController.slotTop(1) - AppController.indicatorSize / 2
        controller.pointerMoved(CGPoint(x: frame.minX + AppController.barWidth / 2, y: y))
        XCTAssertEqual(controller.barState.hovered, "e1", "the ring near the left edge")
        controller.pointerMoved(CGPoint(x: frame.maxX - AppController.barWidth / 2, y: y))
        XCTAssertNil(controller.barState.hovered, "the far side of the window is no row")

        let bounds = try XCTUnwrap(panel.contentView).bounds
        let listY = AppController.headroom + AppController.slotTop(1) + 5
        XCTAssertTrue(controller.scroll(at: CGPoint(x: bounds.minX + 10, y: listY), deltaY: 0, precise: true))
        XCTAssertFalse(controller.scroll(at: CGPoint(x: bounds.minX + controller.barState.openWidth + 4,
                                                     y: listY), deltaY: 0, precise: true),
                       "past the open body")
    }

    /// Whether this process is the active application, as the system sees
    /// it. `NSApp.isActive` is not enough inside a test: no event loop runs,
    /// so it stayed `false` even after `activate` had made the test runner
    /// frontmost (measured). The run loop is turned briefly first.
    private func isFrontmost() -> Bool {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return NSRunningApplication.current.isActive || NSApplication.shared.isActive
    }

    /// Changing the edge moves the same panel: an open bar closes through
    /// the intent (the next entry opens it again), the window lands on the
    /// new edge of the main screen, the body is told — and nothing is
    /// activated, the panel never key.
    func testDockingClosesMovesAndTakesNoFocus() throws {
        // The app's own policy. A test runner's default is `.prohibited`,
        // under which `activate` does nothing and this test would pass over
        // a `dock` that activates (measured: the mutation went unseen).
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = controller(edge: .right, rows: 4)
        let panel = try XCTUnwrap(controller.panel)
        defer { panel.close() }
        panel.show()
        XCTAssertFalse(isFrontmost(), "precondition: the test runner is not frontmost")
        let main = try XCTUnwrap(NSScreen.screens.first)
        // Wired as launch wires it: the intent opens and closes the body.
        controller.hover.onChange = { [unowned controller] open in
            open ? controller.openBar() : controller.closeBar()
        }
        controller.hover.openNow()
        XCTAssertTrue(controller.barState.isOpen)
        let rects = { () -> NSRect? in
            panel.contentView?.trackingAreas.first { $0.owner is BarHostingView.PointerRelay }?.rect
        }

        controller.dock(.left)
        XCTAssertFalse(controller.barState.isOpen, "the open list closes")
        XCTAssertFalse(controller.hover.isOpen, "and the intent knows it")
        XCTAssertTrue(controller.panel === panel, "the same panel, not a new one")
        XCTAssertEqual(panel.edge, .left)
        XCTAssertEqual(controller.barState.edge, .left)
        XCTAssertEqual(panel.frame.minX, main.visibleFrame.minX, accuracy: 0.5)
        panel.contentView?.updateTrackingAreas()
        XCTAssertEqual(try XCTUnwrap(rects()).minX, 0, accuracy: 0.5, "hover on the left edge")
        XCTAssertFalse(isFrontmost(), "docking must not activate Evlat")
        XCTAssertFalse(panel.isKeyWindow)

        controller.hover.openNow()
        XCTAssertTrue(controller.barState.isOpen, "the next entry opens the bar")
        controller.dock(.right)
        XCTAssertEqual(panel.frame.maxX, main.visibleFrame.maxX, accuracy: 0.5)
        XCTAssertFalse(isFrontmost())
    }

    // MARK: - EVLAT_EDGE

    func testTheForcedEdgeIsReadFromTheEnvironment() {
        XCTAssertEqual(AppController.forcedEdge(["EVLAT_EDGE": "left"]), .left)
        XCTAssertEqual(AppController.forcedEdge(["EVLAT_EDGE": " Right "]), .right)
        XCTAssertNil(AppController.forcedEdge(["EVLAT_EDGE": "top"]), "not a supported edge")
        XCTAssertNil(AppController.forcedEdge(["EVLAT_EDGE": ""]))
        XCTAssertNil(AppController.forcedEdge([:]))
    }
}
