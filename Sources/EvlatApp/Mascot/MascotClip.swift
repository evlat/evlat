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
        /// from the moment the step is entered — so it **includes** `motion`.
        /// A blink is a 0.08 s close with a 0.10 s hold, exactly as the old
        /// `asyncAfter(deadline: .now() + 0.10)` chain had it.
        var hold: Double
        /// Seconds of that hold the step spends **moving** — `curve`'s own
        /// duration. The rest is still.
        ///
        /// This is the measurement instrument's raw material (`plan.md` →
        /// Yaklaşım 6): frames are produced while a step travels and not while
        /// it waits, so `motion / hold` summed over a clip is the duty cycle
        /// that multiplies the in-clip cost. It is a stored field rather than
        /// something read back off `curve` because `Animation` does not expose
        /// its duration — which is why every step is built through one of the
        /// factories below, where the two are written once.
        var motion: Double

        /// A step on the shared phase-change curve. Used for step 0, the step a
        /// phase change travels through.
        static func entering(_ pose: MascotPose, hold: Double) -> Step {
            Step(pose: pose, curve: MascotPose.transition, hold: hold,
                 motion: MascotPose.transitionDuration)
        }

        /// A step inside a clip: eased in and out over `motion` seconds, then
        /// still until `hold` is up.
        static func eased(_ pose: MascotPose, over motion: Double, hold: Double) -> Step {
            Step(pose: pose, curve: .easeInOut(duration: motion), hold: hold, motion: motion)
        }
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
    /// `working` is the one phase with a choice to make: `003/phase-2` writes
    /// three candidates and the **user** picks (`plan.md` → R8). Every other
    /// phase walks the idle rhythm `phase-1` re-expressed; giving those their
    /// own motion is what `phase-3` is for.
    static func clip(for phase: Phase,
                     working: MascotWorking = MascotWorking.selected,
                     pacing: MascotPacing = MascotPacing.selected) -> MascotClip {
        let clip: MascotClip
        switch phase {
        case .working: clip = working.clip
        default: clip = idleRhythm(for: phase)
        }
        return pacing == .continuous ? clip.continuous : clip
    }

    /// Today's behaviour, as `phase-1` wrote it down: an occasional blink, a
    /// rarer breath, quiet in between.
    ///
    /// The rhythm is deterministic but the gaps are deliberately uneven — the
    /// old randomness was there to keep it from reading as a metronome, and
    /// uneven holds buy the same thing without giving up testability. Three
    /// blinks to one breath is the 7:3 coin flip the old 4 s timer used to make.
    static func idleRhythm(for phase: Phase) -> MascotClip {
        let rest = MascotPose.resting(for: phase)
        return MascotClip(steps: [
            // Entering the clip is entering the phase, so step 0 is the resting
            // pose on the shared transition curve. Whichever `.animation`
            // modifier claims a phase change, it gets the same one.
            .entering(rest, hold: 3.6),
            blink(rest), open(rest, hold: 4.4),
            blink(rest), open(rest, hold: 3.2),
            blink(rest), open(rest, hold: 4.8),
            // The breath: slow in, slower out.
            .eased(rest.scaled(by: 1.02), over: 1.1, hold: 1.15),
            // The exhale holds only as long as it takes to land, because
            // wrapping to step 0 — also rest — is where the next quiet gap
            // comes from. Giving both of them a gap would make the seam of the
            // loop twice as still as anywhere else in it.
            .eased(rest, over: 1.3, hold: 1.35)
        ], loops: true)
    }

    /// Eyes shut. The old `lidClosed` flag multiplied eye height by 0.08 from
    /// outside the pose; it is the same number, now written through the channel
    /// that owns eye height.
    static func blink(_ rest: MascotPose) -> Step {
        var closed = rest
        closed.eyeOpen = rest.eyeOpen * 0.08
        return .eased(closed, over: 0.08, hold: 0.10)
    }

    /// Back to rest after a blink.
    static func open(_ rest: MascotPose, hold: Double) -> Step {
        .eased(rest, over: 0.12, hold: hold)
    }

    // MARK: - Measurement (`plan.md` → Yaklaşım 6)

    /// Seconds one full pass through the clip takes.
    var cycle: Double { steps.reduce(0) { $0 + $1.hold } }

    /// Seconds of that pass spent moving.
    ///
    /// A step that lands on the pose it is already in produces **no frames**
    /// however long its curve is, so it does not count: that is exactly step 0
    /// of a looping clip, which re-enters the resting pose the last step already
    /// returned to. Getting this wrong would overstate every clip by a full
    /// transition.
    var movingTime: Double {
        guard let last = steps.last else { return 0 }
        var previous = loops ? last.pose : steps[0].pose
        var total = 0.0
        for step in steps {
            if step.pose != previous { total += step.motion }
            previous = step.pose
        }
        return total
    }

    /// The fraction of the cycle that produces frames.
    ///
    /// This is the multiplier `proje.md`'s canonical 90 s window hides: over a
    /// bursting clip that window reads *in-clip cost × duty cycle*, and
    /// stretching the window buys any number you like. Measure the in-clip cost
    /// with `continuous`, multiply by this, and the 90 s reading has something
    /// to be checked against.
    var dutyCycle: Double { cycle > 0 ? movingTime / cycle : 0 }

    /// The same motion with the waiting taken out: every step holds only as
    /// long as it moves, and the steps that go nowhere are dropped.
    ///
    /// Dropping them is not a shortcut, it is the point: a step that lands on
    /// the pose it is already in produces no frames, so leaving it in would put
    /// dead time back into the measurement — for `glance`, whose whole cycle is
    /// 1.14 s of motion, step 0 alone would be a third of the window measuring
    /// nothing. What comes out is a clip that is moving 100% of the time, which
    /// is what "in-clip cost" means.
    ///
    /// The in-clip leg of the measurement runs on this. It is not a mode to
    /// ship — a clip that never stops is the ~7% floor `001` measured — which
    /// is why it is reachable only through `EVLAT_MASCOT_PACING=continuous`.
    var continuous: MascotClip {
        guard let last = steps.last else { return self }
        var previous = loops ? last.pose : steps[0].pose
        var moving: [Step] = []
        for step in steps where step.pose != previous {
            var tight = step
            tight.hold = step.motion
            moving.append(tight)
            previous = step.pose
        }
        // A clip with no motion in it has nothing to measure; hand back what
        // was asked for rather than an empty clip the player would have to
        // defend itself against.
        return moving.isEmpty ? self : MascotClip(steps: moving, loops: true)
    }
}

