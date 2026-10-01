import Foundation

/// An agent's hooks, as the settings' one row: the command
/// (`HookSettings`) and, where the agent supports it and the target takes
/// it, the approval hook (`ApprovalHook`) together — installed, read and
/// removed as one, one switch, not a setting per hook. Antigravity's file has
/// a shape of its own (`AntigravityHooks`); this is the one place that tells
/// the file shapes apart.
///
/// The transformations are shared with a server's (`RemoteSettings`), which
/// passes `approvals: false`: its approval route is `404` through the tunnel.
public enum LocalHooks {
    public typealias State = HookSettings.State

    /// Current only when both are; missing only when both are. Anything in
    /// between is outdated, which is what offers the install that completes
    /// it — how a copy that had the command alone learns of approvals.
    public static func state(of settings: [String: Any], for source: AgentSource, approvals: Bool) -> State {
        if source == .antigravity { return AntigravityHooks.state(of: settings) }
        let command = HookSettings.state(of: settings, for: source)
        guard approvals && source.supportsApprovals else { return command }
        let approval = ApprovalHook.state(of: settings)
        if command == .current && approval == .current { return .current }
        if command == .missing && approval == .missing { return .missing }
        return .outdated
    }

    public static func installing(into settings: [String: Any], for source: AgentSource,
                                  approvals: Bool) -> [String: Any] {
        if source == .antigravity { return AntigravityHooks.installing(into: settings) }
        let command = HookSettings.installing(into: settings, for: source)
        return approvals && source.supportsApprovals ? ApprovalHook.installing(into: command) : command
    }

    public static func removing(from settings: [String: Any], for source: AgentSource,
                                approvals: Bool) -> [String: Any] {
        if source == .antigravity { return AntigravityHooks.removing(from: settings) }
        let command = HookSettings.removing(from: settings, for: source)
        return approvals && source.supportsApprovals ? ApprovalHook.removing(from: command) : command
    }

    /// What a user pastes by hand for this Mac: the writer's bytes into an
    /// empty file.
    public static func manual(for source: AgentSource) -> String {
        String(decoding: (try? SettingsFile.encode(installing(into: [:], for: source, approvals: true))) ?? Data(),
               as: UTF8.self)
    }

    // MARK: - Files

    /// This Mac's file: the approval hook goes with the command.
    public static func state(at url: URL, for source: AgentSource) throws -> State {
        state(of: try SettingsFile.read(url), for: source, approvals: true)
    }

    /// One write for both, so the file is never left with half of them.
    ///
    /// The hooks folder is made here when the agent's rule says so
    /// (`AgentSource.opensHooksDirectory`): Antigravity's is not the one
    /// that says it is installed and need not exist yet. Claude's and
    /// Codex's folder is the agent's own and never is.
    @discardableResult
    public static func install(at url: URL, for source: AgentSource) throws -> SettingsFile.Outcome {
        if source.opensHooksDirectory {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        let outcome = try SettingsFile.apply(at: url) { installing(into: $0, for: source, approvals: true) }
        if outcome == .unchanged, try state(at: url, for: source) != .current { throw SettingsFile.Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL, for source: AgentSource) throws -> SettingsFile.Outcome {
        try SettingsFile.apply(at: url) { removing(from: $0, for: source, approvals: true) }
    }
}
