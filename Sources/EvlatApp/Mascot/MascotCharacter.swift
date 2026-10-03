import SwiftUI
import EvlatCore

/// Who the mascot is: the body that draws a `MascotPose`.
///
/// A character only **draws**. Phases, clips, gaze and the `failed` shudder
/// are the mascot's and stay the same whoever is drawn, so every character
/// moves in the same beats and an idle bar still produces no frames
/// (`AGENTS.md` → Rendering and CPU). A new character is a new case and a
/// view that reads the pose's eight numbers its own way.
enum MascotCharacter: String, CaseIterable, Identifiable {
    /// The cube with two eyes: the default.
    case cube
    /// A glowing fairy with four wings. The eyes' channels drive the wings —
    /// a blink is a flap, a widened eye spreads them — and the gaze moves
    /// the whole fairy instead of two pupils.
    case fairy
    /// An installed character pack (`CharacterPack`), named by
    /// `mascot.pack`. Drawn as the cube when it is gone.
    case pack
    /// The user's own, made from a picture (`Portrait`). Drawn as the cube
    /// until one exists. Last in the picker.
    case portrait

    var id: String { rawValue }

    /// Stored under `mascot.character`; anything unknown is the cube.
    static func stored(_ raw: String?) -> MascotCharacter {
        raw.flatMap(MascotCharacter.init(rawValue:)) ?? .cube
    }

    var nameKey: String { "character.\(rawValue)" }
}

private struct MascotCharacterKey: EnvironmentKey {
    static let defaultValue: MascotCharacter = .cube
}

/// A moment the mascot just spoke (`AppController.speak`), for a look that
/// answers it on screen. `count` is the trigger; `tone` the colour.
struct MascotCallout: Equatable {
    /// A call for the user, a finish, a failure; `hello`, the bright one,
    /// is the value before any moment has spoken.
    enum Tone { case hello, attention, done, oops }
    var count = 0
    var tone: Tone = .hello
}

private struct MascotPhaseKey: EnvironmentKey { static let defaultValue: Phase = .idle }
private struct MascotRestingKey: EnvironmentKey { static let defaultValue = false }
private struct MascotCalloutKey: EnvironmentKey { static let defaultValue = MascotCallout() }
private struct MascotPokesKey: EnvironmentKey { static let defaultValue = 0 }

extension MascotPose {
    /// The eyes closed by `open` (1 is as posed), for a poke's blink.
    func blinked(_ open: Double) -> MascotPose {
        var p = self
        p.eyeOpen *= open
        return p
    }
}

extension EnvironmentValues {
    /// The character `MascotBody` draws; the cube unless a host sets one.
    var mascotCharacter: MascotCharacter {
        get { self[MascotCharacterKey.self] }
        set { self[MascotCharacterKey.self] = newValue }
    }
    /// The phase on screen, for a character whose colour follows it. The
    /// cube ignores it: its face is the pose.
    var mascotPhase: Phase {
        get { self[MascotPhaseKey.self] }
        set { self[MascotPhaseKey.self] = newValue }
    }
    /// Asleep and on screen: the clip player is gone, and only a
    /// character's own sparse beat may still move.
    var mascotResting: Bool {
        get { self[MascotRestingKey.self] }
        set { self[MascotRestingKey.self] = newValue }
    }
    /// The mascot's poke count (`MascotModel.poke`): each one is a blink.
    var mascotPokes: Int {
        get { self[MascotPokesKey.self] }
        set { self[MascotPokesKey.self] = newValue }
    }
    var mascotCallout: MascotCallout {
        get { self[MascotCalloutKey.self] }
        set { self[MascotCalloutKey.self] = newValue }
    }
}

