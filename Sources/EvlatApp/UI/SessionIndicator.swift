import SwiftUI
import EvlatCore

/// The column under the mascot: one ring per slot, and the overflow count.
///
/// It observes `SessionRowsModel` and nothing else — the mascot's gaze moves
/// with the cursor, and a column that observed the mascot would be rebuilt at
/// that rate for nothing.
struct SessionColumn: View {
    @ObservedObject var model: SessionRowsModel

    var body: some View {
        VStack(spacing: AppController.indicatorSpacing) {
            // Identity is the session, so a reorder travels on the spring
            // rather than snapping rings into each other's places.
            ForEach(model.rows) { row in
                SessionIndicator(phase: row.phase,
                                 // Only a beating row sees the counter move. A
                                 // still row's trigger never changes on the
                                 // beat, so it plays nothing and draws nothing.
                                 beat: row.beats ? model.beat : 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if model.overflow > 0 {
                // A number, not a word: no user text until the catalogue.
                Text("+\(model.overflow)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.55))
                    // Wider than a ring: in a ring-sized frame a two-digit
                    // count truncated to "…" (seen on the live bar).
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: AppController.indicatorSize)
                    .transition(.opacity)
            }
        }
        .animation(MascotPose.transition, value: model.rows)
        .animation(MascotPose.transition, value: model.overflow)
    }
}

/// One session's ring. The phase picks the look (ROADMAP → the indicator's
/// language); the beat plays the gesture.
///
/// **Beats, not loops.** A spinning arc under `TimelineView` or
/// `repeatForever` is the ~7% floor `001` measured, and a working session runs
/// for hours. So `working` turns once per beat and `waiting` pulses once per
/// beat, still in between; `review` flares once on arrival and fades.
struct SessionIndicator: View {
    let phase: Phase
    let beat: Int

    private var size: CGFloat { AppController.indicatorSize }

    var body: some View {
        ring
            .frame(width: size, height: size)
            .animation(MascotPose.transition, value: phase)
            // Hung **above** the phase-dependent drawing, never inside a
            // branch: `keyframeAnimator` fires on a *change* of its trigger and
            // never on first appearance, so a host rebuilt by a phase change
            // would miss exactly the arrival it exists for (`AGENTS.md` →
            // Tuzaklar). The trigger carries the phase so arriving at
            // `review` flares, and the beat so a beating row gestures.
            .keyframeAnimator(initialValue: IndicatorGesture(),
                              trigger: IndicatorTrigger(phase: phase, beat: beat)) { view, g in
                view
                    .rotationEffect(.degrees(g.spin))
                    .scaleEffect(g.pulse)
                    .shadow(color: glowColor.opacity(g.glow), radius: size * 0.35)
            } keyframes: { _ in
                KeyframeTrack(\.spin) {
                    for key in IndicatorGesture.spin(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.pulse) {
                    for key in IndicatorGesture.pulse(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.glow) {
                    for key in IndicatorGesture.glow(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
            }
    }

    private var line: CGFloat { max(1.5, size * 0.13) }

    @ViewBuilder private var ring: some View {
        // Exhaustive on purpose: a new `Phase` must not compile until it has
        // a look here (`proje.md` → Yayın etkisi, the three places).
        switch phase {
        case .idle:
            Circle().stroke(Color.white.opacity(0.28), lineWidth: line)
        case .working:
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
                // The thin arc. The beat turns the whole ring; the track is
                // round, so only the arc is seen to move.
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        case .waiting:
            Circle()
                .stroke(Self.amber, lineWidth: line)
                .background(Circle().fill(Self.amber.opacity(0.35)))
        case .review:
            Circle().stroke(Self.green.opacity(0.8), lineWidth: line)
        case .failed:
            Circle()
                .stroke(Self.red, lineWidth: line)
                .background(Circle().fill(Self.red.opacity(0.3)))
        }
    }

    private var glowColor: Color {
        switch phase {
        case .waiting: return Self.amber
        case .review: return Self.green
        case .idle, .working, .failed: return .clear
        }
    }

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.18)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let red = Color(red: 0.95, green: 0.30, blue: 0.28)
}

/// What fires a gesture: arriving at a phase, or a beat while in one.
struct IndicatorTrigger: Equatable {
    var phase: Phase
    var beat: Int
}

/// The animated values of one gesture, and the table of gestures per phase —
/// the same shape as `MascotShake`, so what each phase does is a claim the
/// tests can read rather than a branch inside a view.
///
/// **Every track ends where it started.** Whether the animator keeps the last
/// keyframe or falls back to the initial value, the ring is left in its rest
/// state, and the next gesture starts from rest.
struct IndicatorGesture {
    /// Degrees the ring is turned.
    var spin: Double = 0
    /// Scale of the ring.
    var pulse: Double = 1
    /// Opacity of the halo.
    var glow: Double = 0

    struct Key: Equatable {
        var value: Double
        /// Seconds to reach it.
        var duration: Double
    }

    /// `working`: one full turn, then snap back to 0 — which is the same angle.
    static func spin(for phase: Phase) -> [Key] {
        guard phase == .working else { return [] }
        return [Key(value: 360, duration: 0.9), Key(value: 0, duration: 0)]
    }

    /// `waiting`: one swell and back — the amber pulse.
    static func pulse(for phase: Phase) -> [Key] {
        switch phase {
        case .waiting: return [Key(value: 1.3, duration: 0.2), Key(value: 1, duration: 0.45)]
        case .review: return [Key(value: 1.25, duration: 0.15), Key(value: 1, duration: 0.5)]
        case .idle, .working, .failed: return []
        }
    }

    /// `waiting` glows with its pulse; `review` flares and fades — the
    /// "green, then dies away" of the indicator language, played once.
    static func glow(for phase: Phase) -> [Key] {
        switch phase {
        case .waiting: return [Key(value: 0.9, duration: 0.2), Key(value: 0, duration: 0.45)]
        case .review: return [Key(value: 1, duration: 0.15), Key(value: 0, duration: 1.6)]
        case .idle, .working, .failed: return []
        }
    }

    /// How long the gesture keeps producing frames: the longest track.
    static func duration(for phase: Phase) -> Double {
        [spin(for: phase), pulse(for: phase), glow(for: phase)]
            .map { $0.reduce(0) { $0 + $1.duration } }
            .max() ?? 0
    }
}
