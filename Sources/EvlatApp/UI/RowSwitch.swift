import Foundation

/// On the open list, decides when a cursor on a row means "show me that one".
///
/// The card opens by hover, not by a click (the user's decision: the rows
/// did not read as clickable). A cursor that stays on a row for `dwell` brings
/// its card up; with a card up, one that stays on another row for `delay`
/// takes the card there. Taking it along on every row crossed would make it
/// jump under a hand on its way to the card. Leaving the row first — onto the
/// card, back onto the selected row, off the rows — drops the pending switch.
/// No direction test: the delay alone is the rule.
///
/// `HoverIntent`'s skeleton: one pending target, a new wish cancels the old
/// one, and a late item is dropped by the generation check, not the cancel.
/// A class for the same reason (`AGENTS.md` → the `asyncAfter` trap).
@MainActor
final class RowSwitch {
    /// How long the cursor stays on another row before the card follows it.
    static let delay: TimeInterval = 0.12
    /// How long the cursor stays on a row before its card first comes up.
    /// Counted from the row, not from the bar opening (`HoverIntent.openDelay`).
    static let dwell: TimeInterval = 0.15

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
    /// when it is over no row (the card, the mascot). Without a selection the
    /// wait is `dwell`: the card comes up; with one it is `delay`: it moves.
    func hover(_ row: String?, selected: String?) {
        guard let row, row != selected else {
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
        schedule(selected == nil ? Self.dwell : Self.delay, item)
    }

    func cancel() {
        generation &+= 1
        pendingItem?.cancel()
        pendingItem = nil
        pendingTarget = nil
    }
}
