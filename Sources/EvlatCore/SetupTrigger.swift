import Foundation

/// Whether the setup opens by itself at launch (`014`, R9). Only once, and
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
}
