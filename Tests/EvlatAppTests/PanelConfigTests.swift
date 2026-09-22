import XCTest
import AppKit
import SwiftUI
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

    private func makePanel(edge: BarPanel.Edge = .right) -> BarPanel {
        BarPanel(edge: edge, size: CGSize(width: 56, height: 220), content: EmptyView())
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
