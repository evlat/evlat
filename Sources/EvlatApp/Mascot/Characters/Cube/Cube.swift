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
    static let character = MascotCharacter(id: "cube", rig: rig)

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

    /// One eye; `side` is −1 for the left, 1 for the right. The eyes used to
    /// sit in a row 0.16 apart, laid out by their drawn widths.
    static func eye(side: Double) -> MascotPart {
        .eye(side: side, width: 0.13, height: 0.30, gap: 0.16, gaze: (0.11, 0.08),
             fill: Color.black.opacity(0.92))
    }
}
