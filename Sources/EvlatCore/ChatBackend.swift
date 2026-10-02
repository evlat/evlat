import Foundation

/// The chat bubble's seam: one agent's way of running a turn, reading what it
/// says and answering what it asks. The bubble (`ChatSession`, the shell's
/// store and runner) speaks only the shared types below; everything
/// particular to an agent — its command line, its stream's words, its
/// permission format — is its backend's (`Agent.chat`).
///
/// A turn is one process. **One way**: the process streams its stdout and
/// asks its permissions through the listener (`ChatRequest.path`), where
/// the answer is an HTTP body. **Duplex**: the process asks on the same
/// channel it streams on, and the answer is a line written to its stdin.
public protocol ChatBackend {
    var id: AgentID { get }
    /// The program a turn runs, looked up on the login shell's `PATH`; the
    /// variable `EVLAT_<NAME>` (upper-cased) points at another one.
    var executable: String { get }
    /// Every mode a chat can be in, in the order the bubble's menu lists them.
    var modes: [ChatMode] { get }
    /// The new chats' defaults Settings and Setup list, the recommended one
    /// first. A mode that may not be a default is not among them.
    var offered: [ChatMode] { get }
    /// A new chat's mode when nothing was chosen.
    var standardMode: ChatMode { get }
    /// Where the new chats' mode is stored (`UserDefaults`). Each backend has
    /// its own, `chat.<id>.mode` unless one was stored before it existed.
    var modeKey: String { get }
    /// The index file under the store's root (`ChatIndex`): each backend
    /// keeps its own, `chats-<id>.json` unless one was written before.
    var indexFile: String { get }
    var caps: ChatCapabilities { get }
    /// How Stop ends a running turn.
    var stopPlan: ChatStopPlan { get }
    /// The agent version its chat was checked against: a turn that reports
    /// another (`ChatParser.version`) is said in the diagnostics and in
    /// Settings, since an unmeasured version may speak differently. `nil`
    /// checks nothing.
    var measuredVersion: String? { get }
    /// A catalogue key for one line Settings shows under the backend while it
    /// is chosen (an experimental protocol, say); `nil` for none.
    var noteKey: String? { get }

    /// The turn to start for `spec`, with what is known only when it starts.
    func turn(_ spec: TurnSpec, ctx: TurnContext) -> TurnLaunch
    /// A fresh reader for the turn `spec` starts. A duplex reader drives
    /// the turn too: what it writes back (`ChatParser.feed`) can depend on
    /// the spec and on what the process answered.
    func parser(for spec: TurnSpec) -> any ChatParser
    /// A permission request posted to the listener by one of this backend's
    /// turns; `nil` when it is not one the card can hold. Asked only of a
    /// one-way backend.
    func request(json: [String: Any], token: String) -> ChatRequest?
    /// The answer to `request`, in this backend's format.
    func encode(_ decision: ChatDecision, for request: ChatRequest) -> ChatReply
}

extension ChatBackend {
    public var modeKey: String { "chat.\(id.rawValue).mode" }

    public var indexFile: String { ChatIndex.fileName(for: id) }

    public func request(json: [String: Any], token: String) -> ChatRequest? { nil }

    public var measuredVersion: String? { nil }

    public var noteKey: String? { nil }

    /// A stored mode read back; anything else — an old value, a mode this
    /// build does not offer — is `nil`, and the caller's default applies.
    public func mode(stored: String?) -> ChatMode? {
        guard let stored else { return nil }
        return modes.first { $0.id == stored }
    }

    /// The variable that points at another `executable`: `EVLAT_<NAME>`.
    public var executableVariable: String { ChatBackends.variable(for: executable) }
}

public enum ChatBackends {
    /// `EVLAT_` and the program's name, upper-cased.
    public static func variable(for executable: String) -> String { "EVLAT_" + executable.uppercased() }
}

