import XCTest
import SwiftUI
@testable import EvlatApp

/// The body's geometry. Aesthetics are judged by eye, but **two claims are
/// measurable** and both can break silently: being flush with the edge, and the
/// direction of the inverse curve at the ends.
final class BarShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 54, height: 260)

    /// The shape touches the screen edge. If it does not, the bar reads as
    /// something stuck on.
    func testShapeTouchesTheScreenEdge() {
        let box = BarShape(edge: .right).path(in: rect).boundingRect
        XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.5, "flush with the right edge")
    }

    /// The vertical reach at the edge is **longer** than the body's: the flare
    /// opens toward the bezel, so the shape fills the whole window.
    func testFlareReachesTheFullHeightAtTheEdge() {
        let path = BarShape(flare: 20, edge: .right).path(in: rect)
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.maxY, rect.maxY, accuracy: 0.5)
    }

    /// The curve's **direction**: near the edge the shape must be filled at a
    /// height where the inner side is still empty. The first version bent the
    /// wrong way, and this is the test that catches it.
    func testFlareCurvesInwardNotOutward() {
        let flare = CGFloat(20)
        let path = BarShape(corner: 18, flare: flare, edge: .right).path(in: rect)
        // The curve starts **tangent** to the edge: at the very top the flare
        // is still 0.2pt wide (solved: x = w − flare·t², y = flare(2t − t²)).
        // The place to sample is near the body's top edge, where the width is
        // roughly half the flare.
        let y = flare * 0.9
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 2, y: y)),
                      "right against the edge, above the body, the flare must be filled")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 40, y: y)),
                       "the inner side at the same height must be EMPTY — filled means the curve is inverted")
        // And the curve really has to hug the edge: near the top there is a
        // sliver of fill, but it must not reach half the body's width.
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - rect.width / 2, y: 2)),
                       "tangent at the top; it must not fill as far as half the width")
    }

    /// The middle of the body is always filled.
    func testBodyIsFilled() {
        let path = BarShape(edge: .right).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// Inner corners are rounded, so the body's inner-top corner point is empty.
    func testInnerCornersAreRounded() {
        let path = BarShape(corner: 18, flare: 20, edge: .right).path(in: rect)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 21)),
                       "the inner corner must be rounded")
    }

    /// The left edge is a mirror: the same claims hold, flipped on x.
    func testLeftEdgeIsMirrored() {
        let path = BarShape(flare: 20, edge: .left).path(in: rect)
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 18)), "filled right against the left edge")
        XCTAssertFalse(path.contains(CGPoint(x: 40, y: 18)))
    }

    /// A very short window must not make the shape consume itself.
    func testDegenerateSizeDoesNotProduceAnEmptyOrInvertedPath() {
        for h in [CGFloat(8), 20, 41] {
            let small = CGRect(x: 0, y: 0, width: 54, height: h)
            let box = BarShape(corner: 18, flare: 20, edge: .right).path(in: small).boundingRect
            XCTAssertFalse(box.isEmpty, "h=\(h)")
            XCTAssertGreaterThan(box.width, 0, "h=\(h)")
            XCTAssertGreaterThan(box.height, 0, "h=\(h)")
        }
    }
}

// MARK: - Edge transforms (gate finding)

/// The canonical path hugs the right edge, and each edge is a transform of it.
/// The `.top` and `.bottom` transforms were swapped in the first version: a
/// top-docked bar flared away from the menu bar and pointed its rounded inner
/// corners at the bezel. Only `.right` was exercised, so nothing caught it.
extension BarShapeTests {
    /// A horizontal bar's rect is wide and short.
    private var horizontal: CGRect { CGRect(x: 0, y: 0, width: 260, height: 54) }

    /// Sampled **in the flare region at one end**, not in the middle: across the
    /// middle the body spans the whole cross-section, so both sides are filled
    /// there and the sample says nothing.
    private var inFlare: CGFloat { 20 * 0.9 }

    func testTopEdgePutsTheFlushSideAgainstTheTop() {
        let path = BarShape(corner: 18, flare: 20, edge: .top).path(in: horizontal)
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: inFlare, y: 2)),
                      "the flush side must sit against the top")
        XCTAssertFalse(path.contains(CGPoint(x: inFlare, y: horizontal.maxY - 2)),
                       "at the same point along the bar the inner side must be empty")
    }

    func testBottomEdgePutsTheFlushSideAgainstTheBottom() {
        let path = BarShape(corner: 18, flare: 20, edge: .bottom).path(in: horizontal)
        XCTAssertEqual(path.boundingRect.maxY, horizontal.maxY, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: inFlare, y: horizontal.maxY - 2)),
                      "the flush side must sit against the bottom")
        XCTAssertFalse(path.contains(CGPoint(x: inFlare, y: 2)),
                       "at the same point along the bar the inner side must be empty")
    }

    /// Every edge fills its whole rect, so the flare always reaches the bezel.
    func testEveryEdgeSpansItsRect() {
        for (edge, rect) in [(BarPanel.Edge.right, self.rect), (.left, self.rect),
                             (.top, horizontal), (.bottom, horizontal)] {
            let box = BarShape(corner: 18, flare: 20, edge: edge).path(in: rect).boundingRect
            XCTAssertEqual(box.width, rect.width, accuracy: 1, "\(edge)")
            XCTAssertEqual(box.height, rect.height, accuracy: 1, "\(edge)")
        }
    }

    /// `outline` drops the segment that lies on the screen edge: stroking the
    /// closed path drew a hairline on the screen's outermost pixel column.
    func testOutlineOmitsTheScreenEdgeSegment() {
        let filled = BarShape(edge: .right).path(in: rect)
        let outline = BarShape(edge: .right).outline.path(in: rect)
        XCTAssertFalse(outline.isEmpty)
        // The open path still traces the same silhouette…
        XCTAssertEqual(outline.boundingRect.maxX, filled.boundingRect.maxX, accuracy: 0.5)
        // …but it is not a closed region, so nothing inside it counts as filled.
        XCTAssertTrue(filled.contains(CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertFalse(BarShape(edge: .right, closed: false).closed)
    }
}
