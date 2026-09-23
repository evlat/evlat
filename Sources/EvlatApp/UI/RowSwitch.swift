import Foundation

/// With the card open, decides when a cursor on another row means "show me
/// that one".
///
/// Taking the card along on every row the cursor crosses would make it jump
/// under a hand on its way to the card, so the cursor has to stay on the new
/// row for `delay`. Leaving it first — onto the card, back onto the selected
/// row, off the rows — drops the pending switch. No direction test: the delay
/// alone is the rule (`discussion.md` → Karar 6).
///
/// `HoverIntent`'s skeleton: one pending target, a new wish cancels the old
/// one, and a late item is dropped by the generation check, not the cancel.
/// A class for the same reason (`AGENTS.md` → the `asyncAfter` trap).
@MainActor
final class RowSwitch {
    /// How long the cursor stays on a row before the card follows it.
    static let delay: TimeInterval = 0.12

    typealias Scheduler = HoverIntent.Scheduler

    /// The row to select, once the cursor has stayed.
    var onSelect: ((String) -> Void)?

    private let schedule: Scheduler
    private var pendingTarget: String?
    private var pendingItem: DispatchWorkItem?
    private var generation = 0

    init(schedule: @escaping Scheduler = { delay, item in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }) {
        self.schedule = schedule
    }

    /// Every move over the bar: `row` is the session under the cursor, `nil`
    /// when it is over no row (the card, the mascot). Without a selection
    /// there is no card to move.
    func hover(_ row: String?, selected: String?) {
        guard let row, let selected, row != selected else {
            cancel()
            return
        }
        // Already on its way: moves arrive at display rate and must not push
        // it out.
        guard row != pendingTarget else { return }

        cancel()
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.pendingTarget = nil
                self.pendingItem = nil
                self.onSelect?(row)
            }
        }
        pendingTarget = row
        pendingItem = item
        schedule(Self.delay, item)
    }

    func cancel() {
        generation &+= 1
        pendingItem?.cancel()
        pendingItem = nil
        pendingTarget = nil
    }
}
