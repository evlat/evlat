import Foundation

/// Which of several terminal-side processes a session belongs to, told by
/// start: the one that started nearest the session's own beginning, on this
/// Mac's clock. Shared by a remote session's `ssh` (`Ssh`) and a Docker
/// sandbox's `sbx` client (`Sandbox`), each with its own thresholds — what
/// each measured, not one number for both.
enum StartMatch {
    enum Choice: Equatable {
        case one(Int32)
        /// Several, none told apart: their pids, for "is it one app".
        case ambiguous([Int32])
        case none
    }

    /// The thresholds a caller trusts a start within.
    struct Rule: Equatable {
        /// The farthest a chosen start may be from the reference.
        let nearest: TimeInterval
        /// The nearest any other candidate's start may be.
        let apart: TimeInterval
        /// A lone candidate whose start is farther than this is not chosen
        /// (`.none`): for `ssh` another connection, for a sandbox's client
        /// maybe another session's. `nil` takes a lone candidate as it is.
        let aloneWithin: TimeInterval?
    }

    /// In order: none; one, unless its start says it is someone else's
    /// (`aloneWithin`); without a reference start, ambiguous; else the
    /// nearest within `nearest` while every other is past `apart`. A
    /// candidate whose start cannot be read could be the one: no pick.
    static func choose(_ pids: [Int32], start: Date?, rule: Rule,
                       startedAt: (Int32) -> Date?) -> Choice {
        guard let first = pids.first else { return .none }
        if pids.count == 1 {
            if let limit = rule.aloneWithin, let start, let own = startedAt(first),
               abs(own.timeIntervalSince(start)) > limit {
                return .none
            }
            return .one(first)
        }
        guard let start else { return .ambiguous(pids) }
        let distances = pids.compactMap { pid in
            startedAt(pid).map { (pid: pid, distance: abs($0.timeIntervalSince(start))) }
        }.sorted { $0.distance < $1.distance }
        guard distances.count == pids.count, let best = distances.first, best.distance <= rule.nearest,
              distances.dropFirst().allSatisfy({ $0.distance > rule.apart }) else { return .ambiguous(pids) }
        return .one(best.pid)
    }
}
