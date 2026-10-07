import Foundation

/// Is this process kept apart from the user's own? One predicate for
/// the setup's writers — the setup's "shown" mark, the login item — and
/// for the setup opening by itself.
///
/// Any `EVLAT_` key counts, set to anything (blank included): a measurement,
/// a test or a look by eye names at least one (`EVLAT_SOCKET`, `EVLAT_HOME`,
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

    /// Is this a second Evlat beside the user's — a test's, a measurement's,
    /// the demo's? Then it has a socket of its own (`EVLAT_SOCKET`, non-blank)
    /// and takes none of the user's state: no chat store, no tunnel to the
    /// user's servers, no keychain, no sandboxes, no stored switches. The
    /// one predicate those rules ask, each unless its own variable is given
    /// (`EVLAT_CHATS`, `EVLAT_MACHINES`, `EVLAT_SANDBOX_PORT`…).
    ///
    /// Narrower than `isIsolated` on purpose: `EVLAT_HOME` or
    /// `EVLAT_SESSIONS` alone moves where files are read, not whose Evlat
    /// this is.
    public static func hasOwnSocket(_ environment: [String: String]) -> Bool {
        !(environment[EvlatSocket.environmentKey]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    /// The variable that once gave a second Evlat its own port. There is no
    /// port to give now, and a recipe that still sets it would run a second
    /// Evlat on the user's socket and state: such a process refuses to start
    /// (`LaunchMode.refused`).
    public static let retiredPortKey = "EVLAT_PORT"

    /// The one line a process with `retiredPortKey` set says before it exits.
    public static let retiredPortLine = "\(retiredPortKey) is gone; use \(EvlatSocket.environmentKey)"

    /// Set at all, blank included: any recipe that names it is an old one.
    public static func setsRetiredPort(_ environment: [String: String]) -> Bool {
        environment[retiredPortKey] != nil
    }
}
