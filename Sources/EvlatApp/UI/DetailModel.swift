import Foundation
import EvlatCore

/// What the card draws of the selected session, and nothing else.
public struct SessionDetail: Equatable {
    public let entity: String
    public let label: String
    public let source: AgentSource?
    public let phase: Phase
    /// The row's, so the card's time and the status line's agree.
    public let enteredAt: Date?
    public let activity: Signal.Activity?
    /// Where the session runs, for the footer and the button. Resolved when
    /// the card comes up and on the click, not on every snapshot.
    var host: SessionHost = .notFound

    public init(entity: String, label: String, source: AgentSource?, phase: Phase,
                enteredAt: Date?, activity: Signal.Activity?) {
        self.entity = entity
        self.label = label
        self.source = source
        self.phase = phase
        self.enteredAt = enteredAt
        self.activity = activity
    }
}

/// The card's own model, apart from the column's.
///
/// Apart because the card's facts — the last tool, the count — move on every
/// tool event, and the column must not (`SessionRow` carries none of them).
/// Only the card observes this, and it is written **only while something is
/// selected**, and only for that session: another session's burst never
/// reaches it, and without a card nothing here moves at all.
@MainActor
public final class DetailModel: ObservableObject {
    @Published public private(set) var detail: SessionDetail?

    /// The terminal lookup and the activation, injected so a test neither
    /// walks this machine's processes nor brings an app forward.
    var resolveHost: (Int32?) -> SessionHost = { SessionHost.resolve(pid: $0) }
    var activate: (SessionHost.App) -> Bool = { SessionHost.activate($0) }

    /// Which session and pid `detail.host` was resolved for. The snapshot
    /// arrives every poll and on every event; the process walk runs only when
    /// the card comes up for a session (or its pid moves), not at that rate.
    private var hostKey: (entity: String, pid: Int32?)?

    public init() {}

    /// Fed from the same snapshot as the rows, after them. `row` is the
    /// selected session's drawn row; the caller closes the card when there is
    /// none. Whole-value compare is the deadband: the stamp is not in here.
    func update(row: SessionRow, signal: Signal?) {
        let pid = signal?.activity?.pid
        var next = SessionDetail(entity: row.entity, label: row.label, source: row.source,
                                 phase: row.phase, enteredAt: row.enteredAt,
                                 activity: signal?.activity)
        if let key = hostKey, key.entity == row.entity, key.pid == pid, let current = detail {
            next.host = current.host
        } else {
            next.host = resolveHost(pid)
            hostKey = (row.entity, pid)
        }
        if detail != next { detail = next }
    }

    /// The card went away: the next one resolves afresh, even for the same
    /// session — the app may have quit or come back meanwhile.
    func cardClosed() {
        hostKey = nil
    }

    /// `[Go to session]`: resolved again at the click, then brought forward.
    /// `true` when an app was activated (the caller closes the bar); if not,
    /// the card now says why.
    @discardableResult
    func go() -> Bool {
        guard var current = detail else { return false }
        let host = resolveHost(current.activity?.pid)
        if current.host != host {
            current.host = host
            detail = current
        }
        guard case .app(let app) = host else { return false }
        return activate(app)
    }
}

/// What the card's body shows, picked from the activity's own facts rather
/// than the row's phase: a waiting session's card shows the tool it asks
/// about even if a sibling subagent has run another since, and a finished
/// one its reply. Pure, so the choice is a table in the tests.
enum CardBody: Equatable {
    case tool(Signal.Activity.Tool)
    case reply(String)
    /// Nothing known: the card is its title.
    case none

    static func pick(_ activity: Signal.Activity?) -> CardBody {
        guard let activity else { return .none }
        if let blocking = activity.blockingTool { return .tool(blocking) }
        if let reply = activity.lastReply, !reply.isEmpty { return .reply(reply) }
        if let tool = activity.lastTool { return .tool(tool) }
        return .none
    }
}
