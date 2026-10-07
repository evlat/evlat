import Foundation
import EvlatCore

/// Codex's `PermissionRequest`, held on the card — on a server only. The
/// hook is the core's command group (`ApprovalHook`), on Codex's own path.
///
/// Measured, interactive (codex-cli 0.160.0):
///
/// - **The dialog waits for the hook**: the terminal says "Running hook"
///   and asks only once the hook is done. On this Mac, with Evlat open,
///   every Codex permission would wait on the bar first — so the group is
///   installed on servers only (`installs`), where the bar is the point.
/// - `"behavior":"allow"` ran the command with no dialog; `"behavior":
///   "deny"` with a `message` blocked it. Empty stdout, `{}`, text that is
///   not JSON, an exit 1 or the hook's time running out is no decision: the
///   dialog comes.
/// - **An exit 2 is a deny** ("Blocked by hook"), where Claude Code reads it
///   as no decision: the command's `|| true` carries that weight.
/// - Esc ends the turn while the hook's process lives on: the connection is
///   not closed, and the request is let go by the `Interrupt` that follows,
///   which the adapter reads as `Stop` (`ApprovalHook.resolves`).
/// - The body is Claude Code's shape (`session_id`, `turn_id`, `cwd`,
///   `tool_name`, `tool_input.command`), with no `permission_suggestions`
///   and no question tool. `updatedInput`, `updatedPermissions` and
///   `interrupt` fail closed (its source), so none is ever sent.
struct CodexApprovals: ApprovalChannel {
    /// Codex asks no question through it.
    func isQuestion(_ tool: String) -> Bool { false }

    /// Through Codex's adapter, then read as Claude's is: the shapes are
    /// the same once canonical. No question and no grant is kept: the
    /// answer can carry neither.
    func request(json: [String: Any]) -> HeldRequest? {
        guard let read = HeldRequest(json: CodexHookAdapter.canonical(json), token: nil) else { return nil }
        return HeldRequest(id: read.id, token: nil, tool: read.tool, subject: read.subject, command: read.command,
                           sessionID: read.sessionID, cwd: read.cwd, subagent: read.subagent)
    }

    /// Allow once or Deny, in the two shapes measured; anything else —
    /// a question's answer, which Codex never asks for — is no decision.
    func body(_ decision: ChatDecision) -> String {
        let inner: [String: Any]
        switch decision {
        case .allow, .allowForSession:
            inner = ["behavior": "allow"]
        case .deny:
            inner = ["behavior": "deny", "message": PermissionHook.deniedMessage]
        case .answer:
            return "{}"
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner]]
        let data = (try? JSONSerialization.data(withJSONObject: output,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    let path = ApprovalHook.path + "/codex"

    /// Two minutes: the dialog waits for the hook, so this is how long a
    /// turn can stand still before the terminal asks on its own.
    let timeout = 120

    let installs: Set<HookTarget> = [.server]
}
