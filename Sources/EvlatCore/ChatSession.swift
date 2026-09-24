import Foundation

/// One chat's state machine (`011`): the user's prompts and the stream's
/// events in; the messages the balloon draws and the bar's `Signal` out.
///
/// **The phase comes from the stream, not from hooks** (Karar 3): an Evlat on
/// another port never hears the turn's hooks, it always hears its stdout.
/// `working` from the prompt to the `result`; `review` when the turn
/// finished (or the user stopped it); `failed` when it ended in an error,
/// died without a result or never started; `waiting` while a permission
/// card is open (`phase-3`), back to `working` when the last one is
/// answered. No `Phase` value is added.
///
/// Pure and a value: time is handed in, the process is the shell's.
public struct ChatSession: Equatable {
    /// `Signal.provider` of every chat row. Not an `AgentSource`: that would
    /// ask for a hook route of its own (`testEverySourceHasItsOwnRoute`).
    public static let provider = "evlat"

    /// The row's word for a turn the user stopped.
    public static let stoppedWord = "stopped"

    /// Evlat's id for the chat, a UUID; `entity` is built from it.
    public let id: String
    /// Claude's session id, chosen by Evlat (`--session-id`).
    public let sessionID: String
    /// The working directory every turn runs in.
    public var folder: String
    /// Is `folder` Evlat's own `chats/<id>/` rather than the user's?
    public var isWorkspace: Bool
    /// `nil` until one is given (`phase-5`, from the first reply); the row
    /// falls back to the first prompt.
    public var title: String?

    public private(set) var messages: [Message] = []
    /// `nil` before the first prompt: such a chat has no row.
    public private(set) var phase: Phase?
    /// The last word that set the phase — the row's `rawStatus`.
    public private(set) var word: String?
    /// When the phase was set: the row's stamp.
    public private(set) var since: Date?
    public private(set) var failure: Failure?
    public private(set) var isRunning = false
    /// Has any turn reached Claude? Until one has, there is no session to
    /// resume and the next turn names it again.
    public private(set) var hasStarted = false
    public private(set) var stopRequested = false
    public private(set) var lastTool: Signal.Activity.Tool?
    public private(set) var toolCount = 0
    public private(set) var lastReply: String?
    /// Did this turn's `result` arrive? An exit without one is a crash.
    private var resultSeen = false
    /// Is the last message a reply still being streamed? Deltas append to
    /// it and the finished `assistant` text replaces it.
    private var replyOpen = false

    public enum Message: Equatable {
        case user(text: String, attachments: [String])
        case reply(String)
        /// One tool call on one line; `failed` is `nil` until its result,
        /// `output` the first line of what it said.
        case tool(id: String, name: String, subject: String?, failed: Bool?, output: String?)
        /// A permission request, open until answered.
        case permission(PermissionCard)
    }

    /// One permission request on the balloon (`R6`).
    public struct PermissionCard: Equatable {
        /// The request's id: the held connection's key.
        public let id: String
        public let tool: String
        public let subject: String?
        /// What "always" would grant: the suggested rules…
        public let rules: [PermissionHook.Rule]
        /// …and folders outside the chat's. With a folder the card offers
        /// access to it rather than a rule.
        public let directories: [String]
        /// `nil` while the card waits for the user.
        public var outcome: Outcome?

        public enum Outcome: Equatable {
            case allowed
            /// Allowed, with the rules or folders kept for the chat.
            case allowedAlways
            case denied
            /// The request went away unanswered: Claude's time ran out, the
            /// turn ended or was stopped.
            case expired
        }

        public var isOpen: Bool { outcome == nil }
        /// Is there anything "always" would grant?
        public var offersAlways: Bool { !rules.isEmpty || !directories.isEmpty }
    }

    /// Why a chat failed. Reasons, not text: the balloon words them from the
    /// catalogue (`phase-2`). `detail` is the process's own line.
    public enum Failure: Equatable {
        /// No `claude` was found (`EVLAT_CLAUDE`, then the login shell's `PATH`).
        case noBinary
        /// The process could not be started.
        case launch(String)
        /// The process ended without a result.
        case exited(status: Int32, detail: String?)
        /// The turn ended with an error result.
        case result(subtype: String, text: String?)
        /// The turn was running when Evlat went away (found at launch).
        case interrupted
        /// Evlat's loopback listener is not bound, so no permission request
        /// could reach it: the turn is not started rather than having every
        /// request silently denied (another Evlat holding the port).
        case noListener(String)
    }

    /// `hasStarted` is the index's word for a chat read back at launch.
    public init(id: String, sessionID: String, folder: String, isWorkspace: Bool, title: String? = nil,
                hasStarted: Bool = false) {
        self.hasStarted = hasStarted
        self.id = id
        self.sessionID = sessionID
        self.folder = folder
        self.isWorkspace = isWorkspace
        self.title = title
    }

