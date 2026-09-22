import SwiftUI

/// The bar's body: docked to an edge, flaring **outward** at both ends.
///
/// The detail that matters is the inverse rounding at the ends (*flare*). A
/// plain rounded rectangle reads as something **stuck onto** the screen; here
/// the body widens as it approaches the edge and ends tangent to the bezel, so
/// it reads as part of the screen itself. macOS's hardware notch and
/// codenotch's `SideNotchShape` use the same trick.
///
/// The vertical extent at the edge is `2 × flare` **longer** than the body:
/// the shape opens up toward the bezel.
///
/// ```
///        ┃  ← screen edge
///     ╭──┚     top flare: inverse curve from body to edge
///     │  ┃
///     │  ┃  ← body, flush with the edge
///     │  ┃
///     ╰──┒     bottom flare
///        ┃
/// ```
public struct BarShape: Shape {
    /// Corner radius of the inner corners (the side away from the edge).
    public var corner: CGFloat
    /// Radius of the inverse curve at the ends. The body gets **shorter** by
    /// this much and the reach at the edge gets **longer** by the same.
    public var flare: CGFloat
    /// Which edge it docks to. The path is drawn for the right edge; the
    /// others are transforms of it.
    public var edge: BarPanel.Edge
    /// Whether the segment that runs **along the screen edge** is part of the
    /// path.
    ///
    /// Filling needs it; stroking must not have it. `closeSubpath()` draws a
    /// straight line back along x == w, and stroking that puts a hairline on the
    /// screen's outermost pixel column — exactly the seam the border is meant to
    /// avoid. `BarShape.outline` is the open variant for `.stroke`.
    public var closed: Bool

    public init(corner: CGFloat = 20, flare: CGFloat = 14,
                edge: BarPanel.Edge = .right, closed: Bool = true) {
        self.corner = corner
        self.flare = flare
        self.edge = edge
        self.closed = closed
    }

    /// The same outline without the segment that lies on the screen edge.
    /// Stroke this, fill `self`.
    public var outline: BarShape {
        BarShape(corner: corner, flare: flare, edge: edge, closed: false)
    }

    public func path(in rect: CGRect) -> Path {
        let path = canonicalPath(in: CGRect(origin: .zero, size: canonicalSize(of: rect)))
        return path.applying(transform(for: rect))
    }

    /// Width and height swap on horizontal edges: the canonical path is always
    /// drawn as if docked right.
    private func canonicalSize(of rect: CGRect) -> CGSize {
        switch edge {
        case .right, .left: return rect.size
        case .top, .bottom: return CGSize(width: rect.height, height: rect.width)
        }
    }

    private func transform(for rect: CGRect) -> CGAffineTransform {
        switch edge {
        case .right:
            return .identity
        case .left:
            // mirror on x
            return CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -rect.width, y: 0)
        // The canonical path hugs x == w, so the transform has to land that side
        // on the docked edge. These two were swapped in the first version: a
        // top-docked bar flared away from the menu bar and pointed its rounded
        // inner corners at the bezel. Solved on paper and pinned by
        // BarShapeTests — `.top` must map canonical x == w to y' == 0.
        case .top:
            // translate then rotate −90°: y' = w − x, so the edge side lands on top.
            return CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: -rect.height, y: 0)
        case .bottom:
            // translate then rotate +90°: y' = x, so the edge side lands at the bottom.
            return CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -rect.width)
        }
    }

    /// The canonical right-edge path. The filled region hugs the right; `w` is
    /// the screen edge.
    private func canonicalPath(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // The flare eats into the body; clamp so a very short window does not
        // make the shape consume itself.
        let f = min(flare, h / 2)
        let c = min(corner, (h - 2 * f) / 2, w)
        let top = f            // top edge of the body
        let bottom = h - f     // bottom edge of the body

        var p = Path()
        // At the edge, the top of the upper flare.
        p.move(to: CGPoint(x: w, y: 0))
        // Inverse curve: from the edge down to the body's top.
        //
        // The control point sits on the corner **toward the edge**, (w, top).
        // The first version put it on the other corner (w-f, 0) and the curve
        // bent the wrong way: the flare came out convex and looked like a second
        // rounded blob glued to the bar (caught on a screenshot). With the edge
        // corner as control the curve wraps the edge and the gap is carved
        // INWARD — that is what makes it read as growing out of the bezel.
        p.addQuadCurve(to: CGPoint(x: w - f, y: top),
                       control: CGPoint(x: w, y: top))
        // Body's top edge, up to the inner corner.
        p.addLine(to: CGPoint(x: c, y: top))
        // Inner corners are ordinary (convex) rounding.
        p.addQuadCurve(to: CGPoint(x: 0, y: top + c), control: CGPoint(x: 0, y: top))
        p.addLine(to: CGPoint(x: 0, y: bottom - c))
        p.addQuadCurve(to: CGPoint(x: c, y: bottom), control: CGPoint(x: 0, y: bottom))
        // Body's bottom edge and the lower flare.
        p.addLine(to: CGPoint(x: w - f, y: bottom))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w, y: bottom))
        if closed { p.closeSubpath() }
        return p
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(corner, flare) }
        set { corner = newValue.first; flare = newValue.second }
    }
}
