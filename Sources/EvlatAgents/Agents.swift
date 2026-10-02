import EvlatCore

/// The catalog of the agents Evlat knows: each one's routes, hooks, usage
/// and approvals are its own values (`Agent`), and the rest of the app
/// reaches them only through here. An agent not listed is not missing a
/// feature — it does not exist; `AgentCatalogTests` holds the list together.
public enum Agents {
    /// In the catalogue's order: the order settings list them and the order
    /// a stored switch is written in (`EnabledAgents`).
    public static let all: [any Agent] = [Claude(), Codex(), Antigravity()]

    /// The listener's routes, made from `all`.
    public static let routes = RouteTable(all)
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
