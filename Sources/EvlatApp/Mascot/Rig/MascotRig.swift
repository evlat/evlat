import SwiftUI

/// What a character is made of and how a pose moves it: a tree of parts,
/// each moved by **bindings** from named controls.
///
/// The rig is the line between motion and drawing. A clip says what the
/// controls do (`MascotClip`, written in `MascotPose`'s fields); the rig says
/// which part each control moves and by how much. The same clip therefore
/// plays on every character, each the way its own parts allow — and a
/// character is a rig, not a view, so it can be read and checked as data
/// the way the clips are.
///
/// v0's motion layer had the same shape (`rig.json`: control → node property,
/// a two-point input range onto a two-point output range). What it does not
/// carry over is anything three-dimensional: no joints solved for contact,
/// no model file. Parts are shapes drawn by SwiftUI, and everything here is
/// linear, so SwiftUI's springs interpolating the drawn values land exactly
/// where interpolating the controls would.
struct MascotRig: Equatable {
    /// The part every other part hangs from. Its own bindings move the whole
    /// character.
    var root: MascotPart
    /// The character's **own** controls, beside the standard ones: what a
    /// clip may set them to, and where they rest when no clip does. Only the
    /// character's own clips write them; Evlat's clips do not know they exist.
    var controls: [MascotControl: MascotControl.Range] = [:]

    /// Every part, root first, each before its children: the order they are
    /// drawn in, back to front.
    var parts: [MascotPart] {
        var out: [MascotPart] = []
        func visit(_ part: MascotPart) {
            out.append(part)
            part.children.forEach(visit)
        }
        visit(root)
        return out
    }

    /// A control's value in a pose: a standard one is the pose's field, an
    /// own one what the pose set it to, else its rest. A name the rig never
    /// declared drives nothing — its bindings are left out, and
    /// `MascotCharacterContractTests` refuses the rig.
    func value(of control: MascotControl, in pose: MascotPose) -> Double? {
        if let value = pose.value(of: control) { return value }
        guard let range = controls[control] else { return nil }
        return pose.own[control] ?? range.rest
    }
}

/// A name a rig moves its parts by.
///
/// The **standard** controls are the pose's own fields — the vocabulary
/// Evlat's clips are written in. A character that binds them moves in every
/// phase without a clip of its own.
struct MascotControl: Hashable, CustomStringConvertible {
    let name: String

    init(_ name: String) { self.name = name }

    var description: String { name }

    static let yaw = MascotControl("yaw")
    static let pitch = MascotControl("pitch")
    static let eyeOpen = MascotControl("eyeOpen")
    static let eyeSquint = MascotControl("eyeSquint")
    static let scaleX = MascotControl("scaleX")
    static let scaleY = MascotControl("scaleY")
    static let tilt = MascotControl("tilt")

    /// `gazeMix` is not among them: it moves no part. It says how much of the
    /// cursor is blended into `yaw` and `pitch` before a rig ever reads them.
    static let standard: [MascotControl] = [.yaw, .pitch, .eyeOpen, .eyeSquint, .scaleX, .scaleY, .tilt]

    /// An own control's declaration (`MascotRig.controls`).
    struct Range: Equatable {
        var lower: Double
        var upper: Double
        var rest: Double

        init(_ lower: Double, _ upper: Double, rest: Double) {
            self.lower = lower
            self.upper = upper
            self.rest = rest
        }

        func contains(_ value: Double) -> Bool { lower <= value && value <= upper }
    }
}

extension MascotPose {
    /// The pose with one of the character's own controls set.
    func setting(_ control: MascotControl, to value: Double) -> MascotPose {
        var p = self
        p.own[control] = value
        return p
    }

    /// A standard control's value; `nil` for any other name.
    func value(of control: MascotControl) -> Double? {
        switch control {
        case .yaw: return yaw
        case .pitch: return pitch
        case .eyeOpen: return eyeOpen
        case .eyeSquint: return eyeSquint
        case .scaleX: return scaleX
        case .scaleY: return scaleY
        case .tilt: return tilt
        default: return nil
        }
    }
}

/// One piece of a character, and what moves it.
///
/// Positions and sizes are fractions of the mascot's side, measured from its
/// centre with y pointing down, so one rig draws at any size — the bar's 34 pt
/// and the setup's 18 pt alike.
struct MascotPart: Equatable {
    /// Unique within the rig. SwiftUI tells parts apart by it, so a pose
    /// change animates a part rather than replacing it.
    var name: String
    /// What it draws; `nil` for a group that only carries its children.
    var shape: MascotShape?
    var fill: Color = .clear
    /// Where the shape sits at rest.
    var center: CGPoint = .zero
    /// The shape's size at rest.
    var size = CGSize(width: 1, height: 1)
    /// The point the part scales and turns about.
    var pivot: CGPoint = .zero
    var bindings: [MascotBinding] = []
    /// Drawn over this part's shape, and moved, scaled and turned with it.
    var children: [MascotPart] = []

