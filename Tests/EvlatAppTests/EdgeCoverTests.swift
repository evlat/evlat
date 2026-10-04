import XCTest
import AppKit
@testable import EvlatApp

/// The edge's rule over the window list, held with literals in the list's
/// own shape: no test reads the user's windows.
final class EdgeCoverTests: XCTestCase {
    private let me: Int32 = 4242
    /// A 1512 × 982 screen, the bar's window on its right edge with 190 pt
    /// of headroom: the strip is x 1458–1512, y 290–590.
    private let barFrame = CGRect(x: 812, y: 100, width: 700, height: 800)

    private func strip(_ edge: BarPanel.Edge = .right, length: CGFloat = 300) -> EdgeCover.Strip {
        EdgeCover.Strip(window: 77, edge: edge, headroom: 190, width: 54, length: length, pid: me)
    }

    private func window(_ frame: CGRect, number: Int = 1, layer: Int = 0, alpha: Double = 1,
                        pid: Int32 = 99) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: number),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: frame.dictionaryRepresentation]
    }

    private var bar: [String: Any] { window(barFrame, number: 77, layer: 25, pid: me) }

    func testAWindowOverTheStripCoversIt() {
        let editor = window(CGRect(x: 900, y: 300, width: 600, height: 400))
        XCTAssertEqual(EdgeCover.covered([bar, editor], by: strip()), true)
    }

    func testAWindowAwayFromTheStripLeavesItClear() {
        let beside = window(CGRect(x: 100, y: 300, width: 600, height: 400))
        let below = window(CGRect(x: 1000, y: 600, width: 512, height: 300))
        XCTAssertEqual(EdgeCover.covered([bar, beside, below], by: strip()), false)
        XCTAssertEqual(EdgeCover.covered([bar], by: strip()), false, "nothing but the bar")
    }

    /// A window that ends where the strip begins does not cover it.
    func testTouchingIsNotCovering() {
        let flush = window(CGRect(x: 858, y: 300, width: 600, height: 400))
        XCTAssertEqual(EdgeCover.covered([bar, flush], by: strip()), false)
        let overByOne = window(CGRect(x: 859, y: 300, width: 600, height: 400))
        XCTAssertEqual(EdgeCover.covered([bar, overByOne], by: strip()), true)
    }

    /// Only the normal layer counts: the Dock, menus and other status
    /// windows sit above it.
    func testOnlyTheNormalLayerCounts() {
        let panel = window(CGRect(x: 1400, y: 300, width: 112, height: 200), layer: 3)
        XCTAssertEqual(EdgeCover.covered([bar, panel], by: strip()), false)
    }

    func testAFullyTransparentWindowDoesNotCount() {
        let clear = window(CGRect(x: 1400, y: 300, width: 112, height: 200), alpha: 0)
        XCTAssertEqual(EdgeCover.covered([bar, clear], by: strip()), false)
        let faint = window(CGRect(x: 1400, y: 300, width: 112, height: 200), alpha: 0.02)
        XCTAssertEqual(EdgeCover.covered([bar, faint], by: strip()), true, "no alpha threshold")
    }

    /// Evlat's own windows — the balloon, Settings — never cover the edge.
    func testEvlatsOwnWindowsDoNotCount() {
        let settings = window(CGRect(x: 900, y: 300, width: 612, height: 400), number: 78, pid: me)
        XCTAssertEqual(EdgeCover.covered([bar, settings], by: strip()), false)
    }

    func testTheLeftEdgeReadsItsOwnSide() {
        let leftBar = window(CGRect(x: 0, y: 100, width: 700, height: 800), number: 77, layer: 25, pid: me)
        let onLeft = window(CGRect(x: 0, y: 300, width: 400, height: 400))
        let onRight = window(CGRect(x: 600, y: 300, width: 400, height: 400))
        XCTAssertEqual(EdgeCover.covered([leftBar, onLeft], by: strip(.left)), true)
        XCTAssertEqual(EdgeCover.covered([leftBar, onRight], by: strip(.left)), false,
                       "inside the bar's window, not on its edge")
    }

    /// The headroom above the head is no part of the strip, and neither is
    /// what lies past the closed body's length.
    func testOnlyUnderTheHeadAndAsLongAsTheBody() {
        let above = window(CGRect(x: 1300, y: 100, width: 212, height: 189))
        XCTAssertEqual(EdgeCover.covered([bar, above], by: strip()), false, "the headroom")
        let under = window(CGRect(x: 1300, y: 591, width: 212, height: 200))
        XCTAssertEqual(EdgeCover.covered([bar, under], by: strip()), false, "past a 300 pt body")
        XCTAssertEqual(EdgeCover.covered([bar, under], by: strip(length: 400)), true, "a longer body reaches it")
    }

    func testWithoutTheBarsWindowNothingIsKnown() {
        let editor = window(CGRect(x: 900, y: 300, width: 600, height: 400))
        XCTAssertNil(EdgeCover.covered([editor], by: strip()))
        XCTAssertNil(EdgeCover.covered([], by: strip()))
    }

    func testTheStripIsTheClosedBodyOnTheBarsWindow() {
        XCTAssertEqual(EdgeCover.area(of: strip(), in: barFrame),
                       CGRect(x: 1458, y: 290, width: 54, height: 300))
        XCTAssertEqual(EdgeCover.area(of: strip(.left), in: barFrame),
                       CGRect(x: 812, y: 290, width: 54, height: 300))
        XCTAssertNil(EdgeCover.area(of: strip(.top), in: barFrame), "no horizontal bar is built")
    }
}