    /// A prompt. Returns the turn to start, or `nil` while one is running.
    /// The chat's granted directories and rules ride along (`phase-3`).
    public mutating func begin(prompt: String, attachments: [String], at now: Date,
                               addDirectories: [String] = [], allowedTools: [String] = []) -> ClaudeInvocation? {
        guard !isRunning else { return nil }
        messages.append(.user(text: prompt, attachments: attachments))
        isRunning = true
        resultSeen = false
        stopRequested = false
        replyOpen = false
        failure = nil
        lastTool = nil
        toolCount = 0
        lastReply = nil
        set(.working, word: "send", at: now)
        return ClaudeInvocation.turn(chatID: id, sessionID: sessionID, resume: hasStarted,
                                     prompt: prompt, attachments: attachments, directory: folder,
                                     addDirectories: addDirectories, allowedTools: allowedTools)
    }

    /// One stream event of the running turn.
    public mutating func apply(_ event: ChatStream.Event, at now: Date) {
        switch event {
        case .started:
            hasStarted = true
        case .textDelta(let text):
            if replyOpen, case .reply(let sofar)? = messages.last {
                messages[messages.count - 1] = .reply(sofar + text)
            } else {
                messages.append(.reply(text))
                replyOpen = true
            }
        case .assistant(let text, let tools):
            if let text {
                if replyOpen, case .reply? = messages.last {
                    messages[messages.count - 1] = .reply(text)
                } else {
                    messages.append(.reply(text))
                }
            }
            // A finished message closes the reply: the next deltas are the
            // next block's, after a tool or in a later message.
            replyOpen = false
            for tool in tools {
                messages.append(.tool(id: tool.id, name: tool.name, subject: tool.subject, failed: nil,
                                      output: nil))
                lastTool = Signal.Activity.Tool(name: tool.name, subject: tool.subject)
                toolCount += 1
            }
        case .toolResult(let id, let isError, let output):
            if let index = messages.lastIndex(where: {
                if case .tool(id, _, _, _, _) = $0 { return true }
                return false
            }), case .tool(_, let name, let subject, _, _) = messages[index] {
                messages[index] = .tool(id: id, name: name, subject: subject, failed: isError, output: output)
            }
        case .result(let result):
            resultSeen = true
            replyOpen = false
            lastReply = HookEvent.firstParagraph(result.text)
            if stopRequested {
                set(.review, word: Self.stoppedWord, at: now)
            } else if result.isError || result.subtype != "success" {
                failure = .result(subtype: result.subtype, text: result.text)
                set(.failed, word: "result/\(result.subtype)", at: now)
            } else {
                set(.review, word: "result/\(result.subtype)", at: now)
            }
        case .permissionDenied:
            break
        }
    }

    // MARK: - Permission

    /// The requests still waiting for the user, oldest first.
    public var openRequests: [String] {
        messages.compactMap { if case .permission(let card) = $0, card.isOpen { return card.id } else { return nil } }
    }

    /// A permission request of the running turn: a card, and the chat
    /// `waiting`. `false` when no turn runs — the caller denies it.
    @discardableResult
    public mutating func ask(_ request: PermissionHook.Request, at now: Date) -> Bool {
        guard isRunning, !stopRequested, card(request.id) == nil else { return false }
        replyOpen = false
        messages.append(.permission(PermissionCard(id: request.id, tool: request.tool, subject: request.subject,
                                                   rules: request.rules, directories: request.directories)))
        // A second card while one is open keeps the wait's start: the bar
        // counts how long the chat has been waiting, not since the last card.
        if phase != .waiting { set(.waiting, word: "permission", at: now) }
        return true
    }

    /// The user's answer to one card: the decision to send, or `nil` when
    /// that card is not open (answered, expired, never seen). `always` grants
    /// the card's rules and folders for this session; the caller keeps them
    /// for the chat's later turns.
    public mutating func answer(_ id: String, _ decision: Action.Decision, at now: Date) -> PermissionHook.Decision? {
        guard let index = cardIndex(id), case .permission(var card) = messages[index], card.isOpen else { return nil }
        let sent: PermissionHook.Decision
        switch decision {
        case .allow:
            card.outcome = .allowed
            sent = .allow(rules: [], directories: [])
        case .allowAlways:
            card.outcome = .allowedAlways
            sent = .allow(rules: card.rules, directories: card.directories)
        case .deny:
            card.outcome = .denied
            sent = .deny(interrupt: false)
        }
        messages[index] = .permission(card)
        resume(at: now)
        return sent
    }

