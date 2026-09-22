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
    /// `waiting` and `failed` cannot be produced without hooks (`002`), so
    /// there would otherwise be no way to see those two expressions.
    @Published public var override: Phase?

    public init() {}

    public var effectivePhase: Phase { override ?? phase }
}
