@testable import EvlatAgents
import EvlatCore

// The catalog's agents by name, for tests that are about one of them:
// `.claude` reads as the agent where an agent is expected and as its id
// where an id is.
extension Agent where Self == Claude { static var claude: Claude { Claude() } }
extension Agent where Self == Codex { static var codex: Codex { Codex() } }
extension Agent where Self == Antigravity { static var antigravity: Antigravity { Antigravity() } }

extension AgentID {
    static let claude = Claude().id
    static let codex = Codex().id
    static let antigravity = Antigravity().id
}

extension HookEvent {
    /// Fixtures are written in the canonical vocabulary, which is Claude
    /// Code's; naming the agent each time would only repeat it.
    init(json: [String: Any]) {
        self.init(json: json, source: .claude)
    }
}

extension LocalAPI {
    /// `handle` as the app's listener runs it: the catalog's routes and
    /// agents, whatever else the listener says.
    static func handleAsTheApp(_ request: HTTPRequest, listener: Listener = Listener()) -> Outcome {
        handle(request, listener: Listener(origin: listener.origin, signalKey: listener.signalKey,
                                           transcriptRoots: listener.transcriptRoots, routes: Agents.routes,
                                           trustsSandboxHeaders: listener.trustsSandboxHeaders),
               agents: Agents.all)
    }
}

extension ChatMode {
    /// Claude's modes, by the names its chat tests use.
    static var ask: ChatMode { PermissionMode.ask.chatMode }
    static var auto: ChatMode { PermissionMode.auto.chatMode }
    static var acceptEdits: ChatMode { PermissionMode.acceptEdits.chatMode }
    static var bypass: ChatMode { PermissionMode.bypass.chatMode }
    static var standard: ChatMode { PermissionMode.standard.chatMode }
}