/// What a backend can do, as values: the bubble asks these, never which
/// backend it is.
public struct ChatCapabilities: Equatable {
    /// Does a turn ask, tool call by tool call? Without it there is no card.
    public let asks: Bool
    /// What "always" on a card grants.
    public let alwaysOption: AlwaysOption
    /// Does a later turn go on with the conversation?
    public let resume: Bool
    /// Do workspace chats share one memory folder (`TurnContext.memoryDirectory`)?
    public let memory: Bool
    public let transport: Transport

    public enum AlwaysOption: Equatable {
        /// The request's suggested rules and folders, kept for the chat's
        /// later turns (`ChatIndex.Entry.allowedRules`).
        case rules
        /// The same command again, for the rest of the turn's session; the
        /// agent remembers it, Evlat keeps nothing.
        case thisCommand
    }

    public enum Transport: Equatable {
        /// Stdout streams; permissions come through the listener.
        case oneWay
        /// Permissions come on stdout too, and are answered on stdin.
        case duplex
    }

    public init(asks: Bool, alwaysOption: AlwaysOption, resume: Bool, memory: Bool, transport: Transport) {
        self.asks = asks
        self.alwaysOption = alwaysOption
        self.resume = resume
        self.memory = memory
        self.transport = transport
    }
}

/// How much a chat's turn does without asking: one of its backend's modes.
public struct ChatMode: Equatable, Hashable {
    /// The backend's own word for it; also what the index and the defaults
    /// store.
    public let id: String
    /// The catalogue key of its name; `<nameKey>.detail` says what it does.
    public let nameKey: String
    /// Picking it takes the user's explicit yes, every time it is switched on.
    public let asksBeforePicking: Bool
    /// Whether it may be the new chats' mode.
    public let mayBeDefault: Bool
    /// A call this mode denied on its own judgement — not a rule, not the
    /// user — may be tried again in this mode, where it would ask (its id).
    public let retryDenialAs: String?

    public init(id: String, nameKey: String, asksBeforePicking: Bool = false, mayBeDefault: Bool = true,
                retryDenialAs: String? = nil) {
        self.id = id
        self.nameKey = nameKey
        self.asksBeforePicking = asksBeforePicking
        self.mayBeDefault = mayBeDefault
        self.retryDenialAs = retryDenialAs
    }

    /// What it does, in one line.
    public var detailKey: String { nameKey + ".detail" }
}

/// One turn as the chat asks for it: what the session knows.
public struct TurnSpec: Equatable {
    /// Evlat's id for the chat; the turn's hooks carry it (`TurnLaunch.taskVariable`).
    public let chatID: String
    public let sessionID: String
    /// Does the turn go on with the session rather than start it?
    public let resume: Bool
    public let prompt: String
    public let attachments: [String]
    public let directory: String
    /// What the chat was granted before ("always" on a card).
    public let addDirectories: [String]
    public let allowedTools: [String]
    public let mode: ChatMode

    public init(chatID: String, sessionID: String, resume: Bool, prompt: String, attachments: [String],
                directory: String, addDirectories: [String] = [], allowedTools: [String] = [], mode: ChatMode) {
        self.chatID = chatID
        self.sessionID = sessionID
        self.resume = resume
        self.prompt = prompt
        self.attachments = attachments
        self.directory = directory
        self.addDirectories = addDirectories
        self.allowedTools = allowedTools
        self.mode = mode
    }
}

/// What the shell knows only when the turn starts: the listener's bound
/// port, the turn's token and, for a workspace chat, the shared memory folder.
/// A duplex turn asks on its own channel and may start with no listener
/// bound: its port is then 0.
public struct TurnContext: Equatable {
    public let port: UInt16
    public let token: String
    public let memoryDirectory: String?

    public init(port: UInt16, token: String, memoryDirectory: String? = nil) {
        self.port = port
        self.token = token
        self.memoryDirectory = memoryDirectory
    }
}

/// How one turn's process is started. Pure — the shell resolves the binary
/// and the `PATH` and runs it.
public struct TurnLaunch: Equatable {
    /// The variable the installed hook command sends as `X-Evlat-Task`
    /// (`LocalAPI.installedHookCommand`), so the user's own hooks mark the
    /// turn's events as an Evlat errand and `HooksProvider` leaves them out.
    public static let taskVariable = "EVLAT_TASK"

