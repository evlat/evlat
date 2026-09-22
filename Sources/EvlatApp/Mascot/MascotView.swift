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
    /// Breathing and blinking state. Kept here rather than in the model because
    /// it is pure presentation: when `hasLive` goes false this view is destroyed
    /// and both die with it.
    @State private var inhale = false
    @State private var lidClosed = false

    /// The idle heartbeat. Each tick fires **one short** animation and then
    /// everything goes quiet again — see `breathing` for why this is not a
    /// continuous loop.
    private static let beat = 4.0

    /// One publisher for the whole process, not one per view.
    ///
    /// `private let` on a struct `View` is **not** per-lifetime storage: the
    /// view is a value that SwiftUI rebuilds on every parent update, so a stored
    /// publisher is a new instance each time and `onReceive` re-subscribes,
    /// restarting the beat. The first fix only moved that churn from this view's
    /// body up into its parent's. Since the beat carries no per-view state,
    /// `static` is the honest lifetime — and it means a moving cursor can no
    /// longer keep resetting the timer so the mascot never blinks.
    private static let heartbeat = Timer
        .publish(every: MascotView.beat, on: .main, in: .common)
        .autoconnect()

    private var pose: MascotPose {
        var p = MascotPose.resting(for: model.effectivePhase)
        // Gaze rides ON TOP of every phase: whatever mood it is in, the mascot
        // still follows the cursor.
        p.yaw = model.gaze.width
        p.pitch = model.gaze.height
        return p
    }

    var body: some View {
        ZStack {
            animatedBody
        }
        .frame(width: size, height: size)
        .animation(MascotPose.transition, value: model.effectivePhase)
        .animation(MascotPose.transition, value: model.gaze)
    }

    @ViewBuilder
    private var animatedBody: some View {
        if model.hasLive {
            // While a session is live it breathes and blinks.
            breathing { cube }
        } else {
            // **Asleep.** The `PhaseAnimator` leaves the view tree entirely —
            // it is removed, not hidden. That is the only way a motionless bar
            // stops producing frames.
            cube
        }
    }

    /// Idle liveliness: an occasional blink, a rarer breath. **Never a
    /// continuous loop**, and that is a measured decision, not a stylistic one.
    ///
    /// Measured on this machine, mascot visible with a live session:
    ///   - `PhaseAnimator` cycling a `scaleEffect` — **11.5% CPU**
    ///   - a single property on `repeatForever` — **7.3%**
    ///   - the same plus `.drawingGroup()` — **7.9%**
    ///   - no animation at all — **0.1%**
    ///
    /// So roughly 7% is the floor for *any* continuous SwiftUI animation here,
    /// whatever the technique — and v1's sprite sheet cost 5.1%. Continuous
    /// motion would have thrown away the entire reason for choosing this path.
    ///
    /// Bursts cost what their duty cycle costs: a ~0.2 s blink or a ~2.4 s
    /// breath every 4 s averages far below the floor, and between them the view
    /// is completely still. It also reads better — something pulsing forever at
    /// the edge of vision is noise, not life.
    private func breathing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .scaleEffect(inhale ? 1.02 : 1.0, anchor: .center)
            .onReceive(Self.heartbeat) { _ in
                // Blinking is the common tick, breathing the rare one, so the
                // rhythm stays organic instead of metronomic.
                if Int.random(in: 0..<10) < 7 { blink() } else { breathe() }
            }
    }

    private func blink() {
        withAnimation(.easeInOut(duration: 0.08)) { lidClosed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.easeInOut(duration: 0.12)) { lidClosed = false }
        }
    }

    private func breathe() {
        withAnimation(.easeInOut(duration: 1.1)) { inhale = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeInOut(duration: 1.3)) { inhale = false }
        }
    }

    private var cube: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color.white.opacity(0.92))
            eyes
        }
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .center)
        .rotationEffect(.degrees(pose.tilt))
        .keyframeAnimator(initialValue: 0.0, trigger: model.effectivePhase) { view, shake in
            view.offset(x: shake)
        } keyframes: { _ in
            // The `failed` shake: one damped shudder. It stays at zero in every
            // other phase because the amplitude is phase-dependent.
            let amplitude = model.effectivePhase == .failed ? 3.5 : 0.0
            SpringKeyframe(amplitude, duration: 0.05)
            SpringKeyframe(-amplitude, duration: 0.07)
            SpringKeyframe(amplitude * 0.5, duration: 0.07)
            SpringKeyframe(0, duration: 0.12)
        }
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
        let lid = lidClosed ? 0.08 : 1.0
        let height = size * 0.30 * pose.eyeOpen * (1 - pose.eyeSquint * 0.55) * lid

        return Capsule(style: .continuous)
            .fill(Color.black.opacity(0.92))
            .frame(width: width, height: max(width * 0.35, height))
            // A squint closes the eye from above: the lid comes down, the eye
            // does not drift upward.
            .offset(y: pose.eyeSquint * size * 0.04)
    }
}
