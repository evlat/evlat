import Foundation
import EvlatCore

/// The Codex CLI. Its hooks are shaped like Claude Code's and translated
/// where they were measured to differ (`CodexHookAdapter`); its usage is read
/// from its own session log, not a status line.
struct Codex: Agent {
    let id = AgentID("codex")

    let presence = [".codex"]

    /// `Interrupt` is there because Codex sends no `Stop` on an interrupt;
    /// the adapter translates it.
    let hooks = HookChannel(
        paths: [RouteTable.installedPrefix + "/codex"],
        events: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                 "PermissionRequest", "Stop", "Interrupt"],
        canonical: CodexHookAdapter.canonical)

    let integration = AgentIntegration.Parts(hooksFile: ".codex/hooks.json")

    /// No status line: its windows come from its own file (`providers`).
    let statusLineUsage: StatusLineUsage? = nil

    /// Its permission requests, on a server's card (`CodexApprovals`).
    let approvals: (any ApprovalChannel)? = CodexApprovals()

    /// Its app-server, as the chat bubble's second backend.
    let chat: (any ChatBackend)? = CodexChat()

    let display = AgentDisplay(nameKey: "source.codex", outline: Self.outline)

    /// Its rate-limit windows, read from its newest rollout file.
    func providers(_ context: ProviderContext) -> [Provider] {
        [CodexUsageProvider(home: context.home)]
    }
}