    /// The part's properties in a pose: every binding's output, added or
    /// multiplied as its property says.
    func resolved(in pose: MascotPose, rig: MascotRig) -> Resolved {
        var out = Resolved()
        for binding in bindings {
            guard let value = rig.value(of: binding.control, in: pose) else { continue }
            out.apply(binding.property, binding.output(for: value))
        }
        return out
    }

    /// What the bindings make of a part in one pose.
    struct Resolved: Equatable {
        var offsetX = 0.0, offsetY = 0.0
        var width = 1.0, height = 1.0
        var scaleX = 1.0, scaleY = 1.0
        var rotation = 0.0
        var opacity = 1.0

        mutating func apply(_ property: MascotProperty, _ value: Double) {
            switch property {
            case .offsetX: offsetX += value
            case .offsetY: offsetY += value
            case .width: width *= value
            case .height: height *= value
            case .scaleX: scaleX *= value
            case .scaleY: scaleY *= value
            case .rotation: rotation += value
            case .opacity: opacity *= value
            }
        }
    }
}

/// What a binding moves. Positions and angles **add**, sizes, scales and
/// opacity **multiply**, so several controls can move one property — an
/// eye's height opens with `eyeOpen` and closes with `eyeSquint` — without
/// any of them knowing about the others.
enum MascotProperty: CaseIterable {
    /// The whole part, children included, in fractions of the side.
    case offsetX, offsetY
    /// The part's own shape, as a share of its resting size.
    case width, height
    /// The whole part about its pivot.
    case scaleX, scaleY
    /// The whole part about its pivot, in degrees.
    case rotation
    case opacity
}

/// A control moving a property: `input` maps onto `output`, linearly.
///
/// Values outside `input` are **clamped** to it. That is what makes a binding
/// one-sided: an eye that narrows only as the face turns away from it binds
/// `yaw` over `0…1` and is left alone at every negative value. v0 refused an
/// out-of-range value instead; a mascot that stops drawing is a worse answer
/// than one held at its limit.
struct MascotBinding: Equatable {
    var control: MascotControl
    var property: MascotProperty
    var input: MascotSpan
    var output: MascotSpan

    init(_ control: MascotControl, _ property: MascotProperty,
         from input: (Double, Double), to output: (Double, Double)) {
        self.control = control
        self.property = property
        self.input = MascotSpan(input.0, input.1)
        self.output = MascotSpan(output.0, output.1)
    }

    /// The control passed through unchanged over `range` — a body that
    /// scales and tilts exactly as the pose says.
    static func follows(_ control: MascotControl, _ property: MascotProperty,
                        over range: (Double, Double)) -> MascotBinding {
        MascotBinding(control, property, from: range, to: range)
    }

    func output(for value: Double) -> Double {
        let low = min(input.start, input.end), high = max(input.start, input.end)
        let t = (min(max(value, low), high) - input.start) / (input.end - input.start)
        return output.start + t * (output.end - output.start)
    }
}

/// Two points of a binding's line. The output may run downhill — an eye
/// narrows as `yaw` grows — so it is a pair, not a range.
struct MascotSpan: Equatable {
    var start: Double
    var end: Double

    init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }
}

/// What a part draws.
enum MascotShape: Equatable {
    /// The corner radius is a fraction of the mascot's side, not of the
    /// shape, so a part that grows keeps its corners.
    case roundedRectangle(cornerRadius: Double)
    /// Never flatter than `minimumHeight` times its width: shut, an eye is a
    /// slit rather than nothing.
    case capsule(minimumHeight: Double)
    /// A closed outline through `points`, each a fraction of the part's own
    /// frame (`0…1`, y down), every corner rounded by `cornerRadius` — a
    /// fraction of the mascot's side, as the rectangle's is. An ear, a hem,
    /// anything a rectangle and a capsule cannot draw.
    case polygon(points: [CGPoint], cornerRadius: Double)
    /// One cell of a picture sheet, fitted into the part's frame: the cell
    /// `control` names, rounded, row by row from the top left — the first
    /// with no control, a picture that is only drawn. Clips move it with
    /// cuts (`MascotClip.Step.cut`), never a curve — a frame is there or it
    /// is not, and a cell half-way between two is a third one.
    case cells(MascotSheet, by: MascotControl?)
}
