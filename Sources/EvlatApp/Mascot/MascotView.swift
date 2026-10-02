import SwiftUI
import EvlatCore

/// The mascot: a cube body with two eyes.
///
/// The form is a **cube** — an edged body reads with more character than a
/// sphere when it turns, and it also moves away from the reference. Expression
/// lives in the **eyes**, not the body; the body is a swappable shape
/// (`AGENTS.md` → Architecture: expression is in the pose, the form is
/// pluggable).
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
            for key in MascotShake.shake(for: model.effectivePhase).keys {
                SpringKeyframe(key.offset, duration: key.duration)
            }
        }
        .frame(width: size, height: size)
        // A caught file is drawn by whichever body is on
        // screen, read from the environment — not handed to `ClipPlayer` as
        // a stored value, whose scheduled steps close over a copy (AGENTS.md →
        // Pitfalls). The walk goes on underneath; the face is the file's.
        .environment(\.caughtGaze, model.caughtGaze)
        .environment(\.mascotCharacter, model.character)
        .environment(\.mascotPhase, model.effectivePhase)
        .environment(\.mascotResting, !model.isAwake && model.isShown)
        .environment(\.mascotCallout, model.callout)
        .environment(\.mascotPortrait, model.portrait)
        .environment(\.mascotPack, model.activePack)
        .environment(\.mascotPokes, model.pokes)
        .environment(\.mascotTones, model.cubeTint ? model.tones : nil)
        .background { dropRing }
        .animation(MascotPose.transition, value: model.effectivePhase)
        .animation(MascotPose.transition, value: model.gaze)
        .animation(MascotPose.transition, value: model.catching)
    }

    /// Where to drop: a soft ring around the mascot, only while a file is
    /// over the bar. Out of the tree otherwise — nothing is drawn for it
    /// when no drag is on.
    @ViewBuilder private var dropRing: some View {
        if model.catching {
            let ring = RoundedRectangle(cornerRadius: size * 0.3 + Self.ringInset, style: .continuous)
            ring.fill(Color.white.opacity(0.06))
                .overlay(ring.strokeBorder(Color.white.opacity(0.34), lineWidth: 1.5))
                .padding(-Self.ringInset)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
        }
    }

    /// How far the ring stands off the mascot: inside the bar's width
    /// (`AppController.barWidth` 54 against a 34 mascot).
    static let ringInset: CGFloat = 6
}

private struct CaughtGazeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// The caught file's direction while one is being dragged over the bar;
    /// `nil` otherwise. See `MascotPose.drawn`.
    var caughtGaze: CGSize? {
        get { self[CaughtGazeKey.self] }
        set { self[CaughtGazeKey.self] = newValue }
    }
}

