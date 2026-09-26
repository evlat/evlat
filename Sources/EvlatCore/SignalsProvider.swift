import Foundation

/// The `signal` provider: outside programs' rows, as `POST /signal`
/// left them. In memory only — a restart loses them, and a `watch`'s pulse
/// brings its row back within a minute.
///
/// **A row's life is read, not scheduled.** Each row keeps when it expires,
/// and `currentSignals()` drops what has — so an expired row leaves within one
/// of the app's polls (1.5 s) and nothing new runs to remove it. That is
/// `Registry`'s rule ("no time-driven transitions") carried to the provider,
/// the same shape as `ChatsProvider`'s clock.
///
/// **A finish lives until it is seen, not for its ttl.** `working` and
/// `waiting` live by the sender's ttl — a sender that stops pulsing is gone.
/// A `done` or `failed` is news: it stays until the shell releases it after
/// the user has seen it (`release`), or `ttl: 0` removes it, and the clock
/// ends it only at `finishLifetime` after it finished — the same twelve hours
/// an unseen chat keeps its row. The sent ttl is still validated
/// (`SignalReport`); on a finish it no longer sets the life.
///
/// **One instance per origin**: this Mac's port has one, and each
/// remote machine has its own, fed by its tunnel. A machine's rows are
/// namespaced and carry the machine (`SignalReport.signal`), and are live only
/// while the machine can be heard — the same `LinkClock` its `HooksProvider`
/// reads, so a row dims with the tunnel and does not drive the mascot or
/// `hasLive`. The cap is each instance's own.
///
/// Main queue, like every provider.
public final class SignalsProvider: Provider, Releasable {
    public static let id = SignalReport.provider
    public var id: String { Self.id }

    /// At most this many live ids, per instance. A legitimate sender stays far
    /// below it; a runaway loop minting ids gets a full bar rather than a bar
    /// without end. A machine's instance has its own, so a busy Mac never
    /// silences a server, nor one server another.
    public static let limit = 32

    /// How long an unseen finish keeps its row: one number for every kind
    /// of finish on the bar (`ChatSession.unseenLifetime`).
    public static let finishLifetime = ChatSession.unseenLifetime

    /// What `apply` did with a report. `dropped` is not an error answer: the
    /// cap is known on the main queue, after the listener has already
    /// answered `{}` from its own, so the shell writes it to stderr instead.
    public enum Applied: Equatable {
        case stored
        case cleared
        case dropped(limit: Int)
    }

    private struct Row {
        let report: SignalReport
        /// When the row's current phase began; the row's stamp.
        let phaseStart: Date
        let expiresAt: Date
        /// When the row was last heard — the last `apply` — and lost.
        var mark: LinkClock.Mark
    }

    private var rows: [String: Row] = [:]
    private let now: () -> Date
    /// The remote computer this instance hears through its tunnel; `nil` for
    /// this Mac's own port.
    private let machine: Signal.Machine.Identity?
    private var link = LinkClock()

    /// `machine` makes this the provider for one remote computer. Without it
    /// this is the local provider, unchanged.
    public init(now: @escaping () -> Date = Date.init, machine: Signal.Machine.Identity? = nil) {
        self.now = now
        self.machine = machine
    }

    /// The tunnel came up or went down (`HooksProvider.setLink`, the same
    /// rule). Meaningless on the local instance, and harmless there — its
    /// rows have no machine to be unreachable.
    public func setLink(connected: Bool) {
        let now = now()
        if !connected {
            for key in rows.keys { rows[key]?.mark.lose(at: now) }
        }
        link.setLink(connected: connected, at: now)
    }

    /// Rows held right now, expired ones included until the next read.
    public var count: Int { rows.count }

    public func apply(_ report: SignalReport) -> Applied {
        let now = now()
        // Expired rows go first, so dead rows never hold the cap against a
        // new id until the next poll happens to read them.
        prune(at: now)
        guard report.ttl > 0, let word = report.word else {
            rows.removeValue(forKey: report.id)
            return .cleared
        }
        let previous = rows[report.id]
        // An update of an id already on the bar is never new, so a sender at
        // the cap can still finish what it started.
        if previous == nil, rows.count >= Self.limit { return .dropped(limit: Self.limit) }
        // "Working for 12 min" survives a pulse every minute: the phase's
        // start moves only when the phase does.
        var phaseStart = now
        if let previous, previous.report.word == word { phaseStart = previous.phaseStart }
        // A finish counts from when it finished, so re-sending it does not
        // extend it; live work counts from the last pulse.
        let finished = word == .done || word == .failed
        rows[report.id] = Row(report: report, phaseStart: phaseStart,
                              expiresAt: finished ? phaseStart.addingTimeInterval(Self.finishLifetime)
                                                  : now.addingTimeInterval(TimeInterval(report.ttl)),
                              mark: LinkClock.Mark(heardAt: now))
        return .stored
    }

    public func currentSignals() -> [Signal] {
        prune(at: now())
        return rows.values.compactMap { row in
            row.report.signal(phaseStart: row.phaseStart, machine: machine,
                              dim: machine == nil ? nil : link.disconnected(row.mark))
        }
            .sorted { $0.entity < $1.entity }
    }

    /// Drops the rows that are still the finish that was seen. The key is
    /// built the way the row is (`SignalReport.signal`), so this instance's
    /// namespace — `signal:<id>` here, `signal:<machine>:<id>` for a machine —
    /// is matched by construction and another instance's key never is. A
    /// new phase for the id since then moved the stamp, so it stays.
    public func release(_ finishes: Set<Finish>) {
        rows = rows.filter { _, row in
            guard let finish = row.report.signal(phaseStart: row.phaseStart, machine: machine)
                .flatMap(Finish.init) else { return true }
            return !finishes.contains(finish)
        }
    }

    private func prune(at now: Date) {
        rows = rows.filter { $0.value.expiresAt > now }
    }
}
