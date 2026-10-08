import SwiftUI

extension MascotPart {
    /// Evlat's eye: a capsule bound to the standard controls the way the
    /// cube's is, so every character that wears it blinks, squints, widens
    /// and looks in the one language the clips are written for. A character
    /// changes where it sits and how big it is, never what it does.
    ///
    /// - `side`: −1 for the left eye, 1 for the right.
    /// - `y`, `width`, `height`, `gap`: at rest, in fractions of the side;
    ///   `gap` is the space between the two eyes.
    /// - `gaze`: how far the eye travels at a full look, across and down.
    ///
    /// A face is flat, so instead of a sphere's angle mapping the eye uses
    /// **perspective narrowing**: as the face turns, the far eye gets thinner
    /// and the near one slides in behind it — close to a cosine, but nearly
    /// linear. A squint closes the eye from above: the lid comes down, the eye
    /// does not drift upward. Shut, an eye is a slit, not nothing.
    static func eye(side: Double, y: Double = 0, width: Double, height: Double, gap: Double,
                    gaze: (x: Double, y: Double), fill: Color) -> MascotPart {
        let narrowing = 0.42
        let thin = 1 - narrowing
        let slide = width * narrowing / 2
        return MascotPart(
            name: side < 0 ? "leftEye" : "rightEye",
            shape: .capsule(minimumHeight: 0.35),
            fill: fill,
            center: CGPoint(x: side * (width + gap) / 2, y: y),
            size: CGSize(width: width, height: height),
            bindings: [
                MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-gaze.x, gaze.x)),
                MascotBinding(.pitch, .offsetY, from: (-1, 1), to: (-gaze.y, gaze.y)),
                MascotBinding(.yaw, .width, from: side > 0 ? (0, 1) : (-1, 0), to: side > 0 ? (1, thin) : (thin, 1)),
                MascotBinding(.yaw, .offsetX, from: side > 0 ? (-1, 0) : (0, 1),
                              to: side > 0 ? (-slide, 0) : (0, slide)),
                .follows(.eyeOpen, .height, over: (0, 2)),
                MascotBinding(.eyeSquint, .height, from: (0, 1), to: (1, 0.45)),
                MascotBinding(.eyeSquint, .offsetY, from: (0, 1), to: (0, 0.04))
            ])
    }
}