/// The fairy: a bright core in a soft halo, two pairs of wings.
///
/// Read off the same pose as the cube's face:
/// - `yaw`/`pitch` move the whole fairy towards where the eyes would look,
///   and the far wings narrow as the cube's far eye does;
/// - `eyeOpen` is the wings' spread; a **blink** is too quick to read as a
///   wing, so it starts a flap of its own: one eased beat with a lift;
/// - `eyeSquint` (`working`) draws the glow in and lowers the wings a little;
/// - squash is a hover: a breath lifts the fairy instead of stretching it.
///
/// Her colour is the action's — blue at rest and at work, yellow when a
/// session needs you, green on a finish, red on a failure — and a sound the
/// mascot says (`MascotCallout`) flares her in its own colour.
///
/// **What moves, and when.** Everything rides on beats, as the cube does:
/// the clip player's steps, a flap (~0.9 s) or a callout (~1.2 s). Asleep,
/// where the cube is still, the fairy flutters once every 25–45 s
/// (`restingFlutter`): a duty cycle near 2%, the one place a character moves
/// at idle.
struct FairyBody: View {
    let pose: MascotPose
    let size: CGFloat
    @Environment(\.mascotPhase) private var phase
    @Environment(\.mascotResting) private var resting
    @Environment(\.mascotCallout) private var callout

    /// What a beat animates on top of the pose.
    struct Beat {
        var fold = 0.0
        var lift = 0.0
        var flare = 0.0
    }
    private enum Kind {
        case flap, callout
        /// Wing beats, ~0.4 s each — a 0.18 s down-stroke, a 0.24 s
        /// recovery: one for a flap, two for a call.
        var strokes: [(fold: Double, duration: Double)] {
            Array(repeating: [(0.7, 0.18), (0, 0.24)], count: self == .flap ? 1 : 2).flatMap { $0 }
        }
        var lift: Double { self == .flap ? 1 : 1.6 }
        var flare: Double { self == .flap ? 0 : 1 }
    }

    @State private var beats = 0
    @State private var kind = Kind.flap
    /// Bumped to drop a pending resting flutter.
    @State private var generation = 0

    static let restingFlutter: ClosedRange<Double> = 25...45

    var body: some View {
        KeyframeAnimator(initialValue: Beat(), trigger: beats) { beat in
            drawn(beat)
        } keyframes: { _ in
            // One shape for both beats; the numbers are the kind's.
            // A beat is a down-stroke and a slower recovery, eased both
            // ways: a controlled flap, not a buzz.
            KeyframeTrack(\Beat.fold) {
                for step in kind.strokes { CubicKeyframe(step.fold, duration: step.duration) }
            }
            KeyframeTrack(\Beat.lift) {
                CubicKeyframe(kind.lift, duration: 0.3)
                SpringKeyframe(0, duration: 0.6)
            }
            KeyframeTrack(\Beat.flare) {
                CubicKeyframe(kind.flare, duration: 0.12)
                CubicKeyframe(kind.flare, duration: 0.25)
                CubicKeyframe(0, duration: 0.5)
            }
        }
        .onChange(of: pose.eyeOpen < 0.4) { _, closing in if closing { beat(.flap) } }
        .onChange(of: callout.count) { _, _ in beat(.callout) }
        .onChange(of: resting, initial: true) { _, now in
            generation &+= 1
            if now { scheduleFlutter() }
        }
        .onDisappear { generation &+= 1 }
    }

    private func beat(_ kind: Kind) {
        self.kind = kind
        beats &+= 1
    }

