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
