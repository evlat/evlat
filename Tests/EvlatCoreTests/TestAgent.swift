import Foundation
@testable import EvlatCore

/// A stand-in agent: the core is run with it, never with a real one, which
/// is the proof that the core works with any agent the catalog lists. Its
/// values are plain — a path of its own, the shared hooks shape, no status
/// line unless a test gives it one.
struct TestAgent: Agent {
    var id: AgentID
    var presence: [String]
    var hooks: HookChannel
    var integration: AgentIntegration.Parts
    var statusLineUsage: StatusLineUsage?
    var approvals: (any ApprovalChannel)?
    var chat: (any ChatBackend)?
    var display: AgentDisplay

    init(_ name: String = "test", paths: [String]? = nil, statusLineUsage: StatusLineUsage? = nil,
         approvals: (any ApprovalChannel)? = nil, chat: (any ChatBackend)? = nil,
         canonical: @escaping ([String: Any]) -> [String: Any] = { $0 }) {
        id = AgentID(name)
        presence = [".\(name)"]
        hooks = HookChannel(paths: paths ?? ["\(RouteTable.installedPrefix)/\(name)"],
                            events: ["SessionStart", "PreToolUse", "PermissionRequest", "Stop"],
                            canonical: canonical)
        integration = AgentIntegration.Parts(hooksFile: ".\(name)/hooks.json")
        self.statusLineUsage = statusLineUsage
        self.approvals = approvals
        self.chat = chat
        display = AgentDisplay(nameKey: "source.\(name)")
    }

    func providers(_ context: ProviderContext) -> [Provider] { [] }
}

extension AgentID {
    static let test = AgentID("test")
    static let other = AgentID("other")
    static let third = AgentID("third")
}

extension StatusLineUsage {
    /// A status line carrying two windows under `rate_limits`, read as used
    /// percentages: the shape the usage tests are written in.
    static func test(path: String = "/usage/test") -> StatusLineUsage {
        StatusLineUsage(path: path, providerID: "test-usage", group: "Test", fidelity: .official,
                        root: "rate_limits",
                        windows: [.init("five_hour", minutes: 300), .init("seven_day", minutes: 10080)],
                        reading: .usedPercentage)
    }
}

extension HookEvent {
    /// Fixtures are written in the canonical vocabulary; naming the agent
    /// each time would only repeat it.
    init(json: [String: Any]) {
        self.init(json: json, source: .test)
    }
}

/// A stand-in chat backend: one way, asking through the listener, its modes
/// plain words. Its permission body is the canonical hook's; its answer the
/// decision's own description.
struct TestChatBackend: ChatBackend {
    var id = AgentID.test
    let executable = "testagent"

    static let ask = ChatMode(id: "ask", nameKey: "chat.mode.test.ask")
    /// Judges on its own; what it turns down may be tried again in `ask`.
    static let auto = ChatMode(id: "auto", nameKey: "chat.mode.test.auto", retryDenialAs: "ask")
    static let bypass = ChatMode(id: "bypass", nameKey: "chat.mode.test.bypass",
                                 asksBeforePicking: true, mayBeDefault: false)

    let modes = [TestChatBackend.ask, TestChatBackend.auto, TestChatBackend.bypass]
    let offered = [TestChatBackend.auto, TestChatBackend.ask]
    let standardMode = TestChatBackend.auto
    let caps = ChatCapabilities(asks: true, alwaysOption: .rules, resume: true, memory: false, transport: .oneWay)
    let stopPlan = ChatStopPlan.signal

    func turn(_ spec: TurnSpec, ctx: TurnContext) -> TurnLaunch {
        TurnLaunch(arguments: ["--mode", spec.mode.id], input: [Data((spec.prompt + "\n").utf8)],
                   environment: [TurnLaunch.taskVariable: spec.chatID], directory: spec.directory)
    }

    func parser(for spec: TurnSpec) -> any ChatParser { Quiet() }

    func request(json: [String: Any], token: String) -> ChatRequest? {
        guard json["hook_event_name"] as? String ?? "PermissionRequest" == "PermissionRequest",
              let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
        return ChatRequest(id: UUID().uuidString, token: token, tool: tool,
                           subject: HookEvent.subject(of: json["tool_input"] as? [String: Any]),
                           replyTarget: .listener)
    }

    func encode(_ decision: ChatDecision, for request: ChatRequest) -> ChatReply {
        .http(Data(String(describing: decision).utf8))
    }

    /// Reads nothing; every line is unrecognised.
    struct Quiet: ChatParser {
        private(set) var unrecognized: [String: Int] = [:]
        mutating func feed(_ chunk: Data) -> (events: [ChatEvent], replies: [Data]) {
            unrecognized["line", default: 0] += chunk.filter { $0 == 0x0A }.count
            return ([], [])
        }
        mutating func finish() -> [ChatEvent] { [] }
    }
}