    private func scheduleFlutter() {
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: Self.restingFlutter)) {
            guard mine == generation, resting else { return }
            beat(.flap)
            scheduleFlutter()
        }
    }

    /// The colour the phase gives — the action's own: a finish is green, a
    /// call for you yellow, a failure red — and a callout's on top while it
    /// flares.
    private var tint: Hue {
        switch phase {
        case .waiting: return Self.yellow
        case .review: return Self.green
        case .failed: return Self.red
        case .idle, .working: return Self.blue
        }
    }

    private var calloutTint: Hue {
        switch callout.tone {
        case .hello: return Self.bright
        case .attention: return Self.yellow
        case .done: return Self.green
        case .oops: return Self.red
        }
    }

    /// A colour and its pale inner shade (no `Color.mix` before macOS 15).
    struct Hue {
        let color: Color
        let light: Color
    }
    static let blue = Hue(color: Color(red: 0.42, green: 0.80, blue: 1.0), light: Color(red: 0.80, green: 0.95, blue: 1.0))
    static let green = Hue(color: Color(red: 0.45, green: 1.0, blue: 0.55), light: Color(red: 0.84, green: 1.0, blue: 0.86))
    static let yellow = Hue(color: Color(red: 1.0, green: 0.86, blue: 0.30), light: Color(red: 1.0, green: 0.96, blue: 0.78))
    /// The hello: her own blue, brighter.
    static let bright = Hue(color: Color(red: 0.55, green: 0.88, blue: 1.0), light: Color(red: 0.92, green: 0.98, blue: 1.0))
    static let red = Hue(color: Color(red: 1.0, green: 0.42, blue: 0.40), light: Color(red: 1.0, green: 0.82, blue: 0.80))

    private func drawn(_ beat: Beat) -> some View {
        let color = beat.flare > 0 ? calloutTint : tint
        let open = min(1.25, max(0.12, pose.eyeOpen)) * (1 - pose.eyeSquint * 0.25)
        let spread = max(0.15, open * (1 - beat.fold))
        let dim = resting ? 0.7 : 1.0
        let glow = (0.55 + 0.3 * min(1.4, pose.eyeOpen) - 0.25 * pose.eyeSquint + 0.5 * beat.flare) * dim
        // A breath (squash above 1) lifts her instead of stretching her.
        let hover = (pose.scaleY - 1) * size * 1.6 + beat.lift * size * 0.06
        return ZStack {
            halo(color, glow: glow, flare: beat.flare)
            wings(spread: spread, color: color)
            core(color, flare: beat.flare, dim: dim)
        }
        .rotationEffect(.degrees(pose.tilt))
        .offset(x: pose.yaw * size * 0.16, y: pose.pitch * size * 0.12 - hover)
        // Light and wings carry less weight than the cube's solid face:
        // drawn larger, she reads at the cube's size.
        .scaleEffect(Self.scale)
    }

    static let scale = 1.35

    private func halo(_ color: Hue, glow: Double, flare: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.color.opacity(min(1, 0.55 * glow)), color.color.opacity(0)],
                                 center: .center, startRadius: size * 0.1, endRadius: size * (0.62 + 0.15 * flare)))
            .frame(width: size * 1.2, height: size * 1.2)
    }

    private func core(_ color: Hue, flare: Double, dim: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [.white, color.light, color.color.opacity(0.9)],
                                 center: .center, startRadius: 0, endRadius: size * 0.21))
            .frame(width: size * 0.40, height: size * 0.40)
            .scaleEffect(1 + 0.12 * flare)
            .opacity(0.75 + 0.25 * dim)
    }

    private func wings(spread: Double, color: Hue) -> some View {
        ZStack {
            wing(side: -1, upper: true, spread: spread, color: color)
            wing(side: 1, upper: true, spread: spread, color: color)
            wing(side: -1, upper: false, spread: spread, color: color)
            wing(side: 1, upper: false, spread: spread, color: color)
        }
    }

    /// One wing, hinged at the core. Turning away (`yaw`) narrows the far
    /// pair, the cube's perspective rule for its eyes.
    private func wing(side: Double, upper: Bool, spread: Double, color: Hue) -> some View {
        let away = max(0, -side * pose.yaw)
        let narrow = 1 - away * 0.45
        let length = size * (upper ? 0.54 : 0.40)
        let width = size * (upper ? 0.26 : 0.19)
        let angle = (upper ? -30.0 : 24.0) * side
        return Ellipse()
            .fill(LinearGradient(colors: [Color.white.opacity(0.85), color.light.opacity(0.35)],
                                 startPoint: .center, endPoint: side < 0 ? .leading : .trailing))
            .overlay(Ellipse().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6))
            .frame(width: length, height: width)
            .scaleEffect(x: spread * narrow, y: 1, anchor: side < 0 ? .trailing : .leading)
            .offset(x: side * length / 2, y: 0)
            .rotationEffect(.degrees(angle), anchor: .center)
            .offset(y: upper ? -size * 0.04 : size * 0.06)
    }
}

