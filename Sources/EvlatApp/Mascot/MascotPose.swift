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

    /// Phase → expression (ROADMAP → the state/expression table). This is the
    /// pose a phase **rests** at: `MascotClip` builds its steps on top of it and
    /// leaves every channel it does not drive sitting right here.
    ///
    /// The table aims straight ahead (`yaw`/`pitch` zero) and says through
    /// `gazeMix` how much of the cursor it wants on top of that.
    public static func resting(for phase: Phase) -> MascotPose {
        switch phase {
        case .idle:
            return MascotPose()
        case .working:
            // Focus: the eyes narrow a little, and the face gives up **most** of
            // the cursor — a working agent is looking at its own work, not at
            // you. The exact mix is nailed by eye in `003/phase-2`; this value
            // is provisional and only has to be visibly below `idle`'s.
            return MascotPose(eyeOpen: 0.92, eyeSquint: 0.34, gazeMix: 0.45)
        case .waiting:
            // Eyes WIDEN and the body leans out a touch toward the user. This
            // phase has exactly one job: be noticed — so it keeps the full gaze
            // and locks onto whoever it is waiting for.
            return MascotPose(eyeOpen: 1.28, scaleX: 1.03, scaleY: 1.04)
        case .review:
            // Head tilt plus a slight squint: "had a look — is this right?"
            return MascotPose(eyeOpen: 1.02, eyeSquint: 0.12, tilt: 9)
        case .failed:
            // Lids low, body squashed. The shudder is its own channel and lives
            // in `MascotShake`.
            return MascotPose(eyeOpen: 0.55, eyeSquint: 0.5, scaleX: 1.07, scaleY: 0.9)
        }
    }

    /// The transition spring. Kept in one place so every phase change feels the
    /// same.
    public static let transition: Animation = .spring(response: 0.38, dampingFraction: 0.72)
}
