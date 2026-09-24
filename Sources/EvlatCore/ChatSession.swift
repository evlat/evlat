import Foundation

/// One chat's state machine (`011`): the user's prompts and the stream's
/// events in; the messages the balloon draws and the bar's `Signal` out.
///
/// **The phase comes from the stream, not from hooks** (Karar 3): an Evlat on
/// another port never hears the turn's hooks, it always hears its stdout.
/// `working` from the prompt to the `result`; `review` when the turn
/// finished (or the user stopped it); `failed` when it ended in an error,
/// died without a result or never started. `waiting` is `phase-3`'s. No
/// `Phase` value is added.
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
        /// One tool call on one line; `failed` is `nil` until its result.
        case tool(id: String, name: String, subject: String?, failed: Bool?)
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
                messages.append(.tool(id: tool.id, name: tool.name, subject: tool.subject, failed: nil))
                lastTool = Signal.Activity.Tool(name: tool.name, subject: tool.subject)
                toolCount += 1
            }
        case .toolResult(let id, let isError):
            if let index = messages.lastIndex(where: {
                if case .tool(id, _, _, _) = $0 { return true }
                return false
            }), case .tool(_, let name, let subject, _) = messages[index] {
                messages[index] = .tool(id: id, name: name, subject: subject, failed: isError)
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

    /// The process ended. After a result this changes nothing; without one
    /// the turn crashed — unless the user asked it to stop.
    public mutating func ended(status: Int32, stderr: String, at now: Date) {
        guard isRunning else { return }
        isRunning = false
        replyOpen = false
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

    /// The user asked the running turn to end. `false` when nothing runs.
    @discardableResult
    public mutating func requestStop() -> Bool {
        guard isRunning else { return false }
        stopRequested = true
        return true
    }

    /// A failure with no process behind it: no binary, a launch that did not
    /// happen, a turn found interrupted at launch.
    public mutating func fail(_ reason: Failure, at now: Date) {
        isRunning = false
        replyOpen = false
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
                      activity: Signal.Activity(lastTool: lastTool, lastReply: lastReply,
                                                toolCount: toolCount))
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
        }
    }
}
