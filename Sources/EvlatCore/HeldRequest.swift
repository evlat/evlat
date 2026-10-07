import Foundation

/// A permission request whose answer is held until the user presses a
/// button on the card: an agent's terminal session asking (`ApprovalChannel`).
/// One tool call, and the grants it suggests.
public struct HeldRequest: Equatable {
    /// Evlat's name for this request, given when it is read: the held
    /// connection and the card are both keyed by it.
    public let id: String
    /// Which turn it belongs to; `nil` when the header was missing.
    public let token: String?
    public let tool: String
    /// `HookEvent.subject(of:)` over the input: the one line a card says.
    /// The input itself is not kept (`Write` carries a whole file) —
    /// except a question's, which its answer sends back (`input`).
    public let subject: String?
    /// A `Bash` command whole (`HookEvent.fullCommand(of:)`): what the
    /// card shows in place of the subject, so nothing runs unseen.
    public let command: String?
    /// The `addRules` suggestions that allow, flattened. Other kinds
    /// (`setMode`, `replaceRules`, …) are dropped here and never granted.
    public let rules: [PermissionRule]
    /// The `addDirectories` suggestions: a folder outside the chat's.
    public let directories: [String]
    public let sessionID: String?
    public let cwd: String?
    /// `agent_id`: a subagent's request carries its parent's session, so
    /// what answers it is told apart by the actor (`ApprovalHook.resolves`).
    /// The asking agent itself is `source`.
    public let subagent: String?
    /// An `AskUserQuestion`'s questions, when the card can answer them;
    /// `nil` for every other tool.
    public let questions: [AgentQuestion]?
    /// That tool's input as it came, sorted-keys JSON: `updatedInput`
    /// replaces the whole input, so the answer carries every field of
    /// it, modelled or not. Kept only beside `questions`.
    public let input: Data?
    /// The agent whose route it came in on (`RouteTable.approvals`),
    /// stamped by `LocalAPI.handle` — never read from the body. Its
    /// channel writes the answer (`ApprovalChannel.body`).
    public var source: AgentID?
    /// The remote machine whose listener heard it (`RemoteTunnels`); `nil`
    /// on this Mac's. The listener says it, never the body: only that
    /// machine's events resolve it, only its rows' cards show it, and the
    /// answer goes back to that listener.
    public var machine: String?

    public init(id: String, token: String?, tool: String, subject: String?, command: String? = nil,
                rules: [PermissionRule] = [], directories: [String] = [], sessionID: String? = nil,
                cwd: String? = nil, subagent: String? = nil,
                questions: [AgentQuestion]? = nil, input: Data? = nil,
                source: AgentID? = nil, machine: String? = nil) {
        self.id = id
        self.token = token
        self.tool = tool
        self.subject = subject
        self.command = command
        self.rules = rules
        self.directories = directories
        self.sessionID = sessionID
        self.cwd = cwd
        self.subagent = subagent
        self.source = source
        self.machine = machine
        self.questions = input == nil ? nil : questions
        self.input = questions == nil ? nil : input
    }
}
