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

    public init() {}

    /// Fed from the same snapshot as the rows, after them. `row` is the
    /// selected session's drawn row; the caller closes the card when there is
    /// none. Whole-value compare is the deadband: the stamp is not in here.
    func update(row: SessionRow, signal: Signal?) {
        let next = SessionDetail(entity: row.entity, label: row.label, source: row.source,
                                 phase: row.phase, enteredAt: row.enteredAt,
                                 activity: signal?.activity)
        if detail != next { detail = next }
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
