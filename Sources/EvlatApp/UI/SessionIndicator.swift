import SwiftUI
import EvlatCore

/// The column under the mascot: one ring per slot, and the overflow count;
/// on the open bar, each ring's session name to its left.
///
/// It observes `SessionRowsModel` and nothing else — the mascot's gaze moves
/// with the cursor, and a column that observed the mascot would be rebuilt at
/// that rate for nothing. Whether names show is handed in by `BarBody`.
///
/// **Opening moves no ring.** A name is an overlay on its ring, not a sibling
/// in a row: it takes no room, so the ring's place is the same open or closed.
/// The name comes in from the ring's side, a few points toward it, and fades.
struct SessionColumn: View {
    @ObservedObject var model: SessionRowsModel
    var showsNames = false

    /// Between a name's end and its ring.
    static let nameGap: CGFloat = 8
    /// Between the open body's inner edge and the longest name.
    static let nameInset: CGFloat = 14
    /// How far a name travels as it comes in: from under its ring's side.
    static let nameTravel: CGFloat = 10
    /// The widest a name is drawn; a longer one is cut with "…". It also caps
    /// how far the body opens.
    static let nameMaxWidth: CGFloat = 140
    /// The narrowest the open body gets, so a column of short names still
    /// reads as a panel rather than a ragged tab.
    static let minOpenWidth: CGFloat = 110
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The ring's leading edge inside the bar's width (it is centred there).
    static var ringLead: CGFloat { (AppController.barWidth - AppController.indicatorSize) / 2 }

    /// The width the names need, as drawn: the longest one, and the count
    /// when it has moved into the name column. Capped at `nameMaxWidth`.
    static func namesWidth(_ labels: [String], overflow: Int) -> CGFloat {
        let texts = labels + (overflow > 0 ? ["+\(overflow)"] : [])
        let widest = texts.map {
            ($0 as NSString).size(withAttributes: [.font: nameFont]).width
        }.max() ?? 0
        return min(ceil(widest), nameMaxWidth)
    }

    /// The open body's width for names this wide: the part of the bar right
    /// of the ring's leading edge, the gap, the names and the inset.
    static func openWidth(namesWidth: CGFloat) -> CGFloat {
        let width = AppController.barWidth - ringLead + nameGap + namesWidth + nameInset
        return max(minOpenWidth, width)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: AppController.indicatorSpacing) {
            // Identity is the session, so a reorder travels on the spring
            // rather than snapping rings into each other's places.
            ForEach(model.rows) { row in
                // Centred in the collapsed bar's width, the same column the
                // mascot sits in.
                SessionIndicator(phase: row.phase,
                                 // Only a beating row sees the counter move. A
                                 // still row's trigger never changes on the
                                 // beat, so it plays nothing and draws nothing.
                                 beat: row.beats ? model.beat : 0)
                    .frame(width: AppController.barWidth)
                    .overlay(alignment: .leading) {
                        name(row.label, color: row.phase == .idle
                             ? BarPalette.textSecondary : BarPalette.textPrimary)
                    }
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
            if model.overflow > 0 {
                // A number, not a word: no user text until the catalogue.
                // Closed, it sits in the ring column; open, it moves into the
                // name column and reads as the list's last line.
                Text("+\(model.overflow)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BarPalette.textSecondary)
                    // Wider than a ring: in a ring-sized frame a two-digit
                    // count truncated to "…" (seen on the live bar).
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: AppController.indicatorSize)
                    .frame(width: AppController.barWidth)
                    .opacity(showsNames ? 0 : 1)
                    .animation(showsNames ? BarMotion.namesOut : BarMotion.namesIn, value: showsNames)
                    .overlay(alignment: .leading) {
                        name("+\(model.overflow)", color: BarPalette.textSecondary)
                    }
                    .transition(.opacity)
            }
        }
        .animation(MascotPose.transition, value: model.rows)
        .animation(MascotPose.transition, value: model.overflow)
    }

    /// The name, right-aligned against its ring. Its own animation, keyed on
    /// `showsNames` alone: it comes in just after the body starts to open and
    /// goes out before the body starts to close, so no name is ever drawn
    /// past the body's edge.
    ///
    /// Idle sessions are grey and the rest white: the same split the rings
    /// make, so the eye lands on what is doing something.
    private func name(_ label: String, color: Color) -> some View {
        // The name is data, not text of ours: it is what the user called the
        // session, so it bypasses the string lookup (`verbatim`) and needs no
        // catalogue entry.
        Text(verbatim: label)
            .font(Font(Self.nameFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: Self.nameMaxWidth, alignment: .trailing)
            // Held to a ring's height: a taller line would push the rings
            // apart the moment the bar opens.
            .frame(height: AppController.indicatorSize)
            .offset(x: Self.ringLead - Self.nameGap - Self.nameMaxWidth
                        + (showsNames ? 0 : Self.nameTravel))
            .opacity(showsNames ? 1 : 0)
            .animation(showsNames ? BarMotion.namesIn : BarMotion.namesOut, value: showsNames)
            .allowsHitTesting(false)
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
