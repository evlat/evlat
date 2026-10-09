import SwiftUI
import EvlatCore

/// A clip is **data**, not an engine: a list of poses to walk through, in the
/// same static-function shape as `MascotPose.resting(for:)` — and that shape is
/// the whole reason it can be tested at all.
///
/// These are **Evlat's** clips: the default every character plays in a phase
/// it does not play its own way (`MascotCharacter.states`). They are written
/// in the standard controls only, so they move any rig that binds them.
///
/// There is no `Decodable` and no loading from outside, for the clips or for
/// the characters. v1's motion layer was 1202 lines because motion was
/// **pet-pack data** read from files and the engine had no vocabulary of its
/// own; here the vocabulary is the pose, characters are code, and the
/// compiler and `MascotCharacterContractTests` check a character before it
/// is ever drawn.
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
        /// This is the measurement instrument's raw material (`AGENTS.md` →
        /// Measuring): frames are produced while a step travels and not while
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

        /// A step that changes frame rather than moving: one drawn frame,
        /// then still until `hold` is up — a picture sheet's next cell
        /// (`MascotShape.cells`).
        ///
        /// Its `motion` is that one frame, so the duty cycle counts a cut as
        /// the frame it costs. That is the arithmetic, not the measurement:
        /// cost also tracks how often the step index changes, and a sheet's
        /// burst changes it every frame — for a sheet, the gate is its
        /// measured 90 s leg (`MascotContract.maxDutyCycle`).
        static func cut(_ pose: MascotPose, hold: Double) -> Step {
            Step(pose: pose, curve: .linear(duration: cutMotion), hold: hold, motion: cutMotion)
        }

        /// One frame at 60 Hz.
        static let cutMotion = 1.0 / 60
    }

    /// Walked in order.
    var steps: [Step]
    /// Whether the last step wraps back to the first. `false` means the clip
    /// plays once and **holds its final pose** — v1 defaulted this to `true`,
    /// and that default is the one thing from v1's clip layer we are not
    /// taking: a loop that never stops is the measured ~7% CPU floor.
    var loops: Bool

    /// Phase → motion, the sibling of `MascotPose.resting(for:)`.
    ///
    /// Every phase has its own clip, and **whether it loops is
    /// part of what it says**: `idle`, `working` and `failed` are states you sit
    /// in, so they keep a sparse rhythm going; `waiting` and `review` are news,
    /// so they play once and hold. Peripheral vision catches a change, not a
    /// state — a face that stops moving after it arrives is the arrival.
    static func clip(for phase: Phase,
                     pacing: MascotPacing = MascotPacing.selected) -> MascotClip {
        let clip: MascotClip
        switch phase {
        case .idle: clip = idle()
        case .working: clip = working()
        case .waiting: clip = waiting()
        case .review: clip = review()
        case .failed: clip = failed()
        }
        return pacing == .continuous ? clip.continuous : clip
    }

    /// The step after `index`, or `nil` when the clip has played out.
    ///
    /// This is the one decision the player makes about a clip, pulled out here
    /// so that "a one-shot clip stops and holds" is a claim the tests can hold
    /// rather than a branch inside a view. `nil` means: stay on the last pose
    /// and schedule nothing — no pending step, no frames.
    func step(after index: Int) -> Int? {
        let next = index + 1
        if next < steps.count { return next }
        return loops && !steps.isEmpty ? 0 : nil
    }

    /// **`idle`**: the long-standing behaviour — an
    /// occasional blink, a rarer breath, quiet in between. It stays the sparsest
    /// loop in the table (duty cycle 0.16) because it is the one that runs for
    /// hours.
    ///
    /// The rhythm is deterministic but the gaps are deliberately uneven — the
    /// old randomness was there to keep it from reading as a metronome, and
    /// uneven holds buy the same thing without giving up testability. Three
    /// blinks to one breath is the 7:3 coin flip the old 4 s timer used to make.
    static func idle() -> MascotClip {
        let rest = MascotPose.resting(for: .idle)
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

    // MARK: - Measurement (`AGENTS.md` → Measuring)

    /// Seconds one full pass through the clip takes.
    var cycle: Double { steps.reduce(0) { $0 + $1.hold } }

    /// Seconds of that pass spent moving.
    ///
    /// A step that lands on the pose it is already in produces **no frames**
    /// however long its curve is, so it does not count: that is exactly step 0
    /// of a looping clip, which re-enters the resting pose the last step already
    /// returned to. Getting this wrong would overstate every clip by a full
    /// transition.
    ///
    /// A one-shot clip has no such pass: it is only ever played on the way
    /// *into* its phase, from some other phase's pose, so its step 0 is a real
    /// transition and counts.
    var movingTime: Double {
        var previous = entryPose
        var total = 0.0
        for step in steps {
            if step.pose != previous { total += step.motion }
            previous = step.pose
        }
        return total
    }

    /// The pose step 0 is entered from, when the clip itself decides it: a loop
    /// re-enters from its own last step. A one-shot clip is entered from another
    /// phase — a pose it cannot know — so `nil`, and step 0 always moves.
    private var entryPose: MascotPose? { loops ? steps.last?.pose : nil }

    /// The fraction of the cycle that produces frames.
    ///
    /// This is the multiplier the canonical 90 s window hides: over a
    /// bursting clip that window reads *in-clip cost × duty cycle*, and
    /// stretching the window buys any number you like. Measure the in-clip cost
    /// with `continuous`, multiply by this, and the 90 s reading has something
    /// to be checked against.
    ///
    /// **Only for a loop.** A one-shot clip (`waiting`, `review`) plays once and
    /// then produces no frames at all, so its steady state is zero and there is
    /// no cycle to take a fraction of: its cost over a window is *in-clip cost ×
    /// `movingTime` / window*, and it is `nil` here so nobody multiplies it the
    /// other way.
    var dutyCycle: Double? {
        guard loops else { return nil }
        return cycle > 0 ? movingTime / cycle : 0
    }

    /// The same motion with the waiting taken out: every step holds only as
    /// long as it moves, and the steps that go nowhere are dropped.
    ///
    /// Dropping them is not a shortcut, it is the point: a step that lands on
    /// the pose it is already in produces no frames, so leaving it in would put
    /// dead time back into the measurement — for a clip of short eye darts,
    /// step 0's 0.40 s alone can be a third of the window measuring nothing.
    /// What comes out is a clip that is moving 100% of the time, which is what
    /// "in-clip cost" means.
    ///
    /// The in-clip leg of the measurement runs on this. It is not a mode to
    /// ship — a clip that never stops is the measured ~7% floor — which
    /// is why it is reachable only through `EVLAT_MASCOT_PACING=continuous`.
    /// A one-shot clip comes out **looping** too, on purpose: played once it
    /// would be gone before the window opened. As a loop its step 0 re-enters
    /// the rest its last step returned to, so that step is dropped like any
    /// loop's — the variant measures the gesture, and the entering spring every
    /// phase shares is not part of it.
    var continuous: MascotClip {
        var previous = steps.last?.pose
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
    /// mix the cursor overwrites it, as it did before gaze was additive.
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

// MARK: - `working`

extension MascotClip {
    /// **`working`: heads-down.** The user's pick out of three candidates
    /// (the others were a body rhythm alone and a gaze release alone; both
    /// are gone).
    ///
    /// It carries both signals at low amplitude. The gaze is half released
    /// (`gazeMix` 0.30, in `resting(for:)`) and settles **downward** — onto the
    /// work rather than away from you — and the body bobs once while it is down
    /// there, with one dart sideways before it comes back up. The aims live in
    /// the pose's own `yaw`/`pitch`, the two fields no phase could reach before
    /// gaze was made additive; this clip is what that change was for.
    ///
    /// Like every clip it bursts rather than runs, blinks, never
    /// animates `gazeMix` and ends where it started, so the loop's
    /// seam is not a jump. Measured: 1.84% over 90 s at a duty cycle of 0.215.
    static func working() -> MascotClip {
        let rest = MascotPose.resting(for: .working)
        let down = rest.aimed(yaw: -0.18, pitch: 0.30)
        let aside = rest.aimed(yaw: 0.22, pitch: 0.26)
        return MascotClip(steps: [
            .entering(rest, hold: 1.1),
            .eased(down, over: 0.30, hold: 1.4),
            .eased(down.bobbed(0.985), over: 0.45, hold: 0.55),
            .eased(down.bobbed(1.025), over: 0.50, hold: 0.60),
            .eased(down, over: 0.50, hold: 1.5),
            .eased(aside, over: 0.10, hold: 1.3),
            // The blink keeps the aim it lands on, so the eyes open where they
            // closed rather than snapping back to centre mid-clip.
            blink(aside),
            .eased(aside, over: 0.12, hold: 1.9),
            // Back to the resting aim: a phase change out of `working` must not
            // start from an aim no other phase knows about.
            .eased(rest, over: 0.26, hold: 2.3)
        ], loops: true)
    }
}

// MARK: - `waiting`, `review`, `failed`

extension MascotClip {
    /// **`waiting`: turn to you, grow, and stop.** No loop.
    ///
    /// The phase that blocks the user has one job, and the signal is its
    /// *arrival*, not its motion: step 0's spring is where the eyes widen and
    /// the body leans out (`resting(for:)` carries both), and `gazeMix` 1 locks
    /// the eyes onto the cursor — which `working`, at 0.30 and looking down at
    /// its work, had let go. That contrast is free and it is the loudest thing
    /// the mascot can do. After it, one more swell, a settle, one blink, and
    /// then nothing: a face that keeps moving while it waits would read as
    /// busy, and a still one costs no frames for however long you take.
    ///
    /// The swell scales both axes — growing *is* the message here — by the
    /// same 1.02 `idle` breathes with, so it stays inside the area guard for
    /// the same reason the breath does (`MascotClipTests`).
    static func waiting() -> MascotClip {
        let rest = MascotPose.resting(for: .waiting)
        var swell = rest.scaled(by: 1.02)
        swell.eyeOpen = rest.eyeOpen * 1.10
        return MascotClip(steps: [
            .entering(rest, hold: 0.6),
            .eased(swell, over: 0.18, hold: 0.35),
            .eased(rest, over: 0.35, hold: 0.9),
            blink(rest),
            // The last step is the pose the clip holds for as long as the phase
            // lasts, so it is rest — the same face the sleeping branch draws.
            open(rest, hold: 0.5)
        ], loops: false)
    }

    /// **`review`: one look down at the work, then back up to you, and upright.**
    /// No loop.
    ///
    /// The head tilts on arrival — "had a look — is this right?" — and the
    /// gesture is a nod under it: the eyes drop onto the work while the body
    /// dips, come back up with a small lift, blink. Then the head comes back
    /// upright and holds there. It used to hold the tilt until the finish was
    /// seen, which read as stuck; the green ring keeps telling the finish
    /// (`AGENTS.md`: a phase rests upright, `MascotCharacterContractTests`).
    static func review() -> MascotClip {
        let rest = MascotPose.resting(for: .review)
        var asking = rest
        asking.tilt = reviewTilt
        return MascotClip(steps: [
            .entering(asking, hold: 0.7),
            .eased(asking.aimed(yaw: 0.10, pitch: 0.45).bobbed(0.975), over: 0.40, hold: 0.9),
            .eased(asking.bobbed(1.015), over: 0.35, hold: 0.4),
            .eased(asking, over: 0.25, hold: 0.6),
            blink(asking),
            open(asking, hold: 0.4),
            .eased(rest, over: 0.45, hold: 0.5)
        ], loops: false)
    }

    /// The question's lean, degrees: asked on arrival, never held.
    static let reviewTilt = 9.0

    /// **`failed`: the shudder, then a slow slump.** Loops, sparsely.
    ///
    /// The shudder (`MascotShake`) is the arrival, a transient of its
    /// own. What follows used to be `idle`'s rhythm on a squashed face,
    /// which made the two phases the same motion; this is its own: a slow,
    /// heavy blink, and now and then a sigh that sinks the body further and
    /// drops the eyes before it comes back. It keeps looping — a failure sits
    /// there until someone acts, and a face that never blinks reads as dead
    /// rather than sad — but slower than `idle`.
    static func failed() -> MascotClip {
        let rest = MascotPose.resting(for: .failed)
        var heavy = rest
        heavy.eyeOpen = rest.eyeOpen * 0.08
        return MascotClip(steps: [
            .entering(rest, hold: 5.0),
            .eased(heavy, over: 0.20, hold: 0.30),
            .eased(rest, over: 0.25, hold: 6.5),
            .eased(rest.bobbed(0.97).aimed(yaw: 0, pitch: 0.25), over: 1.0, hold: 1.4),
            .eased(rest, over: 1.2, hold: 1.25)
        ], loops: true)
    }
}

/// The `failed` shudder: one damped shake along x.
///
/// It stays out of `MascotPose` because it is not a pose the mascot can rest in
/// — it is a transient fired by *arriving* at `failed`, which is what SwiftUI's
/// `keyframeAnimator(trigger:)` is for. What it is not allowed to stay is
/// invisible to the tests: once, `grep -rn "shake\|keyframe" Tests/`
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

    /// Phase → shudder: out, back past centre, a smaller bounce, then still.
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
