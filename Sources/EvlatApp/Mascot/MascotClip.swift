import SwiftUI
import EvlatCore

/// A clip is **data**, not an engine: a list of poses to walk through, in the
/// same static-function shape as `MascotPose.resting(for:)` — and that shape is
/// the whole reason it can be tested at all.
///
/// There is no `Decodable`, no registry, no loading from outside. v1's motion
/// layer was 1202 lines because motion was **pet-pack data** and the engine had
/// no vocabulary of its own; v2 has no pets, so the generality has no customer.
///
/// Interpolation stays SwiftUI's job (`.animation(step.curve, value: step)`) and
/// timing is a single `@State step` walking this array — see `ClipPlayer` in
/// `MascotView`.
///
/// **The clip owns the channels it drives.** Every step is built on top of
/// `resting(for:)`, so a channel a clip never touches keeps its resting value
/// for the clip's whole length, and nothing else in the view writes to it. That
/// replaces the old arrangement, where scale had two writers (`pose.scaleX` and
/// a separate breathing `scaleEffect`) and eye height had three, with the
/// multiplication order written down nowhere.
struct MascotClip: Equatable {
    /// One step: where to be, how to get there, and how long to stay.
    struct Step: Equatable {
        /// The pose this step settles on. Built from `resting(for:)` so the
        /// untouched channels stay at rest.
        var pose: MascotPose
        /// How to travel **into** this pose. SwiftUI interpolates; we only say
        /// which curve.
        var curve: Animation
        /// Seconds to remain on this step before the next one starts, measured
        /// from the moment the step is entered — so it **includes** `curve`'s
        /// own duration. A blink is a 0.08 s close with a 0.10 s hold, exactly
        /// as the old `asyncAfter(deadline: .now() + 0.10)` chain had it.
        var hold: Double
    }

    /// Walked in order.
    var steps: [Step]
    /// Whether the last step wraps back to the first. `false` means the clip
    /// plays once and **holds its final pose** — v1 defaulted this to `true`,
    /// and that default is the one thing from v1's clip layer we are not
    /// taking: a loop that never stops is the ~7% CPU floor measured in `001`.
    var loops: Bool

    /// Phase → motion, the sibling of `MascotPose.resting(for:)`.
    ///
    /// `003/phase-1` re-expresses **today's** behaviour and nothing more: an
    /// occasional blink, a rarer breath, quiet in between. What changes is that
    /// the rhythm is now data instead of two `asyncAfter` chains rolled by a
    /// coin flip on a 4 s timer, so it can be read and tested. The rhythm is
    /// deterministic but the gaps are deliberately uneven — the old randomness
    /// was there to keep it from reading as a metronome, and uneven holds buy
    /// the same thing without giving up testability.
    ///
    /// Every phase shares this idle rhythm today; giving each phase its own
    /// motion is what the rest of `003` is for.
    static func clip(for phase: Phase) -> MascotClip {
        let rest = MascotPose.resting(for: phase)
        return MascotClip(steps: [
            // Entering the clip is entering the phase, so step 0 is the resting
            // pose on the shared transition spring. Whichever `.animation`
            // modifier claims a phase change, it gets the same curve.
            Step(pose: rest, curve: MascotPose.transition, hold: 3.6),
            blink(rest), open(rest, hold: 4.4),
            blink(rest), open(rest, hold: 3.2),
            blink(rest), open(rest, hold: 4.8),
            // The breath: slow in, slower out. Three blinks to one breath, the
            // 7:3 coin flip the timer used to make.
            Step(pose: rest.scaled(by: 1.02), curve: .easeInOut(duration: 1.1), hold: 1.15),
            // The exhale holds only as long as it takes to land, because
            // wrapping to step 0 — also rest — is where the next quiet gap
            // comes from. Giving both of them a gap would make the seam of the
            // loop twice as still as anywhere else in it.
            Step(pose: rest, curve: .easeInOut(duration: 1.3), hold: 1.35)
        ], loops: true)
    }

    /// Eyes shut. The old `lidClosed` flag multiplied eye height by 0.08 from
    /// outside the pose; it is the same number, now written through the channel
    /// that owns eye height.
    private static func blink(_ rest: MascotPose) -> Step {
        var closed = rest
        closed.eyeOpen = rest.eyeOpen * 0.08
        return Step(pose: closed, curve: .easeInOut(duration: 0.08), hold: 0.10)
    }

    /// Back to rest after a blink.
    private static func open(_ rest: MascotPose, hold: Double) -> Step {
        Step(pose: rest, curve: .easeInOut(duration: 0.12), hold: hold)
    }
}

private extension MascotPose {
    /// Both scale axes together — a breath, not a squash.
    func scaled(by factor: Double) -> MascotPose {
        var p = self
        p.scaleX *= factor
        p.scaleY *= factor
        return p
    }
}

/// The `failed` shudder: one damped shake along x.
///
/// It stays out of `MascotPose` because it is not a pose the mascot can rest in
/// — it is a transient fired by *arriving* at `failed`, which is what SwiftUI's
/// `keyframeAnimator(trigger:)` is for. What it is not allowed to stay is
/// invisible to the tests: before `003`, `grep -rn "shake\|keyframe" Tests/`
/// returned nothing, so "the behaviour is preserved" had no guard at all.
struct MascotShake: Equatable {
    struct Key: Equatable {
        /// Horizontal offset, points.
        var offset: Double
        /// Seconds to reach it.
        var duration: Double
    }

    var keys: [Key]

    /// Peak displacement. Zero in every phase but `failed`: the same clip runs
    /// on every trigger change and the amplitude is what makes it a shudder or
    /// nothing at all.
    static let amplitude: Double = 3.5

    /// Phase → shudder. Four keys, always: out, back past centre, a smaller
    /// bounce, then still.
    static func shake(for phase: Phase) -> MascotShake {
        let a = phase == .failed ? amplitude : 0
        return MascotShake(keys: [
            Key(offset: a, duration: 0.05),
            Key(offset: -a, duration: 0.07),
            Key(offset: a * 0.5, duration: 0.07),
            Key(offset: 0, duration: 0.12)
        ])
    }
}
