import SwiftUI
import EvlatCore

/// The whole mascot reduces to a handful of **animatable numbers**.
///
/// We write no physics loop: transitions go through `withAnimation(.spring(...))`
/// and SwiftUI's spring, when interrupted, continues from its current **position
/// and velocity**. v1's "a state change never snaps" principle comes free from
/// that — it is the hardest part to get right in a hand-rolled spring.
public struct MascotPose: Equatable {
    /// Gaze, horizontal. −1 left, +1 right.
    public var yaw: Double
    /// Gaze, vertical. −1 up, +1 down.
    public var pitch: Double
    /// Eye opening. 1 normal, 0 closed, above 1 widened.
    public var eyeOpen: Double
    /// Focus squint: a lid coming down over the eye.
    public var eyeSquint: Double
    /// Squash / stretch.
    public var scaleX: Double
    public var scaleY: Double
    /// Head tilt, degrees.
    public var tilt: Double
    /// How much of the cursor the eyes take, 0…1. See `blending(gaze:)`.
    ///
    /// The eighth field, and the only one a phase sets about *gaze* rather than
    /// about its own face. It exists because gaze used to be imposed
    /// unconditionally — `yaw`/`pitch` were the two of seven fields no phase
    /// could reach. Constant per phase, so its home is `resting(for:)`.
    public var gazeMix: Double
    /// The character's own controls (`MascotRig.controls`), by name. Empty in
    /// every pose Evlat's clips build: only a character's own clips set them,
    /// and one left out rests where the rig says.
    var own: [MascotControl: Double] = [:]

    public init(yaw: Double = 0, pitch: Double = 0, eyeOpen: Double = 1,
                eyeSquint: Double = 0, scaleX: Double = 1, scaleY: Double = 1,
                tilt: Double = 0, gazeMix: Double = 1) {
        self.yaw = yaw
        self.pitch = pitch
        self.eyeOpen = eyeOpen
        self.eyeSquint = eyeSquint
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.tilt = tilt
        self.gazeMix = gazeMix
    }

    /// Gaze **blended in**, not written over the pose.
    ///
    /// The old rule was one line — `p.yaw = gaze.width` — and it erased whatever
    /// the pose asked for, which is why nothing could ever look away. The rule
    /// that replaces it is a lerp towards the cursor by `gazeMix`: a pose with
    /// `gazeMix: 0` keeps its own aim and receives no gaze at all, one with
    /// `gazeMix: 1` follows the cursor exactly as before. Everything between is
    /// a face that is *partly* somewhere else — which is what `working` needs.
    public func blending(gaze: CGSize) -> MascotPose {
        var p = self
        p.yaw += (gaze.width - p.yaw) * gazeMix
        p.pitch += (gaze.height - p.pitch) * gazeMix
        return p
    }

    /// Phase → expression (`AGENTS.md` → Architecture). This is the
    /// pose a phase **rests** at: `MascotClip` builds its steps on top of it and
    /// leaves every channel it does not drive sitting right here.
    ///
    /// The table aims straight ahead (`yaw`/`pitch` zero) and says through
    /// `gazeMix` how much of the cursor it wants on top of that. The mixes are
    /// nailed per phase and their **order** is the contract,
    /// held by `MascotPoseTests`: `waiting` takes all of it, `working` the least
    /// of anyone, `idle` in between. Idle gives up a little so that the lock
    /// `waiting` makes is a change you can see, not the same stare as before.
    public static func resting(for phase: Phase) -> MascotPose {
        switch phase {
        case .idle:
            // Mostly with you, not locked on. Asleep as well as awake: the
            // sleeping branch draws this pose.
            return MascotPose(gazeMix: 0.85)
        case .working:
            // Focus: the eyes narrow a little, and the face gives up most of the
            // cursor — a working agent is looking at its own work, not at you.
            // 0.30 was nailed by eye when the user picked the
            // `busy` clip out of three: half-released, the gaze settles down
            // onto the work rather than away from you.
            return MascotPose(eyeOpen: 0.92, eyeSquint: 0.34, gazeMix: 0.30)
        case .waiting:
            // Eyes WIDEN and the body leans out a touch toward the user. This
            // phase has exactly one job: be noticed — so it keeps the full gaze
            // and locks onto whoever it is waiting for.
            return MascotPose(eyeOpen: 1.28, scaleX: 1.03, scaleY: 1.04)
        case .review:
            // A slight squint, upright: content with the work. Turned toward
            // you but not locked on. The head tilt — "had a look — is this
            // right?" — is asked once, in `review`'s clip, and not held: a
            // tilt kept until the finish was seen read as stuck. The green
            // ring keeps telling the finish.
            return MascotPose(eyeOpen: 1.02, eyeSquint: 0.12, gazeMix: 0.60)
        case .failed:
            // Lids low, body squashed. The shudder is its own channel and lives
            // in `MascotShake`. Half of the cursor: it still knows you are
            // there, it just cannot quite meet your eye.
            return MascotPose(eyeOpen: 0.55, eyeSquint: 0.5, scaleX: 1.07, scaleY: 0.9,
                              gazeMix: 0.45)
        }
    }

    /// A file on its way to the bar. **Not a
    /// phase**: nothing aggregates to it and the table above does not know
    /// it; the drop target raises it while a drag is over the bar and drops
    /// it when the drag leaves or lands.
    ///
    /// Built from the fields every phase already has, because the face is
    /// the eyes (there is no mouth): they open wider than `waiting` opens
    /// them — otherwise catching would read as one more "I need you" — the
    /// body reaches up a little, taller rather than bigger, and the gaze is
    /// the file's entirely.
    public static let catching = MascotPose(eyeOpen: 1.42, scaleX: 0.97, scaleY: 1.06, gazeMix: 1)

    /// What the body draws: `pose`, or — while a file is caught — the
    /// catching face turned to `catching`, the drag's direction. One rule
    /// for every branch of `MascotView`, so the face changes on the body
    /// already on screen and the spring carries it.
    public static func drawn(_ pose: MascotPose, catching gaze: CGSize?) -> MascotPose {
        gaze.map { Self.catching.blending(gaze: $0) } ?? pose
    }

    /// The transition spring. Kept in one place so every phase change feels the
    /// same.
    ///
    /// The question was whether a cube reads better with this or with an
    /// exponential ease-out; seen side by side, the user
    /// kept the spring — interruptible, velocity-preserving, "never snaps" for
    /// free.
    public static let transition: Animation = .spring(response: 0.38, dampingFraction: 0.72)

    /// How long a transition takes to land, seconds: the spring's response
    /// plus a little of its overshoot. `MascotClip` counts it as the motion of
    /// every step that travels on `transition`, for the duty cycle.
    public static let transitionDuration: Double = 0.40
}
