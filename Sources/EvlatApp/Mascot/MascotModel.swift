import SwiftUI
import EvlatCore

/// The state that drives the mascot. `AppController` feeds it, `MascotView`
/// reads it.
@MainActor
public final class MascotModel: ObservableObject {
    /// Aggregate state (`Registry.aggregate`).
    @Published public var phase: Phase = .idle
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
    @Published public var override: Phase?
    /// A file is being dragged over the bar: the mascot
    /// catches it. Not a phase and not `override` — see `MascotPose.catching`.
    /// Written only when it changes; nothing writes it while no drag is on.
    @Published public var catching = false
    /// Whether the mascot is on screen at all: `false` while the body is in
    /// behind the edge (`BodyPresence.mascotShown`). Written by the controller
    /// only, and only when it changes.
    @Published public var isShown = true

    public init() {}

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

    /// Where the caught file is, while one is: the gaze the catching face
    /// turns to. `nil` when nothing is being caught.
    public var caughtGaze: CGSize? { catching ? gaze : nil }
}
