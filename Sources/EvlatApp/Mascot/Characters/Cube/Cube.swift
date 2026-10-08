import SwiftUI

/// The cube: Evlat's first character, and the face the app's icon wears.
///
/// The form is a **cube** — an edged body reads with more character than a
/// sphere when it turns, and it also moves away from the reference.
/// Expression lives in the **eyes**, not the body. It binds only standard
/// controls and plays Evlat's own clips as they are.
///
/// Every number below is the one the cube was drawn with before it was a rig;
/// `RigTests` holds the drawing to those formulas.
enum Cube {
    static let rig = MascotRig(root: MascotPart(
        name: "cube",
        bindings: [
            .follows(.scaleX, .scaleX, over: (0, 2)),
            .follows(.scaleY, .scaleY, over: (0, 2)),
            .follows(.tilt, .rotation, over: (-180, 180))
        ],
        // The eyes are children of the body: when it tilts they go with it.
        // In a space of their own they would read as two dots stuck on a box.
        children: [
            MascotPart(name: "face", shape: .roundedRectangle(cornerRadius: 0.3),
                       fill: Color.white.opacity(0.92)),
            eye(side: -1),
            eye(side: 1)
        ]
    ))

    /// Eye width and the gap between the eyes, at rest.
    static let eyeWidth = 0.13
    static let eyeGap = 0.16
    /// How much thinner the far eye gets as the face turns all the way.
    static let narrowing = 0.42

    /// One eye; `side` is −1 for the left, 1 for the right.
    ///
    /// A cube's face is flat, so instead of a sphere's angle mapping the eye
    /// uses **perspective narrowing**: as the face turns, the far eye gets
    /// thinner. Close to a cosine, but nearly linear, which suits a cube.
    static func eye(side: Double) -> MascotPart {
        let thin = 1 - narrowing
        // The eyes used to sit in a row laid out by their drawn widths, so
        // the near eye slid inward by half of what the far eye lost. The
        // row is gone; the slide is written down instead.
        let slide = eyeWidth * narrowing / 2
        let away: (Double, Double) = side > 0 ? (0, 1) : (-1, 0)
        return MascotPart(
            name: side < 0 ? "leftEye" : "rightEye",
            shape: .capsule(minimumHeight: 0.35),
            fill: Color.black.opacity(0.92),
            center: CGPoint(x: side * (eyeWidth + eyeGap) / 2, y: 0),
            size: CGSize(width: eyeWidth, height: 0.30),
            bindings: [
                MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-0.11, 0.11)),
                MascotBinding(.pitch, .offsetY, from: (-1, 1), to: (-0.08, 0.08)),
                // The far eye narrows; the near one slides in behind it.
                MascotBinding(.yaw, .width, from: away, to: side > 0 ? (1, thin) : (thin, 1)),
                MascotBinding(.yaw, .offsetX, from: side > 0 ? (-1, 0) : (0, 1),
                              to: side > 0 ? (-slide, 0) : (0, slide)),
                .follows(.eyeOpen, .height, over: (0, 2)),
                // A squint closes the eye from above: the lid comes down, the
                // eye does not drift upward.
                MascotBinding(.eyeSquint, .height, from: (0, 1), to: (1, 0.45)),
                MascotBinding(.eyeSquint, .offsetY, from: (0, 1), to: (0, 0.04))
            ]
        )
    }
}
