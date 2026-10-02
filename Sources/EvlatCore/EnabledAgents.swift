import Foundation

/// Which agents Evlat follows on this Mac (Settings → Agents, the setup's
/// agent step). An agent switched off has no row, no usage provider and no
/// approval card; its hooks may still be installed and still post.
///
/// **Nothing stored is a live answer, not a value.** Until the user changes
/// it, the set is the agents found under the home, asked again every time:
/// an agent installed next week is on next week without anyone writing it.
/// Storing the set at launch would freeze it, so reading never writes —
/// only a user's change does (`changing`).
public enum EnabledAgents {
    /// `UserDefaults` key: the agents' `rawValue`s, in the catalogue's order.
    /// Every function below takes that catalogue: the agents this build
    /// knows, in order.
    public static let key = "agents.enabled"

    /// The set in force. `stored` is the key's value; `nil` (never changed)
    /// is the agents present. A name this build does not know — a newer
    /// copy's agent — is skipped, never an error.
    public static func resolve(stored: [String]?, catalog: [AgentID],
                               isPresent: (AgentID) -> Bool) -> Set<AgentID> {
        guard let stored else { return Set(catalog.filter(isPresent)) }
        return Set(stored.map(AgentID.init(rawValue:)).filter(catalog.contains))
    }

    /// What to store for `set`, in the catalogue's order so the value reads
    /// the same however it was reached.
    public static func stored(_ set: Set<AgentID>, catalog: [AgentID]) -> [String] {
        catalog.filter(set.contains).map(\.rawValue)
    }

    /// The value to write when the user turns `source` on or off: `nil`
    /// when that changes nothing, so a choice that only repeats the live
    /// default leaves it live. A name this build does not know is carried
    /// as it was: a newer copy's agent stays on for that copy.
    public static func changing(_ source: AgentID, to on: Bool, stored: [String]?, catalog: [AgentID],
                                isPresent: (AgentID) -> Bool) -> [String]? {
        var set = resolve(stored: stored, catalog: catalog, isPresent: isPresent)
        guard set.contains(source) != on else { return nil }
        if on { set.insert(source) } else { set.remove(source) }
        let unknown = (stored ?? []).filter { !catalog.contains(AgentID($0)) }
        return Self.stored(set, catalog: catalog) + unknown
    }
}
