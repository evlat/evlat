import Foundation

/// Approving a terminal session's permission from the bar: the routes an
/// agent's approval hook posts to (`Agent.approvals`), the one group that
/// is installed to send them, and how a held request is learnt to be over.
/// What is here reads only the canonical vocabulary and names no agent: an
/// agent's channel gives the path and the timeout.
///
/// Evlat holds the request (`HookListener`) until the user presses Allow or
/// Deny on the detail card, or until the request is answered elsewhere: the
/// terminal's own dialog is up at the same time, and an answer there does
/// not always close the held connection, so `resolves` learns of it from the
/// events that follow. Requests are serialized per session, and the body has
/// no `tool_use_id`, so a request is matched to its outcome by session,
/// actor, tool and subject — and by machine: a request is the listener's
/// that heard it, and only that listener's events speak about it.
public enum ApprovalHook {
    /// Every approval path starts with this.
    public static let path = "/approval"

    // MARK: - The installed group

    /// The one event the group is installed under.
    static let event = "PermissionRequest"

    /// The command, the same bytes on this Mac and on a server: it speaks to
    /// the socket under the home it runs in (`EvlatSocket.Curl.homeSocket`)
    /// and prints the server's answer, which is the decision. Nothing else
    /// reaches stdout: `-f` writes no error body, `2>/dev/null` keeps
    /// `curl`'s complaints off it, and `|| true` makes every failure — no
    /// socket, a refusal, a closed connection, the time running out — an
    /// exit 0 with empty stdout, which is no decision: the agent's own
    /// dialog decides. `-m` is the channel's timeout, the hook's own too.
    public static func command(for channel: some ApprovalChannel) -> String {
        let curl = EvlatSocket.Curl.self
        return "\(curl.program) -sf \(curl.noProxy) \(curl.homeSocket) -m \(channel.timeout)"
            + " -H 'Content-Type: application/json' --data-binary @- \(curl.url(channel.path)) 2>/dev/null || true"
    }

    /// The hook this writer installs; the golden test pins Claude's.
    public static func installedHook(for channel: some ApprovalChannel) -> [String: Any] {
        ["type": "command", "command": command(for: channel), "timeout": channel.timeout]
    }

    /// Ours: the command posting to the channel's url — the same url the
    /// command is built with, so the two cannot drift — or the `type:
    /// "http"` hook every copy before the socket installed at that url,
    /// Evlat's older one. The space after the url keeps another agent's
    /// longer path (`/approval/…`) from reading as this one's.
    private static func isOurs(_ hook: [String: Any], _ channel: some ApprovalChannel) -> Bool {
        let url = EvlatSocket.Curl.url(channel.path)
        switch hook["type"] as? String {
        case "command": return (hook["command"] as? String)?.contains(url + " ") == true
        case "http": return hook["url"] as? String == url
        default: return false
        }
    }

    private static func hooks(of group: Any) -> [[String: Any]]? {
        (group as? [String: Any])?["hooks"] as? [[String: Any]]
    }

    private static func holdsOurs(_ group: Any, _ channel: some ApprovalChannel) -> Bool {
        hooks(of: group)?.contains { isOurs($0, channel) } == true
    }

    /// Current only as exactly one of today's hook; an old http one,
    /// another timeout or two copies are outdated, which offers the install
    /// that replaces them.
    public static func state(of settings: [String: Any], for channel: some ApprovalChannel) -> HookSettings.State {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        let ours = groups.flatMap { hooks(of: $0) ?? [] }.filter { isOurs($0, channel) }
        guard !ours.isEmpty else { return .missing }
        guard ours.count == 1, NSDictionary(dictionary: ours[0]).isEqual(to: installedHook(for: channel)) else {
            return .outdated
        }
        return .current
    }

    /// Our first hook is replaced where it stands, any further one dropped;
    /// whatever else a group holds — another tool's hook beside ours, its
    /// `matcher` — stays, and a group left with no hook goes. Other tools'
    /// groups keep their index (`HookSettings.installing`'s rule).
    public static func installing(into settings: [String: Any], for channel: some ApprovalChannel) -> [String: Any] {
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        guard hooks[event] == nil || hooks[event] is [Any] else { return settings }
        let groups = hooks[event] as? [Any] ?? []
        guard let first = groups.firstIndex(where: { holdsOurs($0, channel) }) else {
            hooks[event] = groups + [["hooks": [installedHook(for: channel)]]]
            var result = settings
            result["hooks"] = hooks
            return result
        }
        hooks[event] = groups.enumerated().compactMap { index, group -> Any? in
            guard holdsOurs(group, channel), var object = group as? [String: Any],
                  let inside = Self.hooks(of: group) else { return group }
            var kept: [[String: Any]] = []
            var placed = false
            for hook in inside {
                if !isOurs(hook, channel) {
                    kept.append(hook)
                } else if index == first && !placed {
                    kept.append(installedHook(for: channel))
                    placed = true
                }
            }
            guard !kept.isEmpty else { return nil }
            object["hooks"] = kept
            return object
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    /// Ours go, old and new, and nothing else: a group keeps another
    /// tool's hook beside ours, and goes only when ours was all it held;
    /// an event key emptied goes with them.
    public static func removing(from settings: [String: Any], for channel: some ApprovalChannel) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any],
              let groups = hooks[event] as? [Any], groups.contains(where: { holdsOurs($0, channel) }) else {
            return settings
        }
        let kept = groups.compactMap { group -> Any? in
            guard holdsOurs(group, channel), var object = group as? [String: Any],
                  let inside = Self.hooks(of: group) else { return group }
            let others = inside.filter { !isOurs($0, channel) }
            guard !others.isEmpty else { return nil }
            object["hooks"] = others
            return object
        }
        hooks[event] = kept.isEmpty ? nil : kept
        var result = settings
        result["hooks"] = hooks
        return result
    }

    // MARK: - Resolution

    /// Events that end a turn: whatever was pending in it is over, whoever
    /// asked.
    static let turnEnders: Set<String> = ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"]
    /// Events that are the outcome of one tool call. `PreToolUse` is not
    /// here: it comes *before* the permission check. Nor are `Notification`
    /// and `PermissionRequest`: the installed command posts the same
    /// request's `PermissionRequest` on its own connection, at any moment.
    static let toolOutcomes: Set<String> = ["PostToolUse", "PostToolUseFailure", "PermissionDenied"]

    /// Has `event`, heard on `machine`'s listener (`nil`: this Mac's), shown
    /// that `request` was answered somewhere else? A session id is the
    /// agent's and could come from any computer: only the request's own
    /// machine speaks about it.
    public static func resolves(_ request: HeldRequest, by event: HookEvent, machine: String? = nil) -> Bool {
        guard request.machine == machine, let session = request.sessionID, event.sessionID == session else {
            return false
        }
        if turnEnders.contains(event.name) { return true }
        guard toolOutcomes.contains(event.name) else { return false }
        return event.agentID == request.subagent && event.toolName == request.tool
            && event.toolSubject == request.subject
    }

    /// A newer request from the same actor, on the same machine, replaces an
    /// older one: requests are serialized, so the older was answered.
    public static func supersedes(_ newer: HeldRequest, _ older: HeldRequest) -> Bool {
        newer.id != older.id && newer.sessionID != nil && newer.sessionID == older.sessionID
            && newer.subagent == older.subagent && newer.machine == older.machine
    }
}