extension MascotPose {
    /// Both scale axes together — a breath, not a squash.
    func scaled(by factor: Double) -> MascotPose {
        var p = self
        p.scaleX *= factor
        p.scaleY *= factor
        return p
    }

    /// Where the eyes are pointed, with the body left alone. A pose that aims
    /// somewhere only reaches the screen because `gazeMix` is below 1: at full
    /// mix the cursor overwrites it, which is the state `phase-1` ended.
    func aimed(yaw: Double, pitch: Double) -> MascotPose {
        var p = self
        p.yaw = yaw
        p.pitch = pitch
        return p
    }

    /// Stretch up and narrow, or squash down and widen: a body that moves
    /// without changing how much of the screen it covers.
    func bobbed(_ factor: Double) -> MascotPose {
        var p = self
        p.scaleY *= factor
        p.scaleX *= 1 / factor
        return p
    }
}

// MARK: - The `working` candidates

extension MascotWorking {
    /// This candidate's clip. **Three answers, no choice made** — `phase-2` is
    /// a user gate.
    ///
    /// All three obey the same rules: they burst rather than run (Karar 3a),
    /// they blink (a face that never blinks reads dead), they never animate
    /// `gazeMix` (Karar 4: the mix is a phase constant), and they end where
    /// they started so the loop's seam is not a jump.
    var clip: MascotClip {
        let rest = MascotPose.resting(for: .working, working: self)
        switch self {
        case .breath:  return MascotWorking.breathClip(rest)
        case .glance:  return MascotWorking.glanceClip(rest)
        case .busy:    return MascotWorking.busyClip(rest)
        }
    }

