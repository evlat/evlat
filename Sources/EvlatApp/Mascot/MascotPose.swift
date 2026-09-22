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

    public init(yaw: Double = 0, pitch: Double = 0, eyeOpen: Double = 1,
                eyeSquint: Double = 0, scaleX: Double = 1, scaleY: Double = 1,
                tilt: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.eyeOpen = eyeOpen
        self.eyeSquint = eyeSquint
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.tilt = tilt
    }

    /// Phase → expression (ROADMAP → the state/expression table). Gaze is not
    /// part of this table: it comes from the cursor and rides on top of every
    /// phase.
    public static func resting(for phase: Phase) -> MascotPose {
        switch phase {
        case .idle:
            return MascotPose()
        case .working:
            // Focus: the eyes narrow a little. `MascotView` adds the rhythmic bob.
            return MascotPose(eyeOpen: 0.92, eyeSquint: 0.34)
        case .waiting:
            // Eyes WIDEN and the body leans out a touch toward the user. This
            // phase has exactly one job: be noticed.
            return MascotPose(eyeOpen: 1.28, scaleX: 1.03, scaleY: 1.04)
        case .review:
            // Head tilt plus a slight squint: "had a look — is this right?"
            return MascotPose(eyeOpen: 1.02, eyeSquint: 0.12, tilt: 9)
        case .failed:
            // Lids low, body squashed. The shake comes from `KeyframeAnimator`.
            return MascotPose(eyeOpen: 0.55, eyeSquint: 0.5, scaleX: 1.07, scaleY: 0.9)
        }
    }

    /// The transition spring. Kept in one place so every phase change feels the
    /// same.
    public static let transition: Animation = .spring(response: 0.38, dampingFraction: 0.72)
}
