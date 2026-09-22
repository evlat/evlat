import AppKit

/// Follows the cursor and feeds the mascot's gaze direction.
///
/// **Permission boundary:** the global monitor listens for mouse movement only.
/// Accessibility permission is required for keyboard events, not for the cursor
/// position. If this ever starts asking for one, that is an architectural
/// decision — `proje.md` → permission-free design.
@MainActor
final class GazeTracker {
    private var monitor: Any?
    private let model: MascotModel
    /// The mascot's centre on screen; re-read whenever the panel moves.
    private var anchor: () -> CGPoint

    /// Beyond this radius the cursor counts as far away and the gaze relaxes.
    /// A mascot locked onto a cursor at the other end of the screen looks
    /// anxious.
    private let reach: CGFloat = 520

    init(model: MascotModel, anchor: @escaping () -> CGPoint) {
        self.model = model
        self.anchor = anchor
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.update(to: NSEvent.mouseLocation) }
        }
        update(to: NSEvent.mouseLocation)
    }

    /// Released when the panel hides or the app quits: listening for events on
    /// behalf of an invisible mascot is wasted work.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func update(to point: CGPoint) {
        let center = anchor()
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()

        guard distance > 1 else { model.gaze = .zero; return }
        // A distant cursor does not lock the gaze: influence falls off with reach.
        let strength = min(1, reach / max(distance, reach * 0.35))
        let nx = dx / distance * strength
        // Screen coordinates grow upward, `pitch` grows downward.
        let ny = -dy / distance * strength
        model.gaze = CGSize(width: max(-1, min(1, nx)), height: max(-1, min(1, ny)))
    }
}
