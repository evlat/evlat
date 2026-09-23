import Foundation

/// How far the open list is scrolled, in points from its top.
///
/// Its own model, not a field of `BarState`: `BarBody` observes that one, and
/// with it the mascot would be re-evaluated on every scroll event. Only the
/// list's container and the card's placing observe this.
@MainActor
final class ListScroll: ObservableObject {
    @Published private(set) var offset: CGFloat = 0

    /// Writes `value` held to `0...max`, and only when that moves the offset
    /// — scroll events arrive at display rate, and a push against a bound
    /// must publish nothing. `true` when it moved.
    @discardableResult
    func set(_ value: CGFloat, max: CGFloat) -> Bool {
        let held = min(Swift.max(0, value), Swift.max(0, max))
        guard held != offset else { return false }
        offset = held
        return true
    }
}
