import Foundation

/// "Remind me if a session waits longer than N minutes" (Settings → General
/// → Waiting reminder). The amber is missed from a fullscreen app or away from
/// the desk; this is the one sound and the one notification Evlat makes, and
/// both are off unless chosen.
///
/// A wait is timed from when this process first saw the row waiting, not from
/// the row's stamp: a hook row's stamp moves on every event, a subagent's
/// included, while the session still waits. Each wait is told once; the row
/// leaving `waiting` — answered, in the terminal or on the card — ends it and
/// re-arms it.
struct WaitingNudge {
    private(set) var since: [String: Date] = [:]
    private var told: Set<String> = []

    struct Change: Equatable {
        /// Rows seen waiting for the first time.
        var began: Set<String> = []
        /// Rows that have just waited `after`.
        var due: Set<String> = []
        /// Told rows that stopped waiting: their notification is taken back.
        var ended: Set<String> = []
    }

    /// Reads the rows waiting now. With `after` nil (off) waits are still
    /// timed, so turning it on mid-wait counts from the wait's start.
    mutating func update(waiting: Set<String>, now: Date, after: TimeInterval?) -> Change {
        var change = Change()
        change.ended = told.subtracting(waiting)
        since = since.filter { waiting.contains($0.key) }
        told.formIntersection(waiting)
        for entity in waiting where since[entity] == nil {
            since[entity] = now
            change.began.insert(entity)
        }
        guard let after else { return change }
        change.due = waiting.filter { !told.contains($0) && now.timeIntervalSince(since[$0]!) >= after }
        told.formUnion(change.due)
        return change
    }

    /// The user was at the wait's tab when it came due (`TabFocus`): it is
    /// timed again from `now`, and comes due once more after the same
    /// minutes. Nothing was posted, so nothing is taken back at its end.
    mutating func rearm(_ entity: String, at now: Date) {
        guard since[entity] != nil else { return }
        told.remove(entity)
        since[entity] = now
    }
}
