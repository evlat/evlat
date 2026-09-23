import Foundation

/// Decides when a cursor over the bar means "show me", and when leaving it
/// means "done".
///
/// Raw enter/exit is too eager both ways: a cursor crossing the screen brushes
/// the bar and would unfold it, and a hand that slips a pixel off the open bar
/// would fold it under itself. So opening waits a moment and closing tolerates
/// a moment — the starting values ROADMAP took from codenotch.
///
/// **One pending decision at a time.** A new wish cancels the old one; an old
/// one that fires anyway is dropped by the generation check. That check is the
/// guard, not the cancel: `DispatchWorkItem.perform()` runs a cancelled item,
/// and a scheduler is free to be late.
///
/// A class, so the closure reads live fields (`AGENTS.md` → the `asyncAfter`
/// trap: a struct's `let` is frozen when the closure is built).
@MainActor
final class HoverIntent {
    /// How long the cursor has to stay before the bar opens.
    static let openDelay: TimeInterval = 0.18
    /// How long the cursor may be gone before the bar closes.
    static let closeTolerance: TimeInterval = 0.25

    typealias Scheduler = (TimeInterval, DispatchWorkItem) -> Void

    private(set) var isOpen = false
    /// Called once per real change, after `isOpen` is written.
    var onChange: ((Bool) -> Void)?

    private let schedule: Scheduler
    /// The state the pending item will set, or nil when nothing is pending.
    private var pendingTarget: Bool?
    private var pendingItem: DispatchWorkItem?
    private var generation = 0

    init(schedule: @escaping Scheduler = { delay, item in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }) {
        self.schedule = schedule
    }

    /// Also the answer to every move inside the bar: moves arrive at display
    /// rate and each one says "inside", which must neither restart the
    /// opening delay nor leave a pending close standing.
    func pointerEntered() { want(true) }

    func pointerExited() { want(false) }

    /// Close at once: `[Go to session]` has sent the user elsewhere. Through
    /// the intent for the same reason as `openNow` — a closed bar the intent
    /// believed open would ignore the next enter.
    func closeNow() {
        guard isOpen else { return }
        cancelPending()
        isOpen = false
        onChange?(false)
    }

    /// Open at once: `EVLAT_SELECT` at launch does not wait out the
    /// opening delay. Through the intent, not around it — an open bar the
    /// intent believed closed would ignore the next leave.
    ///
    /// On an open bar it does nothing, and in particular it leaves a pending
    /// close alone: a row switch firing just after the cursor left selects
    /// through here, and cancelling that close would strand the bar open with
    /// no leave left to come.
    func openNow() {
        guard !isOpen else { return }
        cancelPending()
        isOpen = true
        onChange?(true)
    }

    private func want(_ open: Bool) {
        if open == isOpen {
            // Already there: whatever was pending was the other way (a close
            // inside the tolerance, or a pass that left before opening).
            cancelPending()
            return
        }
        // Already on its way: rescheduling would push it out on every move.
        guard pendingTarget != open else { return }

        cancelPending()
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.pendingTarget = nil
                self.pendingItem = nil
                self.isOpen = open
                self.onChange?(open)
            }
        }
        pendingTarget = open
        pendingItem = item
        schedule(open ? Self.openDelay : Self.closeTolerance, item)
    }

    private func cancelPending() {
        generation &+= 1
        pendingItem?.cancel()
        pendingItem = nil
        pendingTarget = nil
    }
}
