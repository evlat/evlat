import Foundation
import SwiftUI
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
    /// The question up was reached by going back: the next one slides in
    /// from the leading side (`BarMotion.questionTransition`). Read from the
    /// step between two cards of the same request, kept while it stands.
    var questionBack = false
    /// The chat is switched on: a chat's card has its `[Back to chat]`
    /// (`DetailCard.showsButton`). Off, the balloon would not open.
    var opensChat = true

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

    /// What the card shows of a held request. Its buttons take a press as
    /// soon as they are drawn: the pause that once held them after the card
    /// or a question came up read as a card not answering (user's decision).
    struct ApprovalCard: Equatable {
        let id: String
        let tool: String
        /// The command whole, or the one-line subject: what Allow lets run.
        let text: String?
        /// A subagent asked, not the session itself.
        let fromSubagent: Bool
        /// The asking agent's name key (`AgentDisplay.nameKey`): the card
        /// says who asks. Every held request has its route's agent
        /// (`HeldRequest.source`); one without is never held.
        let agentNameKey: String?
        /// A question to answer in place of Allow (`AskQuestion`).
        let question: QuestionCard?

        init(_ request: HeldRequest, draft: AgentQuestion.Draft? = nil) {
            id = request.id
            tool = request.tool
            text = request.command ?? request.subject
            fromSubagent = request.subagent != nil
            agentNameKey = request.source?.agent.display.nameKey
            question = draft.flatMap(QuestionCard.init)
        }

        /// Is `button` one this card has, live?
        func takes(_ button: DetailModel.Button) -> Bool {
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
        /// Every question's tab, and whether it has an answer: the card's
        /// row of them, the one up lit.
        let steps: [Step]

        struct Step: Equatable {
            let header: String?
            let answered: Bool
        }

        init?(_ draft: AgentQuestion.Draft) {
            guard let question = draft.current else { return nil }
            self.question = question
            index = draft.index
            count = draft.questions.count
            picked = draft.picked
            written = draft.written
            canCommit = draft.canCommit
            canGoBack = draft.canGoBack
            steps = zip(draft.questions, draft.choices).map { question, choice in
                Step(header: question.header, answered: !choice.picked.isEmpty || choice.written != nil)
            }
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
    /// Has the server select the session's herdr pane
    /// (`RemoteHostLookup.select`); `false` when it cannot be asked, and
    /// then `completion` is never called. The completion comes on the main
    /// queue once the server answered, whatever it said. Injected like the
    /// host; the default asks nobody.
    var selectRemote: (RemoteQuery, @escaping () -> Void) -> Bool = { _, _ in false }
    /// The longest the window waits for that selection: over a live master
    /// the lookup took 0.19–0.25 s; a server slower than this still gets
    /// its window, on whatever pane it shows.
    static let selectWait: TimeInterval = 1
    /// Runs the closure after the wait, on the main queue. Injected so a
    /// test ends the wait by hand.
    var waitForSelect: (TimeInterval, @escaping () -> Void) -> Void = { wait, then in
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: DispatchWorkItem(block: then))
    }
    /// A sandbox session's terminal, from its sandbox's name, the session's
    /// start and the starts of that sandbox's sessions before it, whose
    /// clients are theirs (`Sandbox.resolve`). Injected like the host.
    var resolveSandbox: (String?, Date?, [Date]) -> Sandbox.Found = {
        Sandbox.resolve(name: $0, start: $1, earlier: $2)
    }
    /// The agents a remote row's records are looked up in: the catalog.
    var agents: [any Agent] = Agents.all

    /// Which session and pid `detail.host` was resolved for. The snapshot
    /// arrives every poll and on every event; the process walk runs only when
    /// the card comes up for a session (or its pid moves), not at that rate.
    private var hostKey: (entity: String, pid: Int32?)?
    /// The same for a sandbox's session: its name, its start and the
    /// earlier sessions' starts. Its start arrives on a later event than its
    /// name, and a row heard before it is looked up again then; so is one
    /// whose sandbox gains or loses an earlier session.
    private var sandboxKey: (entity: String, name: String?, start: Date?, earlier: [Date])?

    /// Which remote session `remoteHost` is for, and the server's answer —
    /// the remote fact, asked once and kept for the card's life: the click
    /// walks this Mac again from it, never asks the server again. A call
    /// that could not be made (no live master) is no answer and keeps no key.
    private var remoteKey: (entity: String, query: RemoteQuery)?
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
    /// `signals` is the snapshot's: a sandbox's session is matched with the
    /// other sessions of its sandbox (`Sandbox.earlierStarts`).
    func update(row: SessionRow, signal: Signal?, approval: SessionDetail.ApprovalCard? = nil,
                signals: [Signal] = [], chatEnabled: Bool = true) {
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
        // A server's session is answered from its card like this Mac's: the
        // caller found the request by the row's machine and session.
        next.approval = approval
        next.opensChat = chatEnabled
        // A sandbox's row before the remote question: its agent keeps
        // session records, but they are in the VM, and there is no server
        // to ask — its client is on this Mac.
        let isSandbox = row.traits.button == .goToSession && signal?.machine?.id == SandboxListener.identity.id
        let query = row.hasLocalHost || isSandbox ? nil : signal.flatMap { RemoteQuery(signal: $0, agents: agents) }
        if query == nil { forgetRemote() }
        if !isSandbox { sandboxKey = nil }
        if isSandbox {
            hostKey = nil
            next.hasSandboxHost = true
            let name = signal?.activity?.sandboxName
            let start = signal?.activity?.sessionStartedAt
            let earlier = signal.map { Sandbox.earlierStarts(of: $0, in: signals) } ?? []
            if let key = sandboxKey, key.entity == row.entity, key.name == name, key.start == start,
               key.earlier == earlier, let current = detail, current.entity == row.entity {
                next.host = current.host
                next.noTerminalOpen = current.noTerminalOpen
            } else {
                Self.apply(resolveSandbox(name, start, earlier), to: &next)
                sandboxKey = (row.entity, name, start, earlier)
            }
        } else if let query {
            // Another computer's session: a remote pid never reaches this
            // side (`LocalAPI`), so its server is asked where it runs — once
            // per card, not per snapshot.
            hostKey = nil
            next.hasRemoteHost = true
            if remoteKey?.entity != row.entity || remoteKey?.query.machineID != query.machineID {
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
        var stepped = false
        if let before = detail?.approval, let now = next.approval, before.id == now.id,
           let from = before.question?.index, let to = now.question?.index {
            next.questionBack = to == from ? detail?.questionBack ?? false : to < from
            stepped = to != from
        }
        guard detail != next else { return }
        // A step between questions is written inside the animation, so all
        // it changes moves on one curve: the card's height and place too,
        // which the layout placing it sets — an animation hung on the card
        // reached only its inside, and the card jumped to its new height.
        if stepped {
            withAnimation(BarMotion.questionStep) { detail = next }
        } else {
            detail = next
        }
    }

    /// The card went away: the next one resolves afresh, even for the same
    /// session — the app may have quit or come back meanwhile.
    func cardClosed() {
        hostKey = nil
        sandboxKey = nil
        forgetRemote()
    }

    private func ask(_ query: RemoteQuery, entity: String) {
        remoteGeneration += 1
        let generation = remoteGeneration
        remoteKey = (entity, query)
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
    /// this. One in a herdr pane on its server is the exception to "asked
    /// once": the server is asked to select the pane, found again there now,
    /// and the window comes when it answers or after `selectWait`, whichever
    /// is first — `true` then means the app was found and is on its way.
    @discardableResult
    func go() -> Bool {
        guard var current = detail else { return false }
        let host: SessionHost
        if current.hasLocalHost {
            host = resolveHost(current.activity?.pid)
        } else if current.hasSandboxHost {
            var found = current
            Self.apply(resolveSandbox(current.activity?.sandboxName, current.activity?.sessionStartedAt,
                                      sandboxKey?.earlier ?? []), to: &found)
            host = found.host
            if current.noTerminalOpen != found.noTerminalOpen {
                current.noTerminalOpen = found.noTerminalOpen
                detail = current
            }
        } else if current.hasRemoteHost, let reply = remoteReply, let query = remoteKey?.query {
            host = resolveRemote(reply, query.machineID)
            remoteHost = host
        } else {
            return false
        }
        if current.host != host {
            current.host = host
            detail = current
        }
        guard case .app(let app) = host else { return false }
        // Only a pane the card promised: one herdr would not select is not
        // waited for.
        if app.serverPane == .selectable, let query = remoteKey?.query, let reply = remoteReply {
            return selectThenActivate(app, query, reply)
        }
        return activate(app)
    }

    /// The server's pane first, then the window — once, whichever of the
    /// answer and the wait comes first, and whatever the answer. Nothing
    /// here reads the card: the caller closes it at once.
    private func selectThenActivate(_ app: SessionHost.App, _ query: RemoteQuery,
                                    _ reply: RemoteHost.Reply) -> Bool {
        let activate = self.activate
        let resolveRemote = self.resolveRemote
        var done = false
        let bring = {
            guard !done else { return }
            done = true
            // A herdr pane on this Mac, on the way to the tunnel, is selected
            // under the click's herdr deadline (`HerdrSocket.session`), which
            // the wait for the server has used up: walked again now, it is
            // found and selected under a deadline of its own.
            if case .pane = app.herdr, case .app(let now) = resolveRemote(reply, query.machineID) {
                _ = activate(now)
            } else {
                _ = activate(app)
            }
        }
        guard selectRemote(query, bring) else { return activate(app) }
        waitForSelect(Self.selectWait, bring)
        return true
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

extension DetailModel.RemoteQuery {
    /// The question for a remote row — the card's and the news's one rule
    /// (`AppController.askIsAtTab`): a session on a machine, its agent's
    /// records (`Agent.sessionRecords`) and its session id; `nil` for any
    /// other row, a Docker sandbox's among them, which has no server to ask.
    init?(signal: Signal, agents: [any Agent]) {
        guard signal.kind == .session, let machine = signal.machine?.id, machine != SandboxListener.identity.id,
              let source = signal.source, let records = agents[id: source]?.sessionRecords,
              let session = RemoteHost.sessionID(entity: signal.entity, machineID: machine) else { return nil }
        self.init(machineID: machine, sessionID: session, records: records)
    }
}