    public let arguments: [String]
    /// Written to stdin in order, each a whole line.
    public let input: [Data]
    /// Added to the inherited environment.
    public let environment: [String: String]
    /// Taken out of the inherited environment first.
    public let removedEnvironment: Set<String>
    /// The working directory the turn runs in.
    public let directory: String

    public init(arguments: [String], input: [Data], environment: [String: String],
                removedEnvironment: Set<String> = [], directory: String) {
        self.arguments = arguments
        self.input = input
        self.environment = environment
        self.removedEnvironment = removedEnvironment
        self.directory = directory
    }

    /// The turn's whole environment: `inherited` without what is removed,
    /// plus what this turn adds.
    public func environment(inheriting inherited: [String: String]) -> [String: String] {
        inherited.filter { !removedEnvironment.contains($0.key) }
            .merging(environment) { _, new in new }
    }
}

/// What a turn's stdout says, in the few events a chat shows.
public enum ChatEvent: Equatable {
    /// The turn reached the agent and this is its session. An agent that
    /// names its sessions itself says it here, and the chat keeps that name
    /// from its first turn on (`ChatSession.sessionID`).
    case started(sessionID: String)
    /// A piece of the reply as it is written.
    case textDelta(String)
    /// A finished assistant message: its text (blocks joined) and the tools
    /// it calls, each reduced to one line.
    case assistant(text: String?, tools: [ToolCall])
    /// A tool's result: whether it failed, and the first line of what it
    /// said, capped.
    case toolResult(id: String, isError: Bool, output: String?)
    case result(Result)
    /// A tool call denied without the user's word on a card, or by it.
    case permissionDenied(Denial)
    /// A duplex turn asking on its own channel (`ChatRequest.ReplyTarget.runner`):
    /// the store puts it on the turn's chat, whose answer goes back on stdin.
    case asked(ChatRequest)
    /// The agent asked for something the bubble cannot answer (its word for
    /// it): the backend refused it on the spot and the turn goes on. Said in
    /// the chat, so a protocol that grew does not fail quietly.
    case unsupported(String)

    public struct ToolCall: Equatable {
        public let id: String
        public let name: String
        /// `HookEvent.subject(of:)` over the input — the same line a session's
        /// card shows. The raw input is never kept (`Write` carries a file).
        public let subject: String?

        public init(id: String, name: String, subject: String?) {
            self.id = id
            self.name = name
            self.subject = subject
        }
    }

    public struct Denial: Equatable {
        public let tool: String?
        public let toolUseID: String?
        /// The agent's own word for why.
        public let reason: String?
        public let message: String?
        /// The user's answer on a card: the card already says so.
        public let answered: Bool
        /// The mode's own judgement, not a rule: asking instead could get
        /// past it (`ChatMode.retryDenialAs`).
        public let retryable: Bool

        public init(tool: String?, toolUseID: String? = nil, reason: String? = nil, message: String? = nil,
                    answered: Bool = false, retryable: Bool = false) {
            self.tool = tool
            self.toolUseID = toolUseID
            self.reason = reason
            self.message = message
            self.answered = answered
            self.retryable = retryable
        }
    }

    public struct Result: Equatable {
        /// `success`, or an error word.
        public let subtype: String
        public let isError: Bool
        /// The final reply text, when the source gives one.
        public let text: String?

        public init(subtype: String, isError: Bool, text: String?) {
            self.subtype = subtype
            self.isError = isError
            self.text = text
        }
    }
}

