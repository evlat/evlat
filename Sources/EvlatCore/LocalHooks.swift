import Foundation

/// An agent's hooks, as the settings' one row: the command, in the agent's
/// file shape (`Parts.format`), and, where the agent's approvals are
/// installed on that target (`ApprovalChannel.installs`), the approval
/// group (`ApprovalHook`) together — installed, read and removed as one,
/// one switch, not a setting per hook.
///
/// The transformations are shared with a server's (`RemoteSettings`), which
/// passes `.server`.
public enum LocalHooks {
    public typealias State = HookSettings.State

    /// Current only when both are; missing only when both are. Anything in
    /// between is outdated, which is what offers the install that completes
    /// it — how a copy that had the command alone learns of approvals.
    public static func state(of settings: [String: Any], for agent: some Agent, target: HookTarget) -> State {
        let command = agent.integration.format.state(of: settings, hooks: agent.hooks)
        guard let channel = approvals(of: agent, on: target) else { return command }
        let approval = ApprovalHook.state(of: settings, for: channel)
        if command == .current && approval == .current { return .current }
        if command == .missing && approval == .missing { return .missing }
        return .outdated
    }

    public static func installing(into settings: [String: Any], for agent: some Agent,
                                  target: HookTarget) -> [String: Any] {
        let command = agent.integration.format.installing(into: settings, hooks: agent.hooks)
        guard let channel = approvals(of: agent, on: target) else { return command }
        return ApprovalHook.installing(into: command, for: channel)
    }

    /// The approval group goes wherever it was installed from: only Evlat's
    /// own, so taking it from a target that would not get it is harmless.
    public static func removing(from settings: [String: Any], for agent: some Agent) -> [String: Any] {
        let command = agent.integration.format.removing(from: settings, hooks: agent.hooks)
        guard let channel = agent.approvals, !channel.installs.isEmpty else { return command }
        return ApprovalHook.removing(from: command, for: channel)
    }

    /// The agent's approvals, when the core's group is installed on `target`.
    public static func approvals(of agent: some Agent, on target: HookTarget) -> (any ApprovalChannel)? {
        agent.approvals.flatMap { $0.installs.contains(target) ? $0 : nil }
    }

    /// What a user pastes by hand for this Mac: the writer's bytes into an
    /// empty file.
    public static func manual(for source: some Agent) -> String {
        String(decoding: (try? SettingsFile.encode(installing(into: [:], for: source, target: .mac))) ?? Data(),
               as: UTF8.self)
    }

    // MARK: - Files

    /// This Mac's file: the approval hook goes with the command.
    public static func state(at url: URL, for source: some Agent) throws -> State {
        state(of: try SettingsFile.read(url), for: source, target: .mac)
    }

    /// One write for both, so the file is never left with half of them.
    ///
    /// The hooks folder is made here when the agent's rule says so
    /// (`Parts.opensHooksDirectory`): a shared folder that does not say the
    /// agent is installed need not exist yet. A folder that is the agent's
    /// own never is.
    @discardableResult
    public static func install(at url: URL, for source: some Agent) throws -> SettingsFile.Outcome {
        if source.integration.opensHooksDirectory {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        let outcome = try SettingsFile.apply(at: url) { installing(into: $0, for: source, target: .mac) }
        if outcome == .unchanged, try state(at: url, for: source) != .current { throw SettingsFile.Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL, for source: some Agent) throws -> SettingsFile.Outcome {
        try SettingsFile.apply(at: url) { removing(from: $0, for: source) }
    }
}
