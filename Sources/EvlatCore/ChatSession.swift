import Foundation

/// One chat's state machine: the user's prompts and the stream's
/// events in; the messages the balloon draws and the bar's `Signal` out.
///
/// **The phase comes from the stream, not from hooks**: an Evlat on
/// another port never hears the turn's hooks, it always hears its stdout.
/// `working` from the prompt to the `result`; `review` when the turn
/// finished (or the user stopped it); `failed` when it ended in an error,
/// died without a result or never started; `waiting` while a permission
/// card is open, back to `working` when the last one is
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
    /// `nil` until the first reply gives one (its first sentence);
    /// the row falls back to the first prompt.
    public var title: String?
    /// How much the next turn does without asking (`--permission-mode`).
    /// The chat's own: a later turn — a `--resume` — runs in it too.
    public var mode: PermissionMode

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
    /// Has this turn's end been seen and let go? The shell lets it go at the
    /// close of the bar after it was seen (on the bar or in the balloon); a
    /// chat let go has no row: it is in the history. A new turn clears it.
    public private(set) var seen = false
    /// Did this turn's `result` arrive? An exit without one is a crash.
    private var resultSeen = false
    /// Is the last message a reply still being streamed? Deltas append to
    /// it and the finished `assistant` text replaces it.
    private var replyOpen = false
    /// Where the running (or last) turn's messages start: its prompt.
    private var turnStart = 0
    /// The mode the running (or last) turn started in.
    private var turnMode = PermissionMode.standard

    public enum Message: Equatable {
        case user(text: String, attachments: [String])
        case reply(String)
        /// One tool call on one line; `failed` is `nil` until its result,
        /// `output` the first line of what it said.
        case tool(id: String, name: String, subject: String?, failed: Bool?, output: String?)
        /// A permission request, open until answered.
        case permission(PermissionCard)
        /// A tool call Claude made and was denied without a card — auto
        /// mode's classifier, a deny rule.
        case notDone(NotDone)
    }

    /// A tool call that did not run and was never asked: the balloon says
    /// so, dimly, and offers to try it again where it would ask.
    public struct NotDone: Equatable {
        public let toolUseID: String?
        public let tool: String
        /// The call's one line (`HookEvent.subject`), from its tool row.
        public let subject: String?
        /// The mode the turn started in, not the chat's now: the label can
        /// change while a turn runs.
        public let mode: PermissionMode
        /// Claude's `decision_reason_type`. Only `classifier` is auto mode's
        /// own judgement; any other (`rule`, `subcommandResults`, …) is a deny
        /// rule, which denies in every mode — asking would not help.
        public let reason: String?

        public init(toolUseID: String?, tool: String, subject: String?, mode: PermissionMode,
                    reason: String? = "classifier") {
            self.toolUseID = toolUseID
            self.tool = tool
            self.subject = subject
            self.mode = mode
            self.reason = reason
        }

        /// Auto mode's classifier said no, in auto mode: the one denial a
        /// turn that asks instead could get past.
        public var isAutoModes: Bool { mode == .auto && reason == "classifier" }
    }

    /// One permission request on the balloon (`R6`).
    public struct PermissionCard: Equatable {
        /// The request's id: the held connection's key.
        public let id: String
        public let tool: String
        public let subject: String?
        /// A command whole, shown in place of `subject` (`PermissionHook.Request.command`).
        public var command: String? = nil
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
    /// catalogue. `detail` is the process's own line.
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
                hasStarted: Bool = false, mode: PermissionMode = .standard) {
        self.hasStarted = hasStarted
        self.mode = mode
        self.id = id
        self.sessionID = sessionID
        self.folder = folder
        self.isWorkspace = isWorkspace
        self.title = title
    }

    /// A prompt. Returns the turn to start, or `nil` while one is running.
    /// The chat's granted directories and rules ride along.
    public mutating func begin(prompt: String, attachments: [String], at now: Date,
                               addDirectories: [String] = [], allowedTools: [String] = []) -> ClaudeInvocation? {
        guard !isRunning else { return nil }
        turnStart = messages.count
        turnMode = mode
        messages.append(.user(text: prompt, attachments: attachments))
        isRunning = true
        resultSeen = false
        stopRequested = false
        replyOpen = false
        failure = nil
        lastTool = nil
        toolCount = 0
        lastReply = nil
        seen = false
        set(.working, word: "send", at: now)
        return ClaudeInvocation.turn(chatID: id, sessionID: sessionID, resume: hasStarted,
                                     prompt: prompt, attachments: attachments, directory: folder,
                                     addDirectories: addDirectories, allowedTools: allowedTools, mode: mode)
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
            lastReply = HookEvent.replyPreview(result.text)
            if title == nil, !result.isError, result.subtype == "success" {
                title = Self.title(fromReply: result.text ?? lastReplyText)
            }
            if stopRequested {
                set(.review, word: Self.stoppedWord, at: now)
            } else if result.isError || result.subtype != "success" {
                failure = .result(subtype: result.subtype, text: result.text)
                set(.failed, word: "result/\(result.subtype)", at: now)
            } else {
                set(.review, word: "result/\(result.subtype)", at: now)
            }
        case .permissionDenied(let denial):
            if let line = notDone(denial) { messages.append(.notDone(line)) }
        }
    }

    /// A denial the user did not give: not a hook's (a card's answer, or
    /// its time running out), not one of this turn's cards by its tool and
    /// line. Only a tool call Claude actually made gets a line — a request
    /// the model turned down itself it already explains.
    private func notDone(_ denial: ChatStream.Denial) -> NotDone? {
        guard isRunning, denial.reason != "hook", let id = denial.toolUseID else { return nil }
        let turn = messages[min(turnStart, messages.count)...]
        guard let row = turn.lazy.compactMap({ message -> (String, String?)? in
            if case .tool(id, let name, let subject, _, _) = message { return (name, subject) }
            return nil
        }).first else { return nil }
        let asked = turn.contains {
            if case .permission(let card) = $0 { return card.tool == row.0 && card.subject == row.1 }
            return false
        }
        guard !asked, !turn.contains(where: {
            if case .notDone(let line) = $0 { return line.toolUseID == id }
            return false
        }) else { return nil }
        return NotDone(toolUseID: id, tool: row.0, subject: row.1, mode: turnMode, reason: denial.reason)
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
        // A folder the chat already works in is no access to give: Claude
        // 2.1.281 suggests the working folder itself for `mkdir` in Ask
        // mode (seen from the balloon), and the card called it "outside
        // this chat's folder" and kept it for nothing.
        let outside = request.directories.filter { !Self.isWithin($0, folder) }
        messages.append(.permission(PermissionCard(id: request.id, tool: request.tool, subject: request.subject,
                                                   command: request.command,
                                                   rules: request.rules, directories: outside)))
        // A second card while one is open keeps the wait's start: the bar
        // counts how long the chat has been waiting, not since the last card.
        if phase != .waiting { set(.waiting, word: "permission", at: now) }
        return true
    }

    /// Is `path` the folder or inside it? By the paths' text, standardized
    /// (`.`, `..`, a trailing `/`); the file system is not asked.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let folder = URL(fileURLWithPath: folder).standardizedFileURL.path
        return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
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

    // MARK: - Seen, and the row's life

    /// A finished chat nobody looked at keeps its row this long after it
    /// ended, then goes to the history on its own: the bar does not collect
    /// yesterday's answers.
    public static let unseenLifetime: TimeInterval = 12 * 3600

    /// Has the turn ended — answered, stopped or failed — with nothing running?
    public var isFinished: Bool { !isRunning && (phase == .review || phase == .failed) }

    /// This chat's seen end is let go (the shell's release at a close of the
    /// bar). `true` when that changed anything.
    @discardableResult
    public mutating func markSeen() -> Bool {
        guard isFinished, !seen else { return false }
        seen = true
        return true
    }

    /// The bar's row at `now`, or `nil`: a chat never sent anything, a
    /// finished one already seen, or one left unseen past `unseenLifetime`.
    /// Read, not scheduled: the row leaves at the first scan after its time.
    public func signal(at now: Date) -> Signal? {
        guard let phase, let since else { return nil }
        if isFinished {
            guard !seen, now.timeIntervalSince(since) < Self.unseenLifetime else { return nil }
        }
        return Signal(provider: Self.provider, entity: Self.entity(id), kind: .job, phase: phase,
                      label: label, detail: folder, source: nil, fidelity: .official,
                      rawStatus: word, updatedAt: since,
                      activity: Signal.Activity(lastTool: lastTool, blockingTool: blocking,
                                                waitKind: blocking == nil ? nil : .approval,
                                                lastReply: lastReply,
                                                // "0 tools" says nothing; a turn
                                                // that used none shows no count.
                                                toolCount: toolCount > 0 ? toolCount : nil))
    }

    /// A chat's `Signal.entity`.
    public static func entity(_ id: String) -> String { "evlat:\(id)" }

    /// The chat an `entity` names, or `nil` for anything that is not a chat's.
    public static func chatID(fromEntity entity: String) -> String? {
        let prefix = "evlat:"
        guard entity.hasPrefix(prefix) else { return nil }
        let id = String(entity.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// A chat read back from the index: the last reply as its one line (the
    /// conversation stays Claude's), no row unless its end was never seen —
    /// then `review` or `failed` from when it ended, as it was.
    /// `mode` is for an entry written before chats had one.
    public static func restored(_ entry: ChatIndex.Entry, mode: PermissionMode = .standard) -> ChatSession {
        var chat = ChatSession(id: entry.id, sessionID: entry.sessionID, folder: entry.folder,
                               isWorkspace: entry.isWorkspace, title: entry.title,
                               hasStarted: entry.started,
                               mode: PermissionMode(stored: entry.permissionMode) ?? mode)
        chat.lastReply = entry.lastReply
        if let reply = entry.lastReply, !reply.isEmpty { chat.messages = [.reply(reply)] }
        if let phase = entry.unseen, phase == .review || phase == .failed {
            chat.set(phase, word: "evlat/restored", at: entry.lastActivity)
        }
        return chat
    }

    /// The finished phase the index keeps while the end is unseen, so a
    /// relaunch brings the row back; `nil` once seen, or while running.
    public var unseenPhase: Phase? { isFinished && !seen ? phase : nil }

    /// A title from a reply: its first sentence on its first line, bare of
    /// markdown's marks, cut to `labelLimit`. `nil` for an empty reply.
    public static func title(fromReply reply: String?) -> String? {
        guard let reply else { return nil }
        let line = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-_>` ")).isEmpty }
        guard var text = line?.trimmingCharacters(in: CharacterSet(charactersIn: "#*-_>` ")) else { return nil }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // The first sentence: up to a stop that ends a word ("3.5" is not one).
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?:".contains(text[index]), next == text.endIndex || text[next] == " " {
                end = text[index] == ":" ? index : next
                break
            }
            index = next
        }
        let sentence = text[..<end].trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty else { return nil }
        return sentence.count > labelLimit ? String(sentence.prefix(labelLimit)) + "…" : sentence
    }

    /// The streamed reply, when the result carried no text of its own.
    private var lastReplyText: String? {
        for case .reply(let text) in messages.reversed() { return text }
        return nil
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
        return promptLabel ?? (folder as NSString).lastPathComponent
    }

    /// The first prompt's first line, capped: what the index keeps as the
    /// title until a reply gives one — a chat read back has no prompt, and
    /// a workspace's folder is a UUID nobody should read.
    public var promptLabel: String? {
        for case .user(let text, _) in messages {
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return line.count > Self.labelLimit ? String(line.prefix(Self.labelLimit)) + "…" : line
            }
        }
        return nil
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
