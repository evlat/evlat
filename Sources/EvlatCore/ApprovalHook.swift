import Foundation

/// Approving a terminal session's permission from the bar: the fixed route
/// an agent's approval hook posts to (`Agent.approvals`), and how a held
/// request is learnt to be over. The hook's installed bytes are the agent's
/// own; what is here reads only the canonical vocabulary.
///
/// Evlat holds the request (`HookListener`) until the user presses Allow or
/// Deny on the detail card, or until the request is answered elsewhere: the
/// terminal's own dialog is up at the same time, and an answer there does
/// not always close the held connection, so `resolves` learns of it from the
/// events that follow. Requests are serialized per session, and the body has
/// no `tool_use_id`, so a request is matched to its outcome by session,
/// actor, tool and subject.
public enum ApprovalHook {
    public static let path = "/approval"

    // MARK: - Resolution

    /// Events that end a turn: whatever was pending in it is over, whoever
    /// asked.
    static let turnEnders: Set<String> = ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"]
    /// Events that are the outcome of one tool call. `PreToolUse` is not
    /// here: it comes *before* the permission check. Nor are `Notification`
    /// and `PermissionRequest`: the installed command posts the same
    /// request's `PermissionRequest` on its own connection, at any moment.
    static let toolOutcomes: Set<String> = ["PostToolUse", "PostToolUseFailure", "PermissionDenied"]

    /// Has `event` shown that `request` was answered somewhere else?
    public static func resolves(_ request: HeldRequest, by event: HookEvent) -> Bool {
        guard let session = request.sessionID, event.sessionID == session else { return false }
        if turnEnders.contains(event.name) { return true }
        guard toolOutcomes.contains(event.name) else { return false }
        return event.agentID == request.agentID && event.toolName == request.tool
            && event.toolSubject == request.subject
    }

    /// A newer request from the same actor replaces an older one: requests
    /// are serialized, so the older was answered.
    public static func supersedes(_ newer: HeldRequest, _ older: HeldRequest) -> Bool {
        newer.id != older.id && newer.sessionID != nil && newer.sessionID == older.sessionID
            && newer.agentID == older.agentID
    }
}
