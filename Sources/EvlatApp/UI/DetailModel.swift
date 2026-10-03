import Foundation
import EvlatCore
import EvlatAgents

/// What the card draws of the selected session, and nothing else.
public struct SessionDetail: Equatable {
    public let entity: String
    public let label: String
    public let source: AgentID?
    public let phase: Phase
    /// The row's, so the card's time and the status line's agree.
    public let enteredAt: Date?
    public let activity: Signal.Activity?
    /// The remote computer's name, for the header; `nil` on this Mac. A
    /// remote session's terminal is found through that computer, when its
    /// agent keeps session records (`hasRemoteHost`).
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
    /// the card comes up and on the click, not on every snapshot. For a
    /// remote session, once its server has answered (`searching`).
    var host: SessionHost = .notFound
    /// A remote session whose terminal can be asked of its server: its
    /// agent keeps session records (`Agent.sessionRecords`). Its button is
    /// there once the terminal is found (`DetailCard.showsButton`).
    var hasRemoteHost = false
    /// The server has not answered yet. Drawn as no button, without words.
    var searching = false
    /// A Docker sandbox's session (`SandboxListener`): its terminal is the
    /// `sbx` client it was started from, looked up on this Mac (`Sandbox`),
    /// never asked of a server. Its button is there only for an app found.
    var hasSandboxHost = false
    /// That sandbox has no client in a terminal: the footer says so, and
    /// there is no button.
    var noTerminalOpen = false
    /// The git branch of the session's folder, on a line under the header. Unlike the
    /// row, which draws one only between same-named sessions, the card has
    /// room and says it always. Resolved with `host`, and never for a remote
    /// session: its folder is on its server.
    var branch: String?
    /// A permission this session waits on, to answer from the card
    /// (`ApprovalHook`); `nil` on every other card.
    var approval: ApprovalCard?

