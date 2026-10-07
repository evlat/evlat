import Foundation
import EvlatCore

/// Claude Code's `PermissionRequest`, held on the card. The request and the
/// answer are its documented hook's (`PermissionHook`); the hook is the
/// core's command group (`ApprovalHook`), on this Mac and on a server.
///
/// Measured, interactive (2.1.285 with the http hook it once was, 2.1.292
/// with the command):
///
/// - The terminal's own dialog appears **at the same time** as the hook: the
///   terminal is never blocked. Whichever answers first wins.
/// - Empty stdout, `{}`, an exit that is not 0, or the hook's time running
///   out is no decision: the dialog stays and the terminal decides.
/// - Esc in the terminal ends the hook's process (the held connection
///   closes, and the listener reports it abandoned); **"Yes" in the
///   terminal does not** — the hook lives until its timeout. `resolves` is
///   how Evlat learns of it from the events that follow.
/// - A decision sent after the terminal answered is ignored (a late deny left
///   the running command alone).
/// - Requests are serialized per session: the next one comes only after this
///   one is answered.
/// - The body has no `tool_use_id`, so a request is matched to its outcome by
///   session, actor, tool and subject.
///
/// The hook authenticates nobody: whatever answers on the socket decides.
/// The socket's folder is this user's alone (`0700`), here and on a server,
/// so that is a process of the same user — which could write the settings
/// file anyway.
struct ClaudeApprovals: ApprovalChannel {
    func isQuestion(_ tool: String) -> Bool { tool == AskQuestion.tool }

    func request(json: [String: Any]) -> HeldRequest? { HeldRequest(json: json, token: nil) }

    func body(_ decision: ChatDecision) -> String { PermissionHook.body(decision) }

    /// The path every copy has posted to: it cannot move.
    let path = ApprovalHook.path

    /// Ten minutes: a card can wait while the user is away from the desk.
    let timeout = 600

    /// This Mac and a server alike.
    let installs: Set<HookTarget> = [.mac, .server]
}
