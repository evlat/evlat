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
/// a synthetic click: `CGEvent` needs Accessibility permission, and
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

    /// The length changes at the far end. The head — the mascot and the gaze
    /// anchor, read off `maxY` — does not move, open or closed.
    func testChangingTheLengthKeepsTheHead() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = makePanel(edge: .right)
        panel.reposition(on: screen)
        let before = panel.frame

        panel.setLength(300, animated: false)
        XCTAssertEqual(panel.frame.height, 300, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, before.maxY, accuracy: 0.5, "the head stays")
        XCTAssertEqual(panel.frame.maxX, before.maxX, accuracy: 0.5)

        panel.setExpanded(true)
        XCTAssertEqual(panel.frame.height, 300, accuracy: 0.5, "opening keeps the length")
        panel.setLength(120, animated: false)
        XCTAssertEqual(panel.frame.width, Self.expanded.width, accuracy: 0.5,
                       "a length change while open stays open")
        XCTAssertEqual(panel.frame.maxY, before.maxY, accuracy: 0.5)
        panel.setExpanded(false)
        XCTAssertEqual(panel.frame.height, 120, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, before.maxY, accuracy: 0.5)
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
}
