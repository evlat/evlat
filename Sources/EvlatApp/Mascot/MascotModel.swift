import SwiftUI
import EvlatCore

/// The state that drives the mascot. `AppController` feeds it, `MascotView`
/// reads it.
@MainActor
public final class MascotModel: ObservableObject {
    /// Aggregate state (`Registry.aggregate`).
    @Published public var phase: Phase = .idle { didSet { notePhase() } }
    /// Whether any session is live. **Not a phase**, a render condition: while
    /// false the mascot's looping animations leave the view tree and drawing
    /// stops.
    @Published public var hasLive: Bool = false
    /// Direction of the cursor relative to the mascot, −1…1. Written by
    /// `GazeTracker`.
    @Published public var gaze: CGSize = .zero
    /// A phase forced by hand so it can be looked at (status-menu item).
    /// `waiting` and `failed` cannot be produced without hooks, so
    /// there would otherwise be no way to see those two expressions.
    @Published public var override: Phase? { didSet { notePhase() } }
    /// A file is being dragged over the bar: the mascot
    /// catches it. Not a phase and not `override` — see `MascotPose.catching`.
    /// Written only when it changes; nothing writes it while no drag is on.
    @Published public var catching = false
    /// Whether the mascot is on screen at all: `false` while the body is in
    /// behind the edge (`BodyPresence.mascotShown`). Written by the controller
    /// only, and only when it changes.
    @Published public var isShown = true
    /// Who is drawn. One character ships today; the model holds it so that a
    /// choice, when there is one, is a write here and nothing else.
    @Published var character = MascotCharacters.default
    /// The sessions behind the face, for a character whose behavior reads
    /// them (`MascotContext`). Written through `hear(_:)` only.
    @Published private(set) var sessions = MascotContext.Sessions()
    /// When the drawn phase last changed, by this Mac's clock: what a
    /// character's rules count "how long" from. Not published — it changes
    /// only with the phase, which redraws anyway.
    private(set) var phaseSince: Date
    private var notedPhase: Phase = .idle
    private let now: () -> Date

    public convenience init() { self.init(now: Date.init) }

    init(now: @escaping () -> Date) {
        self.now = now
        phaseSince = now()
    }

    public var effectivePhase: Phase { override ?? phase }

    /// Whether the clip layer belongs in the view tree.
    ///
    /// **Not** `hasLive` alone. A forced phase is written to `override` and
    /// nothing else, so while no session was live the status menu used to put a
    /// motionless cube on screen — the one state you cannot inspect is the one
    /// the menu item exists to let you inspect.
    ///
    /// Catching does not wake it: the caught face is drawn by
    /// whichever branch is on screen (`caughtGaze`), so the eyes spring open
    /// on the body already there. Waking would swap the asleep body for the
    /// clip player and the face would crossfade between two views instead.
    ///
    /// An unseen mascot sleeps: a clip walking behind the edge would produce
    /// frames nobody sees.
    public var isAwake: Bool { (hasLive || override != nil) && isShown }

    /// Takes the sessions' counts from a snapshot — only while the character
    /// has rules to read them, and only when they changed. A character
    /// without rules is not even counted for, so the face redraws exactly as
    /// often as before.
    func hear(_ snapshot: Registry.Snapshot) {
        guard !character.behavior.isEmpty else { return }
        hear(MascotContext.Sessions(snapshot))
    }

    func hear(_ sessions: MascotContext.Sessions) {
        guard !character.behavior.isEmpty, sessions != self.sessions else { return }
        self.sessions = sessions
    }

    private func notePhase() {
        guard effectivePhase != notedPhase else { return }
        notedPhase = effectivePhase
        phaseSince = now()
    }

    /// Where the caught file is, while one is: the gaze the catching face
    /// turns to. `nil` when nothing is being caught.
    public var caughtGaze: CGSize? { catching ? gaze : nil }
}
