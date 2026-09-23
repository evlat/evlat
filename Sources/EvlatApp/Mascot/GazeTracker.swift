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

    /// A cursor position from somewhere other than the global monitor.
    ///
    /// The monitor only hears events bound for **other** applications, so
    /// over our own panel — exactly where the cursor is while the bar is open
    /// — the gaze would go blind. The panel's tracking area feeds its moves
    /// in here, through the same deadband.
    func observe(_ point: CGPoint) {
        update(to: point)
    }

    /// Below this change in either component the gaze is not republished.
    ///
    /// Without it every `.mouseMoved` event — one per display refresh while the
    /// cursor moves — writes a `@Published` property, which re-runs the whole
    /// bar's body and restarts the 0.38 s spring behind it. In a design whose
    /// premise is "any continuous SwiftUI animation costs ~7% CPU", moving the
    /// mouse would itself be a continuous-animation path. Consecutive samples
    /// from a distant cursor are identical to several decimals, so almost all of
    /// those writes carried no information.
    private let deadband: CGFloat = 0.01

    private func update(to point: CGPoint) {
        let center = anchor()
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()

        let next: CGSize
        if distance > 1 {
            // A distant cursor does not lock the gaze: influence falls off with
            // reach. (An inner clamp used to sit here; it could never change the
            // result, because `min(1, …)` already pins everything nearer than
            // `reach` to 1.)
            let strength = min(1, reach / distance)
            let nx = dx / distance * strength
            // Screen coordinates grow upward, `pitch` grows downward.
            let ny = -dy / distance * strength
            next = CGSize(width: max(-1, min(1, nx)), height: max(-1, min(1, ny)))
        } else {
            next = .zero
        }

        guard abs(next.width - model.gaze.width) > deadband
                || abs(next.height - model.gaze.height) > deadband else { return }
        model.gaze = next
    }
}
