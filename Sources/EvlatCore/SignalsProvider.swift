import Foundation

/// The `signal` provider (`012`): outside programs' rows, as `POST /signal`
/// left them. In memory only — a restart loses them, and a `watch`'s pulse
/// brings its row back within a minute.
///
/// **A row's life is read, not scheduled.** Each row keeps when it expires,
/// and `currentSignals()` drops what has — so an expired row leaves within one
/// of the app's polls (1.5 s) and nothing new runs to remove it. That is
/// `Registry`'s rule ("no time-driven transitions") carried to the provider,
/// the same shape as `ChatsProvider`'s clock.
///
/// Main queue, like every provider.
public final class SignalsProvider: Provider {
    public static let id = SignalReport.provider
    public var id: String { Self.id }

    /// At most this many live ids. A legitimate sender stays far below it; a
    /// runaway loop minting ids gets a full bar rather than a bar without end.
    public static let limit = 32

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
    }

    private var rows: [String: Row] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
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
        rows[report.id] = Row(report: report, phaseStart: phaseStart,
                              expiresAt: now.addingTimeInterval(TimeInterval(report.ttl)))
        return .stored
    }

    public func currentSignals() -> [Signal] {
        prune(at: now())
        return rows.values.compactMap { $0.report.signal(phaseStart: $0.phaseStart) }
            .sorted { $0.entity < $1.entity }
    }

    private func prune(at now: Date) {
        rows = rows.filter { $0.value.expiresAt > now }
    }
}
