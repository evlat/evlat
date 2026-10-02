import Foundation
import EvlatCore

/// Claude Code. Its vocabulary is the canonical one, so its hooks need no
/// translation; its status line and its approvals are documented.
struct Claude: Agent {
    let id = AgentID("claude")

    let presence = [".claude"]

    /// The path is `/hook` and it cannot move: it is written into the
    /// command already installed in the user's settings file.
    /// `/hook/claude` is accepted as well, as a synonym v1 accepted.
    ///
    /// The events are byte for byte v1's list. `SubagentStart` and
    /// `SubagentStop` are left out on purpose: a subagent's tool events
    /// already arrive on the parent's row (`HooksProvider`).
    let hooks = HookChannel(
        paths: [RouteTable.installedPrefix, RouteTable.installedPrefix + "/claude"],
        events: ["SessionStart", "SessionEnd", "UserPromptSubmit",
                 "PreToolUse", "PostToolUse", "PostToolUseFailure",
                 "PermissionRequest", "PermissionDenied",
                 "Notification", "Stop", "StopFailure"])

    /// Hooks and status line share `settings.json`; a server gets the
    /// status line too.
    let integration = AgentIntegration.Parts(
        hooksFile: ".claude/settings.json",
        relay: AgentIntegration.Relay(file: ".claude/settings.json", onServers: true))

    /// Claude Code's documented status line input: `.official`.
    let statusLineUsage: StatusLineUsage? = StatusLineUsage(
        path: "/usage/claude", providerID: "claude-usage", group: "Claude", fidelity: .official,
        root: "rate_limits",
        windows: [.init("five_hour", minutes: 300), .init("seven_day", minutes: 10080)],
        reading: .usedPercentage)

    let approvals: (any ApprovalChannel)? = ClaudeApprovals()

    let chat: (any ChatBackend)? = ClaudeChat()

    let display = AgentDisplay(nameKey: "source.claude", outline: Self.outline)

    /// `~/.claude/sessions/<pid>.json`, as `SessionsProvider` reads it here:
    /// on a server it finds the process a remote row's session runs in.
    let sessionRecords: SessionRecords? = SessionRecords(
        directory: ".claude/sessions", idKey: "sessionId", pidKey: "pid",
        startedAtKey: "startedAt")

    /// Its session records (`~/.claude/sessions`): discovery, name, pid.
    func providers(_ context: ProviderContext) -> [Provider] {
        [SessionsProvider(directory: context.sessionRecords ?? SessionsProvider.defaultDirectory(home: context.home),
                          platform: context.platform, source: id, excluding: context.excludingSessions)]
    }
}

/// Claude Code's `PermissionRequest`, held on the card: the request and the
/// answer are its documented http hook's (`ApprovalHook`, `PermissionHook`).
struct ClaudeApprovals: ApprovalChannel {
    func isQuestion(_ tool: String) -> Bool { tool == AskQuestion.tool }

    func request(json: [String: Any]) -> HeldRequest? { HeldRequest(json: json, token: nil) }

    func body(_ decision: ChatDecision) -> String { PermissionHook.body(decision) }

    func state(of settings: [String: Any]) -> HookSettings.State { ApprovalHook.state(of: settings) }

    func installing(into settings: [String: Any]) -> [String: Any] { ApprovalHook.installing(into: settings) }

    func removing(from settings: [String: Any]) -> [String: Any] { ApprovalHook.removing(from: settings) }
}
