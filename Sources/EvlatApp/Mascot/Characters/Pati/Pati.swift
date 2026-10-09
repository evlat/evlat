import SwiftUI

/// Pati: a cat whose ears say what its eyes say.
///
/// It plays Evlat's own clips and writes none of its own: the ears are bound
/// to the eyes' standard controls. Eyes opened wide — `waiting`, a file
/// caught — prick them up and in; a squint lays them back, a little while
/// it works and flat when something failed. A blink leaves them where they
/// are: the opening only reaches them above its resting 1. Behind the head,
/// they move against the gaze.
///
/// Its own gesture is an ear twitch while it waits on you: the pricked right
/// ear flicks twice, the way a cat's does at a sound — once 45 seconds into
/// the wait, once more at three minutes if it goes on.
enum Pati {
    static let character = MascotCharacter(id: "pati", rig: rig, motions: ["twitch": twitch],
                                           behavior: behavior)

    /// The right ear's flick, apart from what the eyes do to both.
    static let twitchControl = MascotControl("ear.twitch")

    static let behavior = MascotBehavior(rules: [
        MascotRule(phase: .waiting, after: 45, play: [.init("twitch")]),
        MascotRule(phase: .waiting, after: 180, play: [.init("twitch")])
    ])

    /// Out, back past rest, out a little less, home: 0.3 s of motion.
    static let twitch: MascotClip = {
        let rest = MascotPose.resting(for: .waiting)
        return MascotClip(steps: [
            .eased(rest.setting(twitchControl, to: 1), over: 0.07, hold: 0.09),
            .eased(rest.setting(twitchControl, to: -0.6), over: 0.07, hold: 0.09),
            .eased(rest.setting(twitchControl, to: 0.8), over: 0.06, hold: 0.08),
            .eased(rest, over: 0.10, hold: 0.14)
        ], loops: false)
    }()

    static let white = Color(white: 0.92)

    static let rig = MascotRig(root: MascotPart(
        name: "pati",
        bindings: [
            .follows(.scaleX, .scaleX, over: (0, 2)),
            .follows(.scaleY, .scaleY, over: (0, 2)),
            .follows(.tilt, .rotation, over: (-180, 180))
        ],
        children: [
            ear(side: -1),
            ear(side: 1),
            MascotPart(name: "head", shape: .roundedRectangle(cornerRadius: 0.36), fill: white,
                       center: CGPoint(x: 0, y: 0.11), size: CGSize(width: 0.96, height: 0.78)),
            .eye(side: -1, y: 0.13, width: 0.12, height: 0.26, gap: 0.17, gaze: (0.10, 0.07),
                 fill: Color.black.opacity(0.92)),
            .eye(side: 1, y: 0.13, width: 0.12, height: 0.26, gap: 0.17, gaze: (0.10, 0.07),
                 fill: Color.black.opacity(0.92))
        ]
    ), controls: [twitchControl: MascotControl.Range(-1, 1, rest: 0)])

    /// One ear, turning about its base; `side` is −1 for the left.
    static func ear(side s: Double) -> MascotPart {
        MascotPart(
            name: s < 0 ? "leftEar" : "rightEar",
            shape: .polygon(points: s < 0
                            ? [CGPoint(x: 0, y: 1), CGPoint(x: 0.18, y: 0), CGPoint(x: 1, y: 0.92)]
                            : [CGPoint(x: 0, y: 0.92), CGPoint(x: 0.82, y: 0), CGPoint(x: 1, y: 1)],
                            cornerRadius: 0.05),
            fill: white,
            center: CGPoint(x: s * 0.27, y: -0.30),
            size: CGSize(width: 0.36, height: 0.34),
            pivot: CGPoint(x: s * 0.27, y: -0.16),
            bindings: [
                MascotBinding(.eyeOpen, .rotation, from: (1.0, 1.4), to: (0, -s * 12)),
                MascotBinding(.eyeOpen, .offsetY, from: (1.0, 1.4), to: (0, -0.05)),
                MascotBinding(.eyeSquint, .rotation, from: (0.15, 0.5), to: (0, s * 30)),
                MascotBinding(.eyeSquint, .offsetY, from: (0.15, 0.5), to: (0, 0.05)),
                MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (0.03, -0.03))
            ] + (s > 0 ? [MascotBinding(twitchControl, .rotation, from: (-1, 1), to: (-22, 22))] : []))
    }
}
