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
    var display: AgentDisplay

    init(_ name: String = "test", paths: [String]? = nil, statusLineUsage: StatusLineUsage? = nil,
         approvals: (any ApprovalChannel)? = nil,
         canonical: @escaping ([String: Any]) -> [String: Any] = { $0 }) {
        id = AgentID(name)
        presence = [".\(name)"]
        hooks = HookChannel(paths: paths ?? ["\(RouteTable.installedPrefix)/\(name)"],
                            events: ["SessionStart", "PreToolUse", "PermissionRequest", "Stop"],
                            canonical: canonical)
        integration = AgentIntegration.Parts(hooksFile: ".\(name)/hooks.json")
        self.statusLineUsage = statusLineUsage
        self.approvals = approvals
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
