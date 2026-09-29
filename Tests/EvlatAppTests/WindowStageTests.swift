import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// A test run stays off the user's screen and keyboard (`WindowStage`):
/// measured before it, a run flashed a left-docked bar over the user's work
/// and its balloon took the keys typed in another app.
@MainActor
final class WindowStageTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["EVLAT_TEST_DESKTOP"] == "1",
                      "on the real desktop by request")
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        suiteName = "evlat.tests.stage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testATestRunIsOffstage() {
        XCTAssertTrue(WindowStage.isOffstage)
        XCTAssertEqual(WindowStage.alpha(1), 0)
    }

    /// Every window a test shows is drawn with no alpha and lets clicks
    /// through; the balloon's keyboard is a flag, so it still opens and
    /// closes as on the screen, and nothing is activated.
    func testTheBarAndTheBalloonAreNeitherDrawnNorGivenTheKeyboard() throws {
        let controller = AppController(defaults: defaults)
        let panel = controller.installPanel(edge: .left)
        defer {
            controller.closeChat()
            controller.chatPanel?.close()
            panel.close()
        }
        panel.show()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0, "the bar is not drawn")
        XCTAssertTrue(panel.ignoresMouseEvents, "the user's clicks go through it")

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.openChat()
        let balloon = try XCTUnwrap(controller.chatPanel)
        XCTAssertTrue(balloon.isVisible)
        XCTAssertEqual(balloon.alphaValue, 0, "the fade in ends at none")
        XCTAssertTrue(balloon.ignoresMouseEvents)
        XCTAssertTrue(balloon.isKeyWindow, "the balloon's own flag")
        XCTAssertFalse(NSRunningApplication.current.isActive)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)

        controller.closeChat()
        XCTAssertFalse(balloon.isVisible)
        XCTAssertFalse(balloon.isKeyWindow, "ordering out resigns the flag")
        XCTAssertFalse(controller.isChatOpen)
    }

    /// Settings' window: made off the screen, and its default activation
    /// brings nothing forward.
    func testTheSettingsWindowIsNotDrawnAndActivatesNothing() {
        let window = AppWindow(make: { AppKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                                    styleMask: [.titled], backing: .buffered, defer: false) })
        let built = window.build()
        defer { built.close() }
        XCTAssertEqual(built.alphaValue, 0)
        XCTAssertTrue(built.ignoresMouseEvents)
        window.show()
        XCTAssertFalse(NSRunningApplication.current.isActive, "the default activation is offstage too")
    }
}
