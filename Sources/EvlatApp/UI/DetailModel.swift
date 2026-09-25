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
    /// The remote computer's name, for the header; `nil` on this Mac. A
    /// remote session's terminal is on that computer, so such a card has no
    /// terminal and no button (`DetailCard.showsButton`).
    public let machine: String?
    /// The row's, so the card's line and the status line's agree.
    public let dim: Signal.Machine.Dim?
    /// What the session is; what the card may do with it is `traits`.
    public let kind: Signal.Kind
    /// The chat's folder, for the footer (`Signal.detail`); `nil` for a session.
    public let folder: String?
    /// An outside job's sender, for the header (`Signal.sender`).
    public let sender: String?
    /// An outside job's one line (`Signal.detail`) — what it is on, or how it
    /// ended ("exit 3"). The sender's words, drawn as data.
    public let note: String?
    /// The row's whole percent, so the card and the status line agree.
    public let progress: Int?
    /// Where the session runs, for the footer and the button. Resolved when
    /// the card comes up and on the click, not on every snapshot; never for
    /// a remote session.
    var host: SessionHost = .notFound

    public init(entity: String, label: String, source: AgentSource?, phase: Phase,
                enteredAt: Date?, activity: Signal.Activity?,
                machine: String? = nil, dim: Signal.Machine.Dim? = nil,
                kind: Signal.Kind = .session, folder: String? = nil,
                sender: String? = nil, note: String? = nil, progress: Int? = nil) {
        self.entity = entity
        self.kind = kind
        self.folder = folder
        self.sender = sender
        self.note = note
        self.progress = progress
        self.label = label
        self.source = source
        self.phase = phase
        self.enteredAt = enteredAt
        self.activity = activity
        self.machine = machine
        self.dim = dim
    }

    var traits: RowTraits { .of(kind) }

    /// Only a session on this Mac has a terminal to look up and go to.
    var hasTerminal: Bool { traits.button == .goToSession && machine == nil }
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
        let words: (folder: String?, note: String?)
        switch row.traits.detail {
        case .folder: words = (signal?.detail, nil)
        case .note: words = (nil, signal?.detail)
        case .none: words = (nil, nil)
        }
        var next = SessionDetail(entity: row.entity, label: row.label, source: row.source,
                                 phase: row.phase, enteredAt: row.enteredAt,
                                 activity: signal?.activity, machine: row.machine, dim: row.dim,
                                 kind: row.kind, folder: words.folder,
                                 sender: row.sender, note: words.note, progress: row.progress)
        if !row.hasTerminal {
            // Evlat's own chat and an outside job have no terminal: nothing
            // to look up, and a "not found" button would be a lie
            // (`DetailCard.showsButton`). Another computer's session: no
            // process here to walk, and a remote pid never reaches this side
            // anyway (`LocalAPI`).
            hostKey = nil
        } else if let key = hostKey, key.entity == row.entity, key.pid == pid, let current = detail {
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
    /// the card now says why. A remote session has no button and goes
    /// nowhere, whatever reaches this.
    @discardableResult
    func go() -> Bool {
        guard var current = detail, current.hasTerminal else { return false }
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
