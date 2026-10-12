import EvlatCore

/// The catalog of the agents Evlat knows: each one's routes, hooks, usage
/// and approvals are its own values (`Agent`), and the rest of the app
/// reaches them only through here. An agent not listed is not missing a
/// feature — it does not exist; `AgentCatalogTests` holds the list together.
public enum Agents {
    /// In the catalogue's order: the order settings list them and the order
    /// a stored switch is written in (`EnabledAgents`).
    public static let all: [any Agent] = [Claude(), Codex(), Antigravity(), OpenCode()]

    /// The agents a server's unit covers, in the catalogue's order
    /// (`RemoteSettings.serves`): every form of unit is written over `ssh`,
    /// so today this is `all`. Everything that reads or writes a machine
    /// goes through this list, so a form that one day is not served leaves
    /// the machines' side without a change there; the agents on this Mac go
    /// through `all`.
    public static let served: [any Agent] = all.filter { RemoteSettings.serves($0) }

    /// The listener's routes, made from `all`.
    public static let routes = RouteTable(all)

    /// The agents that can be the chat bubble's backend, in the catalogue's
    /// order: the first is the chat's until one is chosen.
    public static let chatBackends: [any ChatBackend] = all.compactMap(\.chat)
}

extension AgentID {
    /// The catalog's agent with this id. Every id the app holds comes from
    /// `Agents.all`, or from a stored switch resolved against it
    /// (`EnabledAgents`), so an id this build does not know never gets here.
    public var agent: any Agent { Agents.all[id: self]! }
}

extension Agents {
    /// Whether a canonical tool asks the user a question rather than for
    /// permission, for some agent's approvals (`HooksProvider`).
    public static func isQuestion(_ tool: String) -> Bool {
        all.contains { $0.approvals?.isQuestion(tool) == true }
    }
}
