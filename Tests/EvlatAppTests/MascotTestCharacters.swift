import SwiftUI
import EvlatCore
@testable import EvlatApp

/// Characters that exist only for the tests: each one uses the parts of the
/// contract the shipped characters do not yet, so the contract is held by
/// something that exercises it.
enum MascotTestCharacters {
    static let glow = MascotControl("bulb.glow")
    static let sway = MascotControl("antenna.sway")

    /// A round body with an antenna whose bulb glows. Its own controls move
    /// the antenna and the bulb; it plays `waiting` its own way (the bulb
    /// lights up, the antenna stands still) and keeps one gesture of its own.
    static let lantern = MascotCharacter(
        id: "test-lantern",
        rig: MascotRig(
            root: MascotPart(
                name: "lantern",
                bindings: [
                    .follows(.scaleX, .scaleX, over: (0, 2)),
                    .follows(.scaleY, .scaleY, over: (0, 2)),
                    .follows(.tilt, .rotation, over: (-180, 180))
                ],
                children: [
                    MascotPart(name: "stem", shape: .capsule(minimumHeight: 1), fill: .gray,
                               center: CGPoint(x: 0, y: -0.5), size: CGSize(width: 0.06, height: 0.2),
                               pivot: CGPoint(x: 0, y: -0.4),
                               bindings: [MascotBinding(sway, .rotation, from: (-1, 1), to: (-20, 20))],
                               children: [
                                   MascotPart(name: "bulb", shape: .capsule(minimumHeight: 1), fill: .yellow,
                                              center: CGPoint(x: 0, y: -0.62),
                                              size: CGSize(width: 0.14, height: 0.14),
                                              bindings: [MascotBinding(glow, .opacity, from: (0, 1), to: (0.2, 1))])
                               ]),
                    MascotPart(name: "body", shape: .roundedRectangle(cornerRadius: 0.45), fill: .white,
                               size: CGSize(width: 0.9, height: 0.9)),
                    eye(side: -1),
                    eye(side: 1)
                ]),
            controls: [
                glow: MascotControl.Range(0, 1, rest: 0.3),
                sway: MascotControl.Range(-1, 1, rest: 0)
            ]),
        states: [.waiting: waiting],
        motions: ["flicker": flicker]
    )

    static func eye(side: Double) -> MascotPart {
        MascotPart(name: side < 0 ? "leftEye" : "rightEye", shape: .capsule(minimumHeight: 0.4), fill: .black,
                   center: CGPoint(x: side * 0.16, y: 0), size: CGSize(width: 0.12, height: 0.24),
                   bindings: [
                       MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-0.08, 0.08)),
                       MascotBinding(.pitch, .offsetY, from: (-1, 1), to: (-0.06, 0.06)),
                       .follows(.eyeOpen, .height, over: (0, 2))
                   ])
    }

    /// Lit, and still: the bulb says it, not the eyes.
    static let waiting: MascotClip = {
        let rest = MascotPose(eyeOpen: 1.1).setting(glow, to: 1)
        return MascotClip(steps: [
            .entering(rest, hold: 0.6),
            .eased(rest.setting(glow, to: 0.5), over: 0.15, hold: 0.3),
            .eased(rest, over: 0.15, hold: 0.4)
        ], loops: false)
    }()

    static let flicker: MascotClip = {
        let at = MascotPose.resting(for: .working)
        return MascotClip(steps: [
            .eased(at.setting(glow, to: 1).setting(sway, to: 0.6), over: 0.12, hold: 0.2),
            .eased(at.setting(glow, to: 0.1).setting(sway, to: -0.6), over: 0.12, hold: 0.2),
            .eased(at, over: 0.2, hold: 0.25)
        ], loops: false)
    }()
}
