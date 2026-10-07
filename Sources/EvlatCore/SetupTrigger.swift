import Foundation

/// Whether the setup opens by itself at launch. Only once, and
/// only for someone who has set nothing up yet: a v1 user has an edge or
/// hooks, and a measurement or a test is isolated.
public enum SetupTrigger {
    /// - Parameters:
    ///   - hasStorage: the process keeps what it is told (`UserDefaults` and a
    ///     home were handed in); without it the mark could not be kept and
    ///     the setup would open on every launch.
    ///   - seen: the setup has been shown before (`setup.seen`).
    ///   - hasStoredEdge: an edge was ever chosen.
    ///   - hookStates: each present agent's hooks. `.outdated` counts as
    ///     set up: an old command is a user who installed them.
    ///   - environment: `Isolation` reads it.
    public static func shouldOpen(hasStorage: Bool, seen: Bool, hasStoredEdge: Bool,
                                  hookStates: [HookSettings.State],
                                  environment: [String: String]) -> Bool {
        hasStorage && !seen && !hasStoredEdge
            && hookStates.allSatisfy { $0 == .missing }
            && !Isolation.isIsolated(environment)
    }

    /// What the update window does at launch.
    public enum UpdatesAtLaunch: Equatable {
        case nothing
        /// It opens: automatic updates are off.
        case window
        /// Evlat updates its old parts itself, and opens the window only
        /// for what is left to the user (`opensResults`).
        case automatic
    }

    /// At every launch while an agent switched on here holds parts an
    /// older copy wrote (its hooks `.outdated`): the window, or with
    /// automatic updates on (`updates.automatic`) the update itself. Never
    /// while the setup opens — it shows the same cards — and never in an
    /// isolated process, which writes nothing of the user's.
    public static func updatesAtLaunch(hasStorage: Bool, automatic: Bool, outdated: Bool, opensSetup: Bool,
                                       environment: [String: String]) -> UpdatesAtLaunch {
        guard hasStorage, outdated, !opensSetup, !Isolation.isIsolated(environment) else { return .nothing }
        return automatic ? .automatic : .window
    }

    /// Whether automatic updates open the window with what they did: only
    /// when something is left to the user — a step to take (Codex's
    /// `/hooks`), or a write that was refused. Otherwise they are silent.
    public static func opensResults(failed: Bool, stepLeft: Bool) -> Bool {
        failed || stepLeft
    }
}
