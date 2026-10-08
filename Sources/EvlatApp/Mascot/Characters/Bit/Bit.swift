import SwiftUI

/// Bit: a robot with its face on a screen — the app icon's dark square and
/// light eyes, worn as a head.
///
/// It plays Evlat's own clips. The antenna is bound to the standard
/// controls: it leans further than the head tilts, swings against the gaze
/// and droops to one side when the eyes squint on a failure. Its bulb burns
/// low until the eyes open well past rest — bright while it waits on you or
/// catches a file, and nowhere else. A white bulb, not a colour: the rings
/// keep the colours.
enum Bit {
    static let character = MascotCharacter(id: "bit", rig: rig)

    static let white = Color(white: 0.92)
    static let screen = Color.black.opacity(0.92)

    static let rig = MascotRig(root: MascotPart(
        name: "bit",
        bindings: [
            .follows(.scaleX, .scaleX, over: (0, 2)),
            .follows(.scaleY, .scaleY, over: (0, 2)),
            .follows(.tilt, .rotation, over: (-180, 180))
        ],
        children: [
            MascotPart(name: "stem", shape: .capsule(minimumHeight: 1), fill: white,
                       center: CGPoint(x: 0, y: -0.36), size: CGSize(width: 0.06, height: 0.2),
                       pivot: CGPoint(x: 0, y: -0.27),
                       bindings: [
                           MascotBinding(.tilt, .rotation, from: (-20, 20), to: (-22, 22)),
                           MascotBinding(.yaw, .rotation, from: (-1, 1), to: (10, -10)),
                           MascotBinding(.eyeSquint, .rotation, from: (0.2, 0.5), to: (0, 38))
                       ],
                       children: [
                           MascotPart(name: "bulb", shape: .capsule(minimumHeight: 1), fill: .white,
                                      center: CGPoint(x: 0, y: -0.47), size: CGSize(width: 0.14, height: 0.14),
                                      bindings: [MascotBinding(.eyeOpen, .opacity, from: (1.1, 1.28), to: (0.4, 1))])
                       ]),
            MascotPart(name: "head", shape: .roundedRectangle(cornerRadius: 0.2), fill: white,
                       center: CGPoint(x: 0, y: 0.12), size: CGSize(width: 0.98, height: 0.76)),
            MascotPart(name: "screen", shape: .roundedRectangle(cornerRadius: 0.13), fill: screen,
                       center: CGPoint(x: 0, y: 0.12), size: CGSize(width: 0.74, height: 0.52)),
            // The eyes stay on the screen: they travel less than the cube's.
            .eye(side: -1, y: 0.12, width: 0.11, height: 0.25, gap: 0.14, gaze: (0.08, 0.05), fill: white),
            .eye(side: 1, y: 0.12, width: 0.11, height: 0.25, gap: 0.14, gaze: (0.08, 0.05), fill: white)
        ]
    ))
}
