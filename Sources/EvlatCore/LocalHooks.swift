import Foundation

/// This Mac's hooks for an agent, as the settings' one row: for Claude the
/// command (`HookSettings`) and the approval hook (`ApprovalHook`) together,
/// installed, read and removed as one — one switch, not a setting per hook.
/// Codex is its command alone; Antigravity's file has a shape of its own
/// (`AntigravityHooks`). This is the one place that tells them apart.
///
/// Local only. A remote machine's hooks are `HookSettings`' alone
/// (`RemoteSettings`): its approval route is `404` through the tunnel.
public enum LocalHooks {
    public typealias State = HookSettings.State

    static func hasApprovals(_ source: AgentSource) -> Bool { source == .claude }

    /// Current only when both are; missing only when both are. Anything in
    /// between is outdated, which is what offers the install that completes
    /// it — how a copy that had the command alone learns of approvals.
    public static func state(of settings: [String: Any], for source: AgentSource) -> State {
        if source == .antigravity { return AntigravityHooks.state(of: settings) }
        let command = HookSettings.state(of: settings, for: source)
        guard hasApprovals(source) else { return command }
        let approvals = ApprovalHook.state(of: settings)
        if command == .current && approvals == .current { return .current }
        if command == .missing && approvals == .missing { return .missing }
        return .outdated
    }

    public static func installing(into settings: [String: Any], for source: AgentSource) -> [String: Any] {
        if source == .antigravity { return AntigravityHooks.installing(into: settings) }
        let command = HookSettings.installing(into: settings, for: source)
        return hasApprovals(source) ? ApprovalHook.installing(into: command) : command
    }

    public static func removing(from settings: [String: Any], for source: AgentSource) -> [String: Any] {
        if source == .antigravity { return AntigravityHooks.removing(from: settings) }
        let command = HookSettings.removing(from: settings, for: source)
        return hasApprovals(source) ? ApprovalHook.removing(from: command) : command
    }

    /// What a user pastes by hand for this Mac: the writer's bytes into an
    /// empty file.
    public static func manual(for source: AgentSource) -> String {
        String(decoding: (try? SettingsFile.encode(installing(into: [:], for: source))) ?? Data(), as: UTF8.self)
    }

    // MARK: - Files

    public static func state(at url: URL, for source: AgentSource) throws -> State {
        state(of: try SettingsFile.read(url), for: source)
    }

    /// One write for both, so the file is never left with half of them.
    ///
    /// Antigravity's hooks folder is not the one that says it is installed
    /// (`AgentSource.isPresent`) and need not exist yet, so it is made here;
    /// Claude's and Codex's folder is the agent's own and never is.
    @discardableResult
    public static func install(at url: URL, for source: AgentSource) throws -> SettingsFile.Outcome {
        if source == .antigravity {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        let outcome = try SettingsFile.apply(at: url) { installing(into: $0, for: source) }
        if outcome == .unchanged, try state(at: url, for: source) != .current { throw SettingsFile.Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL, for source: AgentSource) throws -> SettingsFile.Outcome {
        try SettingsFile.apply(at: url) { removing(from: $0, for: source) }
    }
}
