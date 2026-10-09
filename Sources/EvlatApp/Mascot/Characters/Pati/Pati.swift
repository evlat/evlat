import SwiftUI

/// Pati: a cat whose ears say what its eyes say — round-faced, with pink
/// inside its ears, a small pink nose and whiskers.
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
    /// The nose and the inside of the ears. Anatomy, never a signal: the
    /// rings keep the bar's colours.
    static let pink = Color(red: 0.96, green: 0.70, blue: 0.74)

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
            // Round, a little wider than tall: a cat's face, not a box's.
            MascotPart(name: "head", shape: .roundedRectangle(cornerRadius: 0.38), fill: white,
                       center: CGPoint(x: 0, y: 0.1), size: CGSize(width: 1.0, height: 0.8)),
            .eye(side: -1, y: 0.10, width: 0.12, height: 0.27, gap: 0.20, gaze: (0.10, 0.06),
                 fill: Color.black.opacity(0.92)),
            .eye(side: 1, y: 0.10, width: 0.12, height: 0.27, gap: 0.20, gaze: (0.10, 0.06),
                 fill: Color.black.opacity(0.92)),
            // On the front of the face, the nose and whiskers follow the
            // gaze less than the eyes and more than the head.
            MascotPart(name: "nose",
                       shape: .polygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)],
                                       cornerRadius: 0.02),
                       fill: pink, center: CGPoint(x: 0, y: 0.31), size: CGSize(width: 0.13, height: 0.085),
                       bindings: [MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-0.07, 0.07)),
                                  MascotBinding(.pitch, .offsetY, from: (-1, 1), to: (-0.04, 0.04))]),
            whisker(side: -1, rising: true), whisker(side: -1, rising: false),
            whisker(side: 1, rising: true), whisker(side: 1, rising: false)
        ]
    ), controls: [twitchControl: MascotControl.Range(-1, 1, rest: 0)])

    /// One ear, turning about its base on top of the head; `side` is −1 for
    /// the left. Its pink inside turns with it.
    static func ear(side s: Double) -> MascotPart {
        let outer: [CGPoint] = s < 0
            ? [CGPoint(x: 0.02, y: 1), CGPoint(x: 0.16, y: 0), CGPoint(x: 0.98, y: 0.78), CGPoint(x: 1, y: 1)]
            : [CGPoint(x: 0, y: 1), CGPoint(x: 0.02, y: 0.78), CGPoint(x: 0.84, y: 0), CGPoint(x: 0.98, y: 1)]
        let inner: [CGPoint] = s < 0
            ? [CGPoint(x: 0.12, y: 1), CGPoint(x: 0.22, y: 0), CGPoint(x: 0.88, y: 0.92)]
            : [CGPoint(x: 0.12, y: 0.92), CGPoint(x: 0.78, y: 0), CGPoint(x: 0.88, y: 1)]
        return MascotPart(
            name: s < 0 ? "leftEar" : "rightEar",
            shape: .polygon(points: outer, cornerRadius: 0.045),
            fill: white,
            center: CGPoint(x: s * 0.255, y: -0.30),
            size: CGSize(width: 0.40, height: 0.40),
            pivot: CGPoint(x: s * 0.24, y: -0.13),
            bindings: [
                MascotBinding(.eyeOpen, .rotation, from: (1.0, 1.4), to: (0, -s * 12)),
                MascotBinding(.eyeOpen, .offsetY, from: (1.0, 1.4), to: (0, -0.05)),
                MascotBinding(.eyeSquint, .rotation, from: (0.15, 0.5), to: (0, s * 30)),
                MascotBinding(.eyeSquint, .offsetY, from: (0.15, 0.5), to: (0, 0.05)),
                MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (0.03, -0.03))
            ] + (s > 0 ? [MascotBinding(twitchControl, .rotation, from: (-1, 1), to: (-22, 22))] : []),
            children: [
                MascotPart(name: s < 0 ? "leftEarInside" : "rightEarInside",
                           shape: .polygon(points: inner, cornerRadius: 0.03), fill: pink,
                           center: CGPoint(x: s * 0.267, y: -0.275), size: CGSize(width: 0.22, height: 0.24))
            ])
    }

    /// A thin sliver from the cheek outward, one rising and one falling on
    /// each side — read at 34 pt as whiskers, not as lines.
    static func whisker(side s: Double, rising: Bool) -> MascotPart {
        let near: Double = s < 0 ? 1 : 0, far: Double = s < 0 ? 0 : 1
        let from = rising ? 0.75 : 0.15, to = rising ? 0.15 : 0.82
        return MascotPart(
            name: (s < 0 ? "left" : "right") + (rising ? "WhiskerUp" : "WhiskerDown"),
            shape: .polygon(points: [CGPoint(x: near, y: from), CGPoint(x: far, y: to),
                                     CGPoint(x: far, y: to + 0.18), CGPoint(x: near, y: min(1, from + 0.22))],
                            cornerRadius: 0.004),
            fill: white,
            center: CGPoint(x: s * 0.5, y: rising ? 0.30 : 0.35),
            size: CGSize(width: 0.26, height: 0.12),
            bindings: [MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-0.04, 0.04))])
    }
}
