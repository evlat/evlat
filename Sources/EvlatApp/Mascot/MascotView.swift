import SwiftUI
import EvlatCore

/// The mascot: a cube body with two eyes.
///
/// The form is a **cube** — an edged body reads with more character than a
/// sphere when it turns, and it also moves away from the reference. Expression
/// lives in the **eyes**, not the body; the body is a swappable shape
/// (ROADMAP → expression is in the pose, the form is pluggable).
///
/// `Canvas` is not used: drawing with plain shapes lets the springs attach
/// directly to view modifiers, and the transitions come free.
struct MascotView: View {
    @ObservedObject var model: MascotModel
    var size: CGFloat

    var body: some View {
        ZStack {
            if model.isAwake {
                // Awake: a clip walks the pose. `isAwake` is not `hasLive` —
                // see `MascotModel`.
                ClipPlayer(phase: model.effectivePhase, gaze: model.gaze, size: size)
            } else {
                // **Asleep.** The clip player leaves the view tree entirely — it
                // is removed, not hidden, and its pending step is dropped with
                // it. That is the only way a motionless bar stops producing
                // frames.
                MascotBody(pose: MascotPose.resting(for: model.effectivePhase)
                                          .blending(gaze: model.gaze),
                           size: size)
            }
        }
        // The `failed` shudder hangs **here**, above the awake branch, and not
        // on the body inside it. `keyframeAnimator` fires on a *change* of its
        // trigger and never on first appearance, so a host that is rebuilt by
        // the branch swap would miss it — and the swap is exactly what forcing
        // `failed` from the status menu with nothing live does. That is the one
        // case the preview exists for.
        .keyframeAnimator(initialValue: 0.0, trigger: model.effectivePhase) { view, shake in
            view.offset(x: shake)
        } keyframes: { _ in
            let keys = MascotShake.shake(for: model.effectivePhase).keys
            SpringKeyframe(keys[0].offset, duration: keys[0].duration)
            SpringKeyframe(keys[1].offset, duration: keys[1].duration)
            SpringKeyframe(keys[2].offset, duration: keys[2].duration)
            SpringKeyframe(keys[3].offset, duration: keys[3].duration)
        }
        .frame(width: size, height: size)
        .animation(MascotPose.transition, value: model.effectivePhase)
        .animation(MascotPose.transition, value: model.gaze)
    }
}

/// Walks a `MascotClip`: one `@State` index, one pending step, nothing else.
///
/// Timing is ours, interpolation is SwiftUI's. Each step schedules the next one
/// `hold` seconds out and then the view is completely still until it lands —
/// which is the whole CPU argument. Measured in `001`: *any* continuous SwiftUI
/// animation costs ~7% on this machine whatever the technique (`PhaseAnimator`
/// 11.5%, `repeatForever` 7.3%, plus `.drawingGroup()` 7.9%) against v1's 5.1%
/// sprite sheet, and nothing at all costs 0.1%. Bursts cost what their duty
/// cycle costs.
///
/// This view exists separately from `MascotView` so that leaving the tree kills
/// the walk: its `@State` dies with it and `onDisappear` drops the step already
/// in flight.
private struct ClipPlayer: View {
    let phase: Phase
    let gaze: CGSize
    let size: CGFloat

    @State private var step = 0
    /// Bumped whenever the clip is replaced or torn down. A pending step checks
    /// it and does nothing if the clip it belonged to is gone — otherwise a
    /// phase change during a long hold would advance the *new* clip one step
    /// early, and the old blink would land on the new face.
    @State private var generation = 0
    /// Whether a step is in flight. A clip with `loops == false` stops at its
    /// last step, and only this says so — otherwise a later phase change would
    /// sit waiting on a step that is never going to land.
    @State private var walking = false

    private var clip: MascotClip { MascotClip.clip(for: phase) }

    /// Clamped because `onChange` runs after a body render: for one pass the
    /// new clip is paired with the old clip's index, and clips do not all have
    /// the same number of steps. An empty clip is a bug the tests catch, but
    /// the mascot is not worth crashing the app over, so it rests instead.
    private var current: MascotClip.Step {
        guard let last = clip.steps.indices.last else {
            return MascotClip.Step(pose: MascotPose.resting(for: phase),
                                   curve: MascotPose.transition, hold: 1)
        }
        return clip.steps[min(step, last)]
    }

    var body: some View {
        MascotBody(pose: current.pose.blending(gaze: gaze), size: size)
            .animation(current.curve, value: step)
            .onAppear { restart() }
            .onDisappear { generation &+= 1; walking = false }
            .onChange(of: phase) { _, _ in enter() }
    }

    /// A phase change lands on the new clip's first pose, but **does not
    /// restart the walk** unless it has stopped.
    ///
    /// Rescheduling here would put the full first hold between the phase change
    /// and the next blink, and the aggregate can flip faster than that while an
    /// agent works — so the mascot would go completely still exactly when it is
    /// busiest. `001` shipped that bug once already, keyed on the cursor rather
    /// than the phase: the note on the heartbeat it replaced read *"a moving
    /// cursor can no longer keep resetting the timer so the mascot never
    /// blinks"*. The step in flight keeps its own schedule and reads the new
    /// clip when it lands.
    private func enter() {
        step = 0
        if !walking { restart() }
    }

    private func restart() {
        generation &+= 1
        step = 0
        scheduleNext()
    }

    private func scheduleNext() {
        walking = true
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + current.hold) {
            // The clip this step belonged to is gone: the player left the tree,
            // or a stopped walk was started again.
            guard mine == generation else { return }
            advance()
        }
    }

    private func advance() {
        let next = step + 1
        if next < clip.steps.count {
            step = next
        } else if clip.loops {
            step = 0
        } else {
            // Played out: hold the final pose and stop scheduling. Nothing
            // moves again until a phase change starts the walk over.
            walking = false
            return
        }
        scheduleNext()
    }
}

/// The cube itself. Draws a pose; decides nothing, and knows nothing about
/// phases — the one thing a phase drives directly, the shudder, hangs above it
/// in `MascotView`.
private struct MascotBody: View {
    let pose: MascotPose
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color.white.opacity(0.92))
            eyes
        }
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .center)
        .rotationEffect(.degrees(pose.tilt))
    }

    private var eyes: some View {
        HStack(spacing: size * 0.16) {
            eye(side: -1)
            eye(side: 1)
        }
        // The eyes are children of the body: when it tilts they go with it. If
        // they lived in their own coordinate space the result would read as two
        // dots stuck on a box.
        .offset(x: pose.yaw * size * 0.11, y: pose.pitch * size * 0.08)
    }

    /// One eye. A cube's face is flat, so instead of the sphere's angle mapping
    /// this uses **perspective narrowing**: as the face turns, the far eye gets
    /// thinner.
    private func eye(side: Double) -> some View {
        // If the face turns by `yaw`, the eye on the opposite side travels
        // toward the edge and narrows. Close to a cosine, but nearly linear,
        // which suits a cube.
        let away = max(0, side * pose.yaw)
        let narrow = 1 - away * 0.42
        let width = size * 0.13 * narrow
        // Eye height has exactly one writer now: the pose. The blink used to
        // arrive from a separate `lidClosed` flag multiplied in here.
        let height = size * 0.30 * pose.eyeOpen * (1 - pose.eyeSquint * 0.55)

        return Capsule(style: .continuous)
            .fill(Color.black.opacity(0.92))
            .frame(width: width, height: max(width * 0.35, height))
            // A squint closes the eye from above: the lid comes down, the eye
            // does not drift upward.
            .offset(y: pose.eyeSquint * size * 0.04)
    }
}