/// Reads one turn's stdout. **An unknown word is counted, not swallowed**:
/// a renamed type would otherwise make the chat silently empty.
public protocol ChatParser {
    /// Words read but not known, with how often.
    var unrecognized: [String: Int] { get }
    /// The agent's version, as the turn reported it; `nil` until it did, or
    /// for an agent whose stream does not say.
    var version: String? { get }
    /// One chunk as read from the pipe: the events of every line it
    /// completed, and — duplex only — the lines to write back.
    mutating func feed(_ chunk: Data) -> (events: [ChatEvent], replies: [Data])
    /// The pipe closed: a last line without a newline is still a line.
    mutating func finish() -> [ChatEvent]
    /// Stop, in the turn's own words (`ChatStopPlan.inBand`): a line that
    /// names what only the stream told — `nil` while it cannot yet.
    func stopLine() -> Data?
}

extension ChatParser {
    public var version: String? { nil }

    public func stopLine() -> Data? { nil }
}

/// A permission rule: a tool, and optionally what it is limited to.
public struct PermissionRule: Equatable, Hashable {
    public let toolName: String
    public let ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }

    /// The rule as a command line spells it: `Bash(ls:*)`, or the bare tool.
    public var text: String {
        guard let ruleContent, !ruleContent.isEmpty else { return toolName }
        return "\(toolName)(\(ruleContent))"
    }
}

/// One permission request of a chat's turn, as its card shows it.
public struct ChatRequest: Equatable {
    /// The listener's route for a one-way turn's requests. Local only: a
    /// tunnel answers it `404` (`LocalAPI`).
    public static let path = "/permission"
    /// The header a one-way turn's token rides in.
    public static let tokenHeader = "X-Evlat-Permission"

    /// Evlat's name for the request: the held connection and the card are
    /// both keyed by it. Unique across every chat.
    public let id: String
    /// Which turn it belongs to.
    public let token: String?
    /// The agent's own id for the request, when its answer must name it (a
    /// duplex request's, as the JSON it came as): not unique across turns,
    /// so never a key.
    public let callID: String?
    public let tool: String
    /// The one line a card says (`HookEvent.subject`).
    public let subject: String?
    /// A command whole, shown in place of the subject.
    public let command: String?
    /// The agent's own sentence for why it asks, when it gives one.
    public let reason: String?
    /// What "always" would grant (`ChatCapabilities.AlwaysOption.rules`).
    public let rules: [PermissionRule]
    public let directories: [String]
    /// Where the answer goes.
    public let replyTarget: ReplyTarget

    public enum ReplyTarget: Equatable {
        /// The listener's held connection (one way).
        case listener
        /// The turn's own stdin (duplex).
        case runner
    }

    public init(id: String, token: String?, callID: String? = nil, tool: String, subject: String?,
                command: String? = nil, reason: String? = nil, rules: [PermissionRule] = [],
                directories: [String] = [], replyTarget: ReplyTarget) {
        self.id = id
        self.token = token
        self.callID = callID
        self.tool = tool
        self.subject = subject
        self.command = command
        self.reason = reason
        self.rules = rules
        self.directories = directories
        self.replyTarget = replyTarget
    }
}

/// The user's answer to a permission request, before a backend words it.
public enum ChatDecision: Equatable {
    /// Allowed; the rules and folders are granted for the session too.
    case allow(rules: [PermissionRule], directories: [String])
    /// Allowed, and the same request again for the rest of the agent's
    /// session (`ChatCapabilities.AlwaysOption.thisCommand`): the agent keeps
    /// it, Evlat keeps nothing.
    case allowForSession
    /// `interrupt` ends the turn with it: the user pressed Stop.
    case deny(interrupt: Bool)
    /// A question answered: allowed with `input` (the request's) plus
    /// `answers`, each question's text to its answer.
    case answer(input: Data, answers: [String: String])
}

/// An answer, ready for its target (`ChatRequest.ReplyTarget`).
public enum ChatReply: Equatable {
    /// The held connection's body.
    case http(Data)
    /// A line for the turn's stdin.
    case line(Data)
}

/// How Stop ends a running turn.
public enum ChatStopPlan: Equatable {
    /// SIGINT, then SIGTERM if it is still running a while later.
    case signal
    /// A line on stdin, worded by the turn's parser (`ChatParser.stopLine`);
    /// the turn ends itself, and is ended all the same if it does not. One
    /// that cannot be worded yet ends the process.
    case inBand
}
