import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The menu-bar image: a template, so macOS tints it for either menu bar,
/// sized for the bar, and actually drawn — not an empty square.
final class TrayIconTests: XCTestCase {
    func testTheTrayImageIsATemplateOfMenuBarSize() {
        let image = TrayIcon.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image.accessibilityDescription, "Evlat")
    }

    func testTheOutlineAndTheEyesAreDrawnAndTheFaceIsLeftClear() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        TrayIcon.image().draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()

        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        XCTAssertGreaterThan(alpha(18, 4), 0.5, "the outline's top edge")
        XCTAssertGreaterThan(alpha(18, 18), 0.5, "the first eye")
        XCTAssertGreaterThan(alpha(24, 18), 0.5, "the second eye")
        XCTAssertLessThan(alpha(10, 18), 0.1, "the face left of the eyes stays clear")
    }
    /// Only Hidden hides the waiting signal, so only Hidden × waiting turns
    /// the icon amber; everything else is today's template.
    func testOnlyHiddenWhileWaitingIsAmber() {
        for mode in BodyPresence.Mode.allCases {
            for phase in Phase.allCases {
                XCTAssertEqual(TrayIcon.isAmber(mode: mode, phase: phase), mode == .hidden && phase == .waiting,
                               "\(mode) × \(phase)")
            }
        }
        let amber = TrayIcon.image(amber: true)
        XCTAssertFalse(amber.isTemplate, "an amber template would be tinted back to black")
        XCTAssertEqual(amber.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(TrayIcon.image(amber: false).isTemplate)
    }

    /// The controller writes the icon from the presence, not by hand.
    @MainActor func testTheControllerTurnsTheIconAmberWhenHiddenAndWaiting() {
        _ = NSApplication.shared
        let controller = AppController()
        let panel = controller.installPanel()
        defer { panel.close() }
        controller.bodyMode = .hidden
        XCTAssertFalse(controller.trayAmber)
        controller.mascot.override = .waiting
        controller.applyPresence()
        XCTAssertTrue(controller.trayAmber)
        controller.bodyMode = .smart
        XCTAssertFalse(controller.trayAmber, "smart still has its peek: no amber")
        controller.bodyMode = .hidden
        controller.mascot.override = .review
        controller.applyPresence()
        XCTAssertFalse(controller.trayAmber)
    }
}
