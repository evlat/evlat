import SwiftUI

/// Puf: a ghost that floats on a breath and sinks on a failure.
///
/// It plays Evlat's own clips, and turns what they do to the body into
/// height: a ghost does not stretch, it rises. Half of the squash is kept as
/// squash; growing taller — the idle breath, `waiting`'s swell, a file
/// caught — lifts it, and squashing — `failed` — lets it sink.
///
/// Its own gesture is a hop of joy when work is done: once the finish has
/// arrived it rises, sways twice and settles back, wide-eyed. Once per
/// finish; the green ring keeps saying it after.
enum Puf {
    static let character = MascotCharacter(id: "puf", rig: rig, motions: ["hop": hop], behavior: behavior)

    static let behavior = MascotBehavior(rules: [
        MascotRule(phase: .review, play: [.init("hop")])
    ])

    /// Up, a sway either side of the finish's own tilt, down: written in
    /// the standard controls alone — a taller ghost is a higher one.
    static let hop: MascotClip = {
        let rest = MascotPose.resting(for: .review)
        var up = rest
        up.scaleY = 1.05
        up.eyeOpen = 1.15
        up.eyeSquint = 0
        var left = up
        left.tilt = rest.tilt - 7
        left.scaleY = 1.035
        var right = up
        right.tilt = rest.tilt + 6
        return MascotClip(steps: [
            .eased(up, over: 0.22, hold: 0.24),
            .eased(left, over: 0.16, hold: 0.18),
            .eased(right, over: 0.16, hold: 0.18),
            .eased(rest, over: 0.30, hold: 0.34)
        ], loops: false)
    }()

    static let white = Color(white: 0.92)

    static let rig = MascotRig(root: MascotPart(
        name: "puf",
        bindings: [
            MascotBinding(.scaleX, .scaleX, from: (0.8, 1.2), to: (0.9, 1.1)),
            MascotBinding(.scaleY, .scaleY, from: (0.8, 1.2), to: (0.9, 1.1)),
            MascotBinding(.scaleY, .offsetY, from: (1.0, 1.05), to: (0, -0.08)),
            MascotBinding(.scaleY, .offsetY, from: (0.85, 1.0), to: (0.07, 0)),
            .follows(.tilt, .rotation, over: (-180, 180))
        ],
        children: [
            // Three pieces, one white: a round top, straight sides, a hem.
            MascotPart(name: "dome", shape: .roundedRectangle(cornerRadius: 0.42), fill: white,
                       center: CGPoint(x: 0, y: -0.06), size: CGSize(width: 0.84, height: 0.84)),
            MascotPart(name: "body", shape: .roundedRectangle(cornerRadius: 0), fill: white,
                       center: CGPoint(x: 0, y: 0.12), size: CGSize(width: 0.84, height: 0.4)),
            MascotPart(name: "hem",
                       shape: .polygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5),
                                                CGPoint(x: 0.833, y: 1), CGPoint(x: 0.667, y: 0.45),
                                                CGPoint(x: 0.5, y: 1), CGPoint(x: 0.333, y: 0.45),
                                                CGPoint(x: 0.167, y: 1), CGPoint(x: 0, y: 0.5)],
                                       cornerRadius: 0.02),
                       fill: white, center: CGPoint(x: 0, y: 0.38), size: CGSize(width: 0.84, height: 0.2)),
            .eye(side: -1, y: -0.06, width: 0.11, height: 0.25, gap: 0.15, gaze: (0.10, 0.07),
                 fill: Color.black.opacity(0.92)),
            .eye(side: 1, y: -0.06, width: 0.11, height: 0.25, gap: 0.15, gaze: (0.10, 0.07),
                 fill: Color.black.opacity(0.92))
        ]
    ))
}
