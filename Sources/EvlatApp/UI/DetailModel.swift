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
    /// The git branch of the session's folder, on a line under the header. Unlike the
    /// row, which draws one only between same-named sessions, the card has
    /// room and says it always. Resolved with `host`, and never for a remote
    /// session: its folder is on its server.
    var branch: String?
    /// A permission this session waits on, to answer from the card
    /// (`ApprovalHook`); `nil` on every other card.
    var approval: ApprovalCard?

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

    /// What the card shows of a held request, and whether its buttons take
    /// a press yet (`AppController.approvalArmDelay`).
    struct ApprovalCard: Equatable {
        let id: String
        let tool: String
        /// The command whole, or the one-line subject: what Allow lets run.
        let text: String?
        /// A subagent asked, not the session itself.
        let fromSubagent: Bool
        /// A question to answer in place of Allow (`AskQuestion`).
        let question: QuestionCard?
        var armed: Bool

        init(_ request: PermissionHook.Request, draft: AskQuestion.Draft? = nil, armed: Bool) {
            id = request.id
            tool = request.tool
            text = request.command ?? request.subject
            fromSubagent = request.agentID != nil
            question = draft.flatMap(QuestionCard.init)
            self.armed = armed
        }

        /// What arms: the request, and which of its questions is up — the
        /// click that answers one must not land on the next one's option
        /// drawn under it.
        var key: String { "\(id)#\(question?.index ?? 0)" }

        /// Is `button` one this card has, live? A faint card has none.
        func takes(_ button: DetailModel.Button) -> Bool {
            guard armed else { return false }
            switch button {
            case .allow: return question == nil
            case .deny: return true
            case .option(let index): return question?.question.options.indices.contains(index) == true
            case .other: return question != nil
            case .send: return question?.canCommit == true
            case .back: return question?.canGoBack == true
            case .go: return false
            }
        }
    }

    /// The question up on the card, and what is picked of it so far.
    struct QuestionCard: Equatable {
        let question: AskQuestion.Question
        /// Which of how many: the terminal's tabs.
        let index: Int
        let count: Int
        let picked: Set<Int>
        let written: String?
        let canCommit: Bool
        let canGoBack: Bool

        init?(_ draft: AskQuestion.Draft) {
            guard let question = draft.current else { return nil }
            self.question = question
            index = draft.index
            count = draft.questions.count
            picked = draft.picked
            written = draft.written
            canCommit = draft.canCommit
            canGoBack = draft.canGoBack
        }

        var isLast: Bool { index == count - 1 }
    }

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

    /// The card's drawn buttons. Clicks are read from geometry
    /// (`AppController.click`), so the pointer's place over them and a press
    /// are told to the card here: a drawn button still answers the pointer.
    enum Button: Hashable {
        case go, allow, deny
        /// A question's option, its "Other…", a multi-select's Next or
        /// Send, and the way back to the question before (`AskQuestion`).
        case option(Int), other, send, back
    }
    /// Written only when it changes: moves arrive at display rate.
    @Published var hovered: Button?
    /// Set for a moment on a press, before what the press does.
    @Published var pressed: Button?

    /// The terminal lookup and the activation, injected so a test neither
    /// walks this machine's processes nor brings an app forward.
    var resolveHost: (Int32?) -> SessionHost = { SessionHost.resolve(pid: $0) }
    var activate: (SessionHost.App) -> Bool = { SessionHost.activate($0) }
    /// The branch of a folder (`GitHead.branch`); injected like the host, so
    /// a test reads no repository. The default reads nothing.
    var resolveBranch: (String) -> String? = { _ in nil }

    /// Which session and pid `detail.host` was resolved for. The snapshot
    /// arrives every poll and on every event; the process walk runs only when
    /// the card comes up for a session (or its pid moves), not at that rate.
    private var hostKey: (entity: String, pid: Int32?)?

    public init() {}

    /// Fed from the same snapshot as the rows, after them. `row` is the
    /// selected session's drawn row; the caller closes the card when there is
    /// none. Whole-value compare is the deadband: the stamp is not in here.
    func update(row: SessionRow, signal: Signal?, approval: SessionDetail.ApprovalCard? = nil) {
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
        next.approval = row.hasTerminal ? approval : nil
        if !row.hasTerminal {
            // Evlat's own chat and an outside job have no terminal: nothing
            // to look up, and a "not found" button would be a lie
            // (`DetailCard.showsButton`). Another computer's session: no
            // process here to walk, and a remote pid never reaches this side
            // anyway (`LocalAPI`).
            hostKey = nil
        } else if let key = hostKey, key.entity == row.entity, key.pid == pid, let current = detail {
            next.host = current.host
            next.branch = current.branch
        } else {
            next.host = resolveHost(pid)
            // The row's, when it already read one: the two never disagree.
            next.branch = row.branch ?? signal?.detail.flatMap(resolveBranch)
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
