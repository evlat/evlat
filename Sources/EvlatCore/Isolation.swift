import Foundation

/// Is this process kept apart from the user's own? One predicate for
/// the setup's writers — the setup's "shown" mark, the login item — and
/// for the setup opening by itself.
///
/// Any `EVLAT_` key counts, set to anything (blank included): a measurement,
/// a test or a look by eye names at least one (`EVLAT_PORT`, `EVLAT_HOME`,
/// `EVLAT_EDGE`…), and a variable added tomorrow isolates without this list
/// learning its name. The one exception is `EVLAT_TASK`, which Evlat hands
/// its own chats' `claude -p` turns: it says nothing about this process.
///
/// Today's writers (edge, shortcut, permission mode, machines) keep their own
/// rules, each tested where it is written; this predicate does not replace them.
public enum Isolation {
    /// The keys that do not isolate.
    public static let exempt: Set<String> = ["EVLAT_TASK"]

    public static func isIsolated(_ environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("EVLAT_") && !exempt.contains($0) }
    }
}