    /// **A — it breathes.** The signal is in the body and the face stays with
    /// you.
    ///
    /// Two breaths per cycle against `idle`'s one per 18.8 s, and they stretch
    /// rather than scale: taller and slightly narrower, which reads as drawing
    /// breath instead of growing. Told apart from `idle` by rate — so it is the
    /// candidate that asks the most of "without looking".
    private static func breathClip(_ rest: MascotPose) -> MascotClip {
        MascotClip(steps: [
            .entering(rest, hold: 1.6),
            .eased(rest.bobbed(1.045), over: 0.75, hold: 0.80),
            .eased(rest, over: 0.95, hold: 1.05),
            .eased(rest.bobbed(1.03), over: 0.70, hold: 0.75),
            .eased(rest, over: 0.90, hold: 3.40),
            MascotClip.blink(rest),
            MascotClip.open(rest, hold: 4.0)
        ], loops: true)
    }

    /// **B — it looks away.** The body is completely still; the eyes leave the
    /// cursor and work a small patch below the face.
    ///
    /// The one candidate readable **without looking at the mascot**: move the
    /// pointer and it no longer follows. The aims live in the pose's own
    /// `yaw`/`pitch`, the two of eight fields no phase could reach before
    /// `phase-1` made gaze additive — this clip is the reason that change was
    /// made. Holds are uneven on purpose; evenly spaced darts read as a
    /// mechanism.
    private static func glanceClip(_ rest: MascotPose) -> MascotClip {
        MascotClip(steps: [
            .entering(rest, hold: 1.2),
            .eased(rest.aimed(yaw: -0.35, pitch: 0.30), over: 0.10, hold: 1.5),
            .eased(rest.aimed(yaw: 0.30, pitch: 0.28), over: 0.12, hold: 0.9),
            // The blink keeps the aim it lands on, so the eyes open where they
            // closed rather than snapping back to centre mid-clip.
            MascotClip.blink(rest.aimed(yaw: 0.30, pitch: 0.28)),
            .eased(rest.aimed(yaw: -0.05, pitch: 0.35), over: 0.12, hold: 2.2),
            .eased(rest.aimed(yaw: -0.28, pitch: 0.32), over: 0.10, hold: 1.6),
            // Back to the resting aim: a clip that wrapped from a saccade would
            // put a jump at the seam, and a phase change out of `working` would
            // start from an aim no other phase knows about.
            .eased(rest, over: 0.22, hold: 2.4)
        ], loops: true)
    }

    /// **C — heads-down.** Both axes, each at lower amplitude than the
    /// candidate that owns it.
    ///
    /// The gaze is half released and settles **downward** — onto the work
    /// rather than away from you — and the body bobs once while it is down
    /// there, with one dart sideways before it comes back up.
    private static func busyClip(_ rest: MascotPose) -> MascotClip {
        let down = rest.aimed(yaw: -0.18, pitch: 0.30)
        return MascotClip(steps: [
            .entering(rest, hold: 1.1),
            .eased(down, over: 0.30, hold: 1.4),
            .eased(down.bobbed(0.985), over: 0.45, hold: 0.55),
            .eased(down.bobbed(1.025), over: 0.50, hold: 0.60),
            .eased(down, over: 0.50, hold: 1.5),
            .eased(rest.aimed(yaw: 0.22, pitch: 0.26), over: 0.10, hold: 1.3),
            MascotClip.blink(rest.aimed(yaw: 0.22, pitch: 0.26)),
            .eased(rest.aimed(yaw: 0.22, pitch: 0.26), over: 0.12, hold: 1.9),
            .eased(rest, over: 0.26, hold: 2.3)
        ], loops: true)
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