    /// The request went away unanswered (the connection closed). A card
    /// already answered expires too: the listener reports only a request it
    /// never wrote an answer to, so an answer given as the connection closed
    /// never reached Claude and the card must not say it did.
    public mutating func expire(_ id: String, at now: Date) {
        guard let index = cardIndex(id), case .permission(var card) = messages[index],
              card.outcome != .expired else { return }
        card.outcome = .expired
        messages[index] = .permission(card)
        resume(at: now)
    }

    /// Back to `working` once no card is open — while the turn still runs.
    private mutating func resume(at now: Date) {
        guard phase == .waiting, openRequests.isEmpty, isRunning else { return }
        set(.working, word: "answer", at: now)
    }

    private func card(_ id: String) -> PermissionCard? {
        guard let index = cardIndex(id), case .permission(let card) = messages[index] else { return nil }
        return card
    }

    private func cardIndex(_ id: String) -> Int? {
        messages.lastIndex { if case .permission(let card) = $0 { return card.id == id } else { return false } }
    }

    /// Every open card marked `expired`, with no phase of its own: the turn's
    /// end sets that.
    private mutating func expireAll() {
        for index in messages.indices {
            if case .permission(var card) = messages[index], card.isOpen {
                card.outcome = .expired
                messages[index] = .permission(card)
            }
        }
    }

    /// The process ended. After a result this changes nothing; without one
    /// the turn crashed — unless the user asked it to stop.
    public mutating func ended(status: Int32, stderr: String, at now: Date) {
        guard isRunning else { return }
        isRunning = false
        replyOpen = false
        // No one is left to ask: the process that held them is gone.
        expireAll()
        guard !resultSeen else { return }
        if stopRequested {
            set(.review, word: Self.stoppedWord, at: now)
            return
        }
        let detail = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        failure = .exited(status: status, detail: detail)
        set(.failed, word: "exit/\(status)", at: now)
    }

    /// The user asked the running turn to end. Returns the open requests,
    /// each now denied — the caller answers them so (with `interrupt`) —
    /// or `nil` when nothing runs.
    @discardableResult
    public mutating func requestStop(at now: Date) -> [String]? {
        guard isRunning else { return nil }
        stopRequested = true
        let open = openRequests
        for index in messages.indices {
            if case .permission(var card) = messages[index], card.isOpen {
                card.outcome = .denied
                messages[index] = .permission(card)
            }
        }
        // Still running until the process says so; no longer waiting on
        // the user.
        if phase == .waiting { set(.working, word: Self.stoppedWord, at: now) }
        return open
    }

    /// A failure with no process behind it: no binary, a launch that did not
    /// happen, a turn found interrupted at launch.
    public mutating func fail(_ reason: Failure, at now: Date) {
        isRunning = false
        replyOpen = false
        expireAll()
        failure = reason
        set(.failed, word: "evlat/\(reason.word)", at: now)
    }

    private mutating func set(_ phase: Phase, word: String, at now: Date) {
        self.phase = phase
        self.word = word
        since = now
    }

    /// The bar's row, or `nil` for a chat that was never sent anything.
    public func signal() -> Signal? {
        guard let phase, let since else { return nil }
        return Signal(provider: Self.provider, entity: "evlat:\(id)", kind: .job, phase: phase,
                      label: label, detail: folder, source: nil, fidelity: .official,
                      rawStatus: word, updatedAt: since,
                      activity: Signal.Activity(lastTool: lastTool, blockingTool: blocking,
                                                waitKind: blocking == nil ? nil : .approval,
                                                lastReply: lastReply, toolCount: toolCount))
    }

    /// The oldest open card's tool, while the chat waits on it.
    private var blocking: Signal.Activity.Tool? {
        guard phase == .waiting else { return nil }
        for case .permission(let card) in messages where card.isOpen {
            return Signal.Activity.Tool(name: card.tool, subject: card.subject)
        }
        return nil
    }

    /// The title, else the first prompt's first line, capped; else the folder.
    private var label: String {
        if let title, !title.isEmpty { return title }
        for case .user(let text, _) in messages {
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return line.count > Self.labelLimit ? String(line.prefix(Self.labelLimit)) + "…" : line
            }
        }
        return (folder as NSString).lastPathComponent
    }

    /// The longest label taken from a prompt; the list cuts the rest.
    static let labelLimit = 60
}

extension ChatSession.Failure {
    /// The reason's name on the row's `rawStatus`.
    var word: String {
        switch self {
        case .noBinary: return "no-binary"
        case .launch: return "launch"
        case .exited: return "exited"
        case .result: return "result"
        case .interrupted: return "interrupted"
        case .noListener: return "no-listener"
        }
    }
}
