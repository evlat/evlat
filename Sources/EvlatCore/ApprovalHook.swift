import Foundation

/// Approving a terminal session's permission from the bar: a second
/// installed hook, opt-in, beside the command `HookSettings` writes.
///
/// It is Claude Code's documented `type: "http"` `PermissionRequest` hook,
/// pointed at `path`. Evlat holds the request (`HookListener`) until the user
/// presses Allow or Deny on the detail card, or until the request is answered
/// elsewhere. Measured on Claude Code 2.1.285, interactive:
///
/// - The terminal's own dialog appears **at the same time** as the hook: the
///   terminal is never blocked. Whichever answers first wins.
/// - A refused connection (Evlat closed), a dropped one, or `{}` is no
///   decision: the dialog stays and the terminal decides.
/// - "No" or Esc in the terminal closes the held connection (the listener
///   reports it abandoned); **"Yes" in the terminal does not** — the
///   connection stays open until the hook's timeout. `resolves` is how Evlat
///   learns of it from the events that follow.
/// - A decision sent after the terminal answered is ignored (a late deny left
///   the running command alone).
/// - Requests are serialized per session: the next one comes only after this
///   one is answered.
/// - The body has no `tool_use_id`, so a request is matched to its outcome by
///   session, actor, tool and subject.
///
/// The hook authenticates nobody: whoever holds the port while Evlat is
/// closed could answer it. Accepted for now (a same-user process can write
/// the settings file anyway); the risk is another user's process on a
/// shared Mac. Off unless the user turns it on.
public enum ApprovalHook {
    public static let path = "/approval"
    /// Written out, as `PermissionHook.timeout` is, so a change of default
    /// does not change how long a card can wait.
    public static let timeout = 600
    /// The fixed point, like the installed command: `defaultPort`, never an
    /// override.
    public static var url: String { "http://127.0.0.1:\(LocalAPI.defaultPort)\(path)" }

    /// The one hook this writer installs; the golden test pins it.
    public static var installedHook: [String: Any] {
        ["type": "http", "url": url, "timeout": timeout]
    }

    static let event = "PermissionRequest"

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
    public static func resolves(_ request: PermissionHook.Request, by event: HookEvent) -> Bool {
        guard let session = request.sessionID, event.sessionID == session else { return false }
        if turnEnders.contains(event.name) { return true }
        guard toolOutcomes.contains(event.name) else { return false }
        return event.agentID == request.agentID && event.toolName == request.tool
            && event.toolSubject == request.subject
    }

    /// A newer request from the same actor replaces an older one: requests
    /// are serialized, so the older was answered.
    public static func supersedes(_ newer: PermissionHook.Request, _ older: PermissionHook.Request) -> Bool {
        newer.id != older.id && newer.sessionID != nil && newer.sessionID == older.sessionID
            && newer.agentID == older.agentID
    }

    // MARK: - The settings (pure)

    public typealias State = HookSettings.State

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        hook["type"] as? String == "http" && hook["url"] as? String == url
    }

    private static func isOurs(_ group: Any) -> Bool {
        guard let group = group as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isOurs)
    }

    public static func state(of settings: [String: Any]) -> State {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        let ours = groups.compactMap { $0 as? [String: Any] }
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter(isOurs)
        guard !ours.isEmpty else { return .missing }
        guard ours.count == 1, ours[0]["timeout"] as? Int == timeout else { return .outdated }
        return .current
    }

    /// Our first group is replaced in place, any further one dropped; other
    /// tools' groups keep their index (`HookSettings.installing`'s rule).
    public static func installing(into settings: [String: Any]) -> [String: Any] {
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        guard hooks[event] == nil || hooks[event] is [Any] else { return settings }
        let ours: [String: Any] = ["matcher": "*", "hooks": [installedHook]]
        let groups = hooks[event] as? [Any] ?? []
        if let first = groups.firstIndex(where: isOurs) {
            hooks[event] = groups.enumerated().compactMap { index, group -> Any? in
                index == first ? ours : (isOurs(group) ? nil : group)
            }
        } else {
            hooks[event] = groups + [ours]
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    public static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any],
              let groups = hooks[event] as? [Any], groups.contains(where: isOurs) else { return settings }
        let kept = groups.filter { !isOurs($0) }
        hooks[event] = kept.isEmpty ? nil : kept
        var result = settings
        result["hooks"] = hooks
        return result
    }

    // MARK: - Files

    public static func state(at url: URL) throws -> State {
        state(of: try SettingsFile.read(url))
    }

    @discardableResult
    public static func install(at url: URL) throws -> SettingsFile.Outcome {
        let outcome = try SettingsFile.apply(at: url) { installing(into: $0) }
        if outcome == .unchanged, try state(at: url) != .current { throw SettingsFile.Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL) throws -> SettingsFile.Outcome {
        try SettingsFile.apply(at: url) { removing(from: $0) }
    }
}
