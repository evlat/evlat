import Foundation

/// When one remote machine's tunnel came up, and for each of its rows when it
/// was last heard and lost. Shared by the two providers a machine has —
/// `HooksProvider` (its sessions) and `SignalsProvider` (its outside rows,
/// `013`) — so "no connection" means the same thing on both.
///
/// A value, one per provider instance: each provider already learns of the
/// tunnel from the shell (`setLink`), and a shared instance would be a second
/// owner of the same fact. What is shared is the rule.
///
/// Only the `disconnected` half of dimming lives here. `quiet` is a hook
/// session's rule (a `working` turn gone silent) and stays in `HooksProvider`.
struct LinkClock {
    /// When the tunnel last came up; `nil` while it is down.
    private(set) var connectedSince: Date?

    /// The tunnel came up or went down. A repeated "up" keeps the first mark:
    /// confirming a link must not dim rows it has not reached yet. Going down
    /// is also each row's business — the provider marks its rows (`Mark.lose`)
    /// at the same moment.
    mutating func setLink(connected: Bool, at now: Date) {
        if !connected {
            connectedSince = nil
        } else if connectedSince == nil {
            connectedSince = now
        }
    }

    /// One row's side of the link.
    struct Mark: Equatable {
        /// When anything last reached the row.
        private(set) var lastSeen: Date
        /// When the tunnel went down with this row not already lost; cleared
        /// when it is heard again. What a dimmed row's "no connection · 5 min"
        /// counts from.
        private(set) var lostAt: Date?

        init(heardAt now: Date) {
            lastSeen = now
        }

        mutating func hear(at now: Date) {
            lastSeen = now
            lostAt = nil
        }

        /// The first loss is kept: a row not heard from across a reconnect
        /// and a second loss was lost at the first.
        mutating func lose(at now: Date) {
            if lostAt == nil { lostAt = now }
        }
    }

    /// Why a row cannot be taken as current, as far as the link goes: the
    /// tunnel is down, or it came back and the row has not been heard since —
    /// something that ended while it was down told nobody. `nil` otherwise.
    /// A row that never had a link is lost since it was last heard.
    func disconnected(_ mark: Mark) -> Signal.Machine.Dim? {
        guard let connectedSince, mark.lastSeen >= connectedSince else {
            return Signal.Machine.Dim(reason: .disconnected, since: mark.lostAt ?? mark.lastSeen)
        }
        return nil
    }
}
