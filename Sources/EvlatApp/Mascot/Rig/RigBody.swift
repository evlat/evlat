import SwiftUI

/// Draws a rig in a pose. Decides nothing: what the controls are is the
/// pose's, what they move is the rig's.
///
/// Every part is a layer the size of the mascot, centred on it, so a part's
/// pivot is a point of that square and a child moves with its parent for
/// free. The modifiers are in one fixed order — the shape framed and placed,
/// then the layer scaled, turned and shifted — because SwiftUI interpolates
/// each modifier's value on its own: the order is what decides the frames
/// in the middle of a spring.
struct RigBody: View {
    let rig: MascotRig
    let pose: MascotPose
    let size: CGFloat

    var body: some View {
        RigLayer(part: rig.root, rig: rig, pose: pose, size: size)
    }
}

private struct RigLayer: View {
    let part: MascotPart
    let rig: MascotRig
    let pose: MascotPose
    let size: CGFloat

    var body: some View {
        let r = part.resolved(in: pose, rig: rig)
        let anchor = UnitPoint(x: 0.5 + part.pivot.x, y: 0.5 + part.pivot.y)
        return ZStack {
            if let shape = part.shape {
                RigShape(shape: shape, fill: part.fill, size: size,
                         width: part.size.width * r.width, height: part.size.height * r.height,
                         cell: shape.cell(in: pose, rig: rig))
                    .offset(x: part.center.x * size, y: part.center.y * size)
            }
            ForEach(part.children, id: \.name) { child in
                RigLayer(part: child, rig: rig, pose: pose, size: size)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: r.scaleX, y: r.scaleY, anchor: anchor)
        .rotationEffect(.degrees(r.rotation), anchor: anchor)
        .offset(x: r.offsetX * size, y: r.offsetY * size)
        .opacity(r.opacity)
    }
}

/// One shape at its drawn size, in fractions of the side.
private struct RigShape: View {
    let shape: MascotShape
    let fill: Color
    let size: CGFloat
    let width: Double
    let height: Double
    /// The cell a `.cells` shape draws.
    let cell: Int?

    var body: some View {
        switch shape {
        case .roundedRectangle(let corner):
            RoundedRectangle(cornerRadius: size * corner, style: .continuous)
                .fill(fill)
                .frame(width: size * width, height: size * height)
        case .capsule(let minimumHeight):
            Capsule(style: .continuous)
                .fill(fill)
                .frame(width: size * width, height: size * max(width * minimumHeight, height))
        case .polygon(let points, let corner):
            RoundedPolygon(points: points, radius: size * corner)
                .fill(fill)
                .frame(width: size * width, height: size * height)
        case .cells(let sheet, _):
            // A frame is there or it is not. Changed inside the step's
            // animation, the picture would fade from one cell into the next
            // — seen: a half-transparent bird between two frames — so the
            // change carries no animation. Scale above it still springs.
            Group {
                if let image = cell.flatMap(sheet.cell) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: size * width, height: size * height)
            .transaction { $0.animation = nil }
        }
    }
}

extension MascotShape {
    /// The cell a `.cells` shape draws in `pose`: its control's value read
    /// from the pose the step names — never one a spring is passing
    /// through, so an overshoot cannot show a neighbouring frame.
    func cell(in pose: MascotPose, rig: MascotRig) -> Int? {
        guard case .cells(_, let control) = self else { return nil }
        guard let control else { return 0 }
        return rig.value(of: control, in: pose).map { Int($0.rounded()) }
    }
}

/// `MascotShape.polygon`'s outline: each corner an arc tangent to its two
/// edges, so the outline stays smooth however few points it has.
///
/// A corner's arc is never wider than its edges allow: where the radius
/// would reach past half the shorter edge, it shrinks to fit. A sharp
/// corner squeezed thin — a pointed eye shutting in a blink — otherwise
/// threw its tangent far outside the shape, a line across the bar (seen).
struct RoundedPolygon: Shape {
    let points: [CGPoint]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let at = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        guard at.count > 2, let first = at.first, let last = at.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for (i, corner) in at.enumerated() {
            let before = at[(i + at.count - 1) % at.count], after = at[(i + 1) % at.count]
            path.addArc(tangent1End: corner, tangent2End: after,
                        radius: Self.radius(radius, at: corner, between: before, and: after))
        }
        path.closeSubpath()
        return path
    }

    /// The largest radius up to `radius` whose arc touches each edge within
    /// its first half — the arc's tangent lies `r / tan(θ/2)` from the
    /// corner, θ the corner's angle.
    static func radius(_ radius: CGFloat, at corner: CGPoint, between a: CGPoint, and b: CGPoint) -> CGFloat {
        let u = CGPoint(x: a.x - corner.x, y: a.y - corner.y), v = CGPoint(x: b.x - corner.x, y: b.y - corner.y)
        let lu = (u.x * u.x + u.y * u.y).squareRoot(), lv = (v.x * v.x + v.y * v.y).squareRoot()
        guard lu > 0, lv > 0 else { return 0 }
        let cosine = max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv)))
        let half = acos(cosine) / 2
        guard half > 1e-6 else { return 0 }
        return min(radius, min(lu, lv) / 2 * tan(half))
    }
}
