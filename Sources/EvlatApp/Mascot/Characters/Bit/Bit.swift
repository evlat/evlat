import SwiftUI
import EvlatCore

/// Bit: a robot with its face on a lit screen — the app icon's dark square
/// and light eyes, worn as a head, on a metal back with a bolt each side.
///
/// It plays Evlat's own clips. The antenna is bound to the standard
/// controls: it leans further than the head tilts, swings against the gaze
/// and droops to one side when the eyes squint on a failure. Its bulb burns
/// low until the eyes open well past rest — bright while it waits on you or
/// catches a file, and nowhere else.
///
/// Its eyes wear the bar's colours: amber while it waits on you, green
/// when work is done, red when it failed — the rings' own (`SessionIndicator.
/// color`), read from there, so the mascot speaks the language the rows
/// do and never one of its own. Ice white otherwise. The colour is held for
/// the whole phase and crosses on the phase change's spring; it is never
/// the only sign — the eyes' shape and the clips still tell the phases
/// apart.
///
/// Its own gesture is the bulb blinking twice while it waits on you: once
/// half a minute in, once more at two minutes if the wait goes on. A wait
/// it has already said stays still between, as `waiting` does.
enum Bit {
    static let character = MascotCharacter(id: "bit", rig: rig, states: states, motions: ["blink": blink],
                                           behavior: behavior)

    /// How far the bulb is put out, apart from how bright the eyes make it.
    static let dimControl = MascotControl("bulb.dim")

    /// A phase whose colour the eyes take, and the control that shows it.
    struct Tint {
        let phase: Phase
        let control: MascotControl
    }

    static let tints = [Phase.waiting, .review, .failed].map {
        Tint(phase: $0, control: MascotControl("eyes." + $0.rawValue))
    }

    /// Evlat's clips, each phase that has a colour holding it throughout.
    static let states: [Phase: MascotClip] = Dictionary(uniqueKeysWithValues: tints.map {
        ($0.phase, MascotClip.clip(for: $0.phase, pacing: .normal).setting($0.control, to: 1))
    })

    static let behavior = MascotBehavior(rules: [
        MascotRule(phase: .waiting, after: 30, play: [.init("blink")]),
        MascotRule(phase: .waiting, after: 120, play: [.init("blink")])
    ])

    /// Off, on, off, on — the eyes still amber.
    static let blink: MascotClip = {
        let rest = states[.waiting]?.steps.last?.pose ?? MascotPose.resting(for: .waiting)
        return MascotClip(steps: [
            .eased(rest.setting(dimControl, to: 1), over: 0.06, hold: 0.16),
            .eased(rest, over: 0.06, hold: 0.16),
            .eased(rest.setting(dimControl, to: 1), over: 0.06, hold: 0.16),
            .eased(rest, over: 0.08, hold: 0.2)
        ], loops: false)
    }()

    static let white = Color(white: 0.92)
    /// The back plate, the bolts and the antenna's mount.
    static let metal = Color(white: 0.58)
    /// Lit, not off: the darkest blue, so it reads as a screen and not a hole.
    static let screen = Color(red: 0.05, green: 0.08, blue: 0.13)
    /// The eyes when no phase gives them a colour: white with the screen's
    /// light in it.
    static let ice = Color(red: 0.86, green: 0.95, blue: 1.0)

    /// The head's centre, a little above the mascot's: the back plate shows
    /// under it.
    static let face = 0.10

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
                                      bindings: [
                                          MascotBinding(.eyeOpen, .opacity, from: (1.1, 1.28), to: (0.4, 1)),
                                          MascotBinding(dimControl, .opacity, from: (0, 1), to: (1, 0.12))
                                      ])
                       ]),
            bolt(side: -1),
            bolt(side: 1),
            MascotPart(name: "mount", shape: .roundedRectangle(cornerRadius: 0.03), fill: metal,
                       center: CGPoint(x: 0, y: -0.285), size: CGSize(width: 0.2, height: 0.08)),
            MascotPart(name: "plate", shape: .roundedRectangle(cornerRadius: 0.2), fill: metal,
                       center: CGPoint(x: 0, y: face + 0.045), size: CGSize(width: 0.98, height: 0.76)),
            MascotPart(name: "head", shape: .roundedRectangle(cornerRadius: 0.2), fill: white,
                       center: CGPoint(x: 0, y: face), size: CGSize(width: 0.98, height: 0.76)),
            MascotPart(name: "screen", shape: .roundedRectangle(cornerRadius: 0.13), fill: screen,
                       center: CGPoint(x: 0, y: face), size: CGSize(width: 0.76, height: 0.54)),
            // A light on the glass, top left: a screen, not a painted panel.
            MascotPart(name: "glare",
                       shape: .polygon(points: [CGPoint(x: 0.3, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
                                                CGPoint(x: 0, y: 0.45)], cornerRadius: 0.01),
                       fill: Color.white.opacity(0.13), center: CGPoint(x: -0.24, y: face - 0.16),
                       size: CGSize(width: 0.2, height: 0.14))
        ] + eyes
    ), controls: Dictionary(uniqueKeysWithValues: [(dimControl, MascotControl.Range(0, 1, rest: 0))]
        + tints.map { ($0.control, MascotControl.Range(0, 1, rest: 0)) }))

    /// A bolt on the side of the head, behind it: it slides against the
    /// gaze, as the far side of a turning head would.
    static func bolt(side: Double) -> MascotPart {
        MascotPart(name: side < 0 ? "leftBolt" : "rightBolt", shape: .roundedRectangle(cornerRadius: 0.035),
                   fill: metal, center: CGPoint(x: side * 0.52, y: face), size: CGSize(width: 0.08, height: 0.28),
                   bindings: [MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (0.025, -0.025))])
    }

    /// The eyes stay on the screen: they travel less than the cube's. Each
    /// is drawn ice white, then once more in every phase's colour, shown as
    /// far as that phase's control says — so a colour crosses on the spring
    /// as the eyes do.
    static let eyes: [MascotPart] = [-1.0, 1].flatMap { side -> [MascotPart] in
        let eye = MascotPart.eye(side: side, y: face, width: 0.11, height: 0.25, gap: 0.15, gaze: (0.08, 0.05),
                                 fill: ice)
        return [eye] + tints.map { tint in
            var worn = eye
            worn.name = eye.name + "." + tint.phase.rawValue
            worn.fill = SessionIndicator.color(tint.phase)
            worn.bindings.append(MascotBinding(tint.control, .opacity, from: (0, 1), to: (0, 1)))
            return worn
        }
    }
}