    public init(entity: String, label: String, source: AgentID?, phase: Phase,
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

        init(_ request: HeldRequest, draft: AgentQuestion.Draft? = nil, armed: Bool) {
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
        let question: AgentQuestion
        /// Which of how many: the terminal's tabs.
        let index: Int
        let count: Int
        let picked: Set<Int>
        let written: String?
        let canCommit: Bool
        let canGoBack: Bool

        init?(_ draft: AgentQuestion.Draft) {
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

    /// A session on this Mac: its terminal is looked up here, and only its
    /// card answers a permission or names a branch.
    var hasLocalHost: Bool { traits.button == .goToSession && machine == nil }
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

    /// A remote session, as its server is asked about it.
    struct RemoteQuery: Equatable {
        let machineID: String
        let sessionID: String
        let records: SessionRecords
    }
    /// Asks the server (`RemoteHostLookup`); `false` when it cannot be asked
    /// — no live tunnel master — and then `completion` is never called.
    /// The completion comes on the main queue. Injected like the host; the
    /// default asks nobody.
    var findRemote: (RemoteQuery, @escaping (RemoteHost.Reply?) -> Void) -> Bool = { _, _ in false }
    /// The server's answer walked on this Mac (`SessionHost.resolve(remote:)`)
    /// for a machine id.
    var resolveRemote: (RemoteHost.Reply, String) -> SessionHost = { _, _ in .notFound }
    /// A sandbox session's terminal, from its sandbox's name and the
    /// session's start (`Sandbox.resolve`). Injected like the host.
    var resolveSandbox: (String?, Date?) -> Sandbox.Found = { Sandbox.resolve(name: $0, start: $1) }
    /// The agents a remote row's records are looked up in: the catalog.
    var agents: [any Agent] = Agents.all

    /// Which session and pid `detail.host` was resolved for. The snapshot
    /// arrives every poll and on every event; the process walk runs only when
    /// the card comes up for a session (or its pid moves), not at that rate.
    private var hostKey: (entity: String, pid: Int32?)?
    /// The same for a sandbox's session: its name and start. Its start
    /// arrives on a later event than its name, and a row heard before it
    /// is looked up again then.
    private var sandboxKey: (entity: String, name: String?, start: Date?)?

    /// Which remote session `remoteHost` is for, and the server's answer —
    /// the remote fact, asked once and kept for the card's life: the click
    /// walks this Mac again from it, never asks the server again. A call
    /// that could not be made (no live master) is no answer and keeps no key.
    private var remoteKey: (entity: String, machine: String)?
    private var remoteReply: RemoteHost.Reply?
    /// `nil` while the server is asked.
    private var remoteHost: SessionHost?
    /// Moves with every new question, so a late answer to an old card is
    /// dropped.
    private var remoteGeneration = 0

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
        next.approval = row.hasLocalHost ? approval : nil
        // A sandbox's row before the remote question: its agent keeps
        // session records, but they are in the VM, and there is no server
        // to ask — its client is on this Mac.
        let isSandbox = row.traits.button == .goToSession && signal?.machine?.id == SandboxListener.identity.id
        let query = row.hasLocalHost || isSandbox ? nil : remoteQuery(row: row, signal: signal)
        if query == nil { forgetRemote() }
        if !isSandbox { sandboxKey = nil }
        if isSandbox {
            hostKey = nil
            next.hasSandboxHost = true
            let name = signal?.activity?.sandboxName
            let start = signal?.activity?.sessionStartedAt
            if let key = sandboxKey, key.entity == row.entity, key.name == name, key.start == start,
               let current = detail, current.entity == row.entity {
                next.host = current.host
                next.noTerminalOpen = current.noTerminalOpen
            } else {
                Self.apply(resolveSandbox(name, start), to: &next)
                sandboxKey = (row.entity, name, start)
            }
        } else if let query {
            // Another computer's session: a remote pid never reaches this
            // side (`LocalAPI`), so its server is asked where it runs — once
            // per card, not per snapshot.
            hostKey = nil
            next.hasRemoteHost = true
            if remoteKey?.entity != row.entity || remoteKey?.machine != query.machineID {
                ask(query, entity: row.entity)
            }
            next.host = remoteHost ?? .notFound
            next.searching = remoteHost == nil
        } else if !row.hasLocalHost {
            // Evlat's own chat and an outside job have no terminal: nothing
            // to look up, and a "not found" button would be a lie
            // (`DetailCard.showsButton`). A remote session whose agent keeps
            // no records cannot be asked about.
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
        sandboxKey = nil
        forgetRemote()
    }

    /// The question for a remote row: its machine, its session id, and its
    /// agent's records; `nil` for any other row.
    private func remoteQuery(row: SessionRow, signal: Signal?) -> RemoteQuery? {
        guard row.traits.button == .goToSession, let machine = signal?.machine?.id,
              let source = row.source, let records = agents[id: source]?.sessionRecords,
              let session = RemoteHost.sessionID(entity: row.entity, machineID: machine) else { return nil }
        return RemoteQuery(machineID: machine, sessionID: session, records: records)
    }

    private func ask(_ query: RemoteQuery, entity: String) {
        remoteGeneration += 1
        let generation = remoteGeneration
        remoteKey = (entity, query.machineID)
        remoteReply = nil
        remoteHost = nil
        let asked = findRemote(query) { [weak self] reply in
            guard let self, self.remoteGeneration == generation else { return }
            self.answered(reply, machine: query.machineID)
        }
        if !asked {
            // No live tunnel to ask through is no answer: the next snapshot
            // asks again, so a card that came up while it reconnected gets
            // its button once it is back. Not asking costs nothing.
            remoteHost = .notFound
            remoteKey = nil
        }
    }

    /// The server's answer: walked here, and drawn if its card is still up.
    private func answered(_ reply: RemoteHost.Reply?, machine: String) {
        remoteReply = reply
        remoteHost = reply.map { resolveRemote($0, machine) } ?? .notFound
        guard var current = detail, current.entity == remoteKey?.entity, current.hasRemoteHost else { return }
        current.host = remoteHost ?? .notFound
        current.searching = false
        if detail != current { detail = current }
    }

    private static func apply(_ found: Sandbox.Found, to detail: inout SessionDetail) {
        switch found {
        case .host(let host):
            detail.host = host
            detail.noTerminalOpen = false
        case .noTerminal:
            detail.host = .notFound
            detail.noTerminalOpen = true
        }
    }

    private func forgetRemote() {
        guard remoteKey != nil else { return }
        remoteGeneration += 1
        remoteKey = nil
        remoteReply = nil
        remoteHost = nil
    }

    /// `[Go to session]`: resolved again at the click, then brought forward.
    /// `true` when an app was activated (the caller closes the bar); if not,
    /// the card now says why. A remote session walks this Mac again from its
    /// server's kept answer; without one it goes nowhere, whatever reaches
    /// this.
    @discardableResult
    func go() -> Bool {
        guard var current = detail else { return false }
        let host: SessionHost
        if current.hasLocalHost {
            host = resolveHost(current.activity?.pid)
        } else if current.hasSandboxHost {
            var found = current
            Self.apply(resolveSandbox(current.activity?.sandboxName, current.activity?.sessionStartedAt), to: &found)
            host = found.host
            if current.noTerminalOpen != found.noTerminalOpen {
                current.noTerminalOpen = found.noTerminalOpen
                detail = current
            }
        } else if current.hasRemoteHost, let reply = remoteReply, let machine = remoteKey?.machine {
            host = resolveRemote(reply, machine)
            remoteHost = host
        } else {
            return false
        }
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