/// Walks a `MascotClip`: one `@State` index, one pending step, nothing else.
///
/// Timing is ours, interpolation is SwiftUI's. Each step schedules the next one
/// `hold` seconds out and then the view is completely still until it lands —
/// which is the whole CPU argument. Measured: *any* continuous SwiftUI
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
    /// Bumped whenever the walk is started over or torn down. A pending step
    /// checks it and does nothing if the walk it belonged to is gone.
    ///
    /// A phase change into a **looping** clip does *not* bump it: the step in
    /// flight keeps its schedule and lands on the new clip (see `enter()`). A
    /// change into a **one-shot** clip does, because that clip's gesture is
    /// timed from the arrival and it only gets one chance.
    @State private var generation = 0
    /// Whether a step is in flight. A clip with `loops == false` stops at its
    /// last step, and only this says so — otherwise a later phase change would
    /// sit waiting on a step that is never going to land.
    @State private var walking = false
    /// The phase whose clip the walk is on. It mirrors `phase`, but it has to
    /// live in `@State`: the pending step is a closure over a **copy** of this
    /// struct, so `phase` read from inside it is the phase at the moment the
    /// step was scheduled. A walk that carried on into a looping clip would
    /// keep playing the old one — and one carried on from `waiting` would run
    /// out at `waiting`'s last step and leave the new phase frozen. `@State` is
    /// the storage that closure reads live, the way it reads `generation`.
    @State private var walkedPhase: Phase?

    private var clipPhase: Phase { walkedPhase ?? phase }
    private var clip: MascotClip { MascotClip.clip(for: clipPhase) }

    /// Clamped because clips do not all have the same number of steps, and the
    /// index and the clip are two separate pieces of state that change in the
    /// same `enter()`. An empty clip is a bug the tests catch, but the mascot is
    /// not worth crashing the app over, so it rests instead.
    private var current: MascotClip.Step {
        guard let last = clip.steps.indices.last else {
            return .entering(MascotPose.resting(for: clipPhase), hold: 1)
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
    /// busiest. An early version shipped that bug once already, keyed on the cursor rather
    /// than the phase: the note on the heartbeat it replaced read *"a moving
    /// cursor can no longer keep resetting the timer so the mascot never
    /// blinks"*. The step in flight keeps its own schedule and reads the new
    /// clip when it lands.
    ///
    /// **One-shot clips are the exception** (`waiting`, `review`): their gesture
    /// is the arrival, so it is timed from the phase change and not from
    /// whatever was left of the old clip's hold. Inheriting that hold would
    /// play the swell up to 6.5 s late, or cut step 0's spring short a tenth
    /// of a second in. The flapping argument above does not apply to them —
    /// restarting a clip that plays once cannot starve a rhythm.
    private func enter() {
        // The new clip's first pose reaches the screen here, not in the render
        // that carried the phase change — that one still drew `walkedPhase`.
        // So the spring has to be supplied here: when `step` was already 0 the
        // `.animation(value: step)` below sees no change and the pose would jump.
        withAnimation(MascotPose.transition) {
            walkedPhase = phase
            step = 0
        }
        if !walking || !MascotClip.clip(for: phase).loops { restart() }
    }

    private func restart() {
        walkedPhase = phase
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
        guard let next = clip.step(after: step) else {
            // Played out: hold the final pose and stop scheduling. Nothing
            // moves again until a phase change starts the walk over.
            walking = false
            return
        }
        step = next
        scheduleNext()
    }
}

/// The cube itself. Draws a pose; decides nothing, and knows nothing about
/// phases — the one thing a phase drives directly, the shudder, hangs above it
/// in `MascotView`. The setup window draws its still face with it too
/// (`SetupView`).
struct MascotBody: View {
    /// The pose it was handed; `drawn` is what it draws.
    let pose: MascotPose
    let size: CGFloat
    @Environment(\.caughtGaze) private var caughtGaze
    @Environment(\.mascotCharacter) private var character
    @Environment(\.mascotPortrait) private var portrait
    @Environment(\.mascotPack) private var pack
    @Environment(\.mascotPokes) private var pokes
    @Environment(\.mascotTones) private var tones

    private var drawn: MascotPose { MascotPose.drawn(pose, catching: caughtGaze) }

    /// A poke is a blink on top of the pose: a beat of its own, ~0.3 s, so
    /// it never waits on the clip. The fairy turns it into a flap.
    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: pokes) { open in
            character(drawn.blinked(open))
        } keyframes: { _ in
            CubicKeyframe(0.08, duration: 0.08)
            CubicKeyframe(0.08, duration: 0.06)
            CubicKeyframe(1, duration: 0.14)
        }
    }

    @ViewBuilder private func character(_ pose: MascotPose) -> some View {
        switch (character, portrait) {
        case (.fairy, _): FairyBody(pose: pose, size: size)
        case (.portrait, let portrait?): PortraitBody(pose: pose, size: size, portrait: portrait)
        case (.pack, _) where pack != nil: PackBody(pose: pose, size: size, loaded: pack!)
        default: cube(pose)
        }
    }

    private func cube(_ pose: MascotPose) -> some View {
        ZStack {
            CubeFill(counts: tones)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            eyes(pose)
        }
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .center)
        .rotationEffect(.degrees(pose.tilt))
    }

    private func eyes(_ pose: MascotPose) -> some View {
        HStack(spacing: size * 0.16) {
            eye(side: -1, pose)
            eye(side: 1, pose)
        }
        // The eyes are children of the body: when it tilts they go with it. If
        // they lived in their own coordinate space the result would read as two
        // dots stuck on a box.
        .offset(x: pose.yaw * size * 0.11, y: pose.pitch * size * 0.08)
    }

    /// One eye. A cube's face is flat, so instead of the sphere's angle mapping
    /// this uses **perspective narrowing**: as the face turns, the far eye gets
    /// thinner.
    private func eye(side: Double, _ pose: MascotPose) -> some View {
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
