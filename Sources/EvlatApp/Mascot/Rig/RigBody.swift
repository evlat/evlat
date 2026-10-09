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
            // One `Image` whose picture changes, never a view swapped for
            // another: a swap inside the step's animation would fade one
            // frame into the next.
            Group {
                if let image = cell.flatMap(sheet.cell) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: size * width, height: size * height)
        }
    }
}

extension MascotShape {
    /// The cell a `.cells` shape draws in `pose`: its control's value read
    /// from the pose the step names — never one a spring is passing
    /// through, so an overshoot cannot show a neighbouring frame.
    func cell(in pose: MascotPose, rig: MascotRig) -> Int? {
        guard case .cells(_, let control) = self, let value = rig.value(of: control, in: pose) else { return nil }
        return Int(value.rounded())
    }
}

/// `MascotShape.polygon`'s outline: each corner an arc tangent to its two
/// edges, so the outline stays smooth however few points it has.
struct RoundedPolygon: Shape {
    let points: [CGPoint]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let at = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        guard at.count > 2, let first = at.first, let last = at.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for (i, corner) in at.enumerated() {
            path.addArc(tangent1End: corner, tangent2End: at[(i + 1) % at.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}