/// The cube's colour from what the sessions are doing (Settings → General →
/// Mascot → Status colours): yellow when one needs you, red on a failure,
/// green on a finish, blue at work, white at rest — blended by how many
/// sessions are in each, so the face shows the whole bar at once.
enum CubeTint {
    /// Pale enough that the eyes keep their contrast.
    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .waiting: return Color(red: 1.0, green: 0.84, blue: 0.42)
        case .failed: return Color(red: 1.0, green: 0.56, blue: 0.52)
        case .review: return Color(red: 0.58, green: 0.92, blue: 0.64)
        case .working: return Color(red: 0.66, green: 0.84, blue: 1.0)
        case .idle: return Color(white: 0.94)
        }
    }

    /// What the blend is made of: the live rows, each by what it says now.
    /// A finish already seen is at rest, the way the face (`aggregate`) and
    /// the list read it; a dimmed row says nothing. Without this a seen
    /// finish kept the cube green until its session ran again.
    static func counts(_ snapshot: Registry.Snapshot) -> [Phase: Int] {
        snapshot.ordered.filter(\.isLive).reduce(into: [Phase: Int]()) { counts, row in
            let active = snapshot.layers[row.entity]?.isActive ?? false
            counts[active ? row.phase : .idle, default: 0] += 1
        }
    }

    /// Each phase present and its share, the most urgent first
    /// (`Phase.priority`); `[]` when every session is at rest or there are
    /// none — the cube stays white.
    static func weights(_ counts: [Phase: Int]) -> [(phase: Phase, share: Double)] {
        let active = counts.filter { $0.key != .idle && $0.value > 0 }
        guard !active.isEmpty else { return [] }
        let total = Double(counts.values.reduce(0, +))
        return counts.filter { $0.value > 0 }
            .sorted { $0.key.priority != $1.key.priority ? $0.key.priority > $1.key.priority : $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, Double($0.value) / total) }
    }

    /// A diagonal blend: each colour holds the middle of its share.
    static func linear(_ weights: [(phase: Phase, share: Double)]) -> LinearGradient {
        var stops: [Gradient.Stop] = []
        var start = 0.0
        for weight in weights {
            stops.append(.init(color: color(weight.phase), location: start + weight.share / 2))
            start += weight.share
        }
        if stops.count == 1 { stops.append(.init(color: stops[0].color, location: 1)) }
        return LinearGradient(stops: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Up to four colours in the corners of a mesh, the biggest share also
    /// in the middle.
    static func corners(_ weights: [(phase: Phase, share: Double)]) -> [Color] {
        let byShare = weights.sorted { $0.share > $1.share }.map { color($0.phase) }
        return (0..<4).map { byShare[$0 % byShare.count] }
    }
}

/// The cube's face colour: white, or the sessions' colours when asked.
struct CubeFill: View {
    let counts: [Phase: Int]?

    var body: some View {
        let weights = counts.map(CubeTint.weights) ?? []
        if weights.isEmpty {
            Rectangle().fill(Color.white.opacity(0.92))
        } else if #available(macOS 15.0, *) {
            let c = CubeTint.corners(weights)
            let middle = CubeTint.color(weights.max { $0.share < $1.share }!.phase)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                c[0], c[0], c[1],
                c[2], middle, c[1],
                c[2], c[3], c[3],
            ])
        } else {
            Rectangle().fill(CubeTint.linear(weights))
        }
    }
}

private struct MascotTonesKey: EnvironmentKey { static let defaultValue: [Phase: Int]? = nil }

extension EnvironmentValues {
    /// How many sessions are in each phase, when the cube shows them;
    /// `nil` keeps it white.
    var mascotTones: [Phase: Int]? {
        get { self[MascotTonesKey.self] }
        set { self[MascotTonesKey.self] = newValue }
    }
}
