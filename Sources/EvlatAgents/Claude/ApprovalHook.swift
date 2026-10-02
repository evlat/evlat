import Foundation
import EvlatCore

/// Approving a terminal session's permission from the bar: a second
/// installed hook beside the command `HookSettings` writes, installed and
/// removed with it as one row (`LocalHooks`).
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
/// shared Mac.
extension ApprovalHook {
    /// Written out, as `PermissionHook.timeout` is, so a change of default
    /// does not change how long a card can wait.
    static let timeout = 600
    /// The fixed point, like the installed command: `defaultPort`, never an
    /// override.
    static var url: String { "http://127.0.0.1:\(LocalAPI.defaultPort)\(path)" }

    /// The one hook this writer installs; the golden test pins it.
    static var installedHook: [String: Any] {
        ["type": "http", "url": url, "timeout": timeout]
    }

    static let event = "PermissionRequest"

    // MARK: - The settings (pure)

    typealias State = HookSettings.State

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        hook["type"] as? String == "http" && hook["url"] as? String == url
    }

    private static func isOurs(_ group: Any) -> Bool {
        guard let group = group as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isOurs)
    }

    static func state(of settings: [String: Any]) -> State {
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
    static func installing(into settings: [String: Any]) -> [String: Any] {
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

    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any],
              let groups = hooks[event] as? [Any], groups.contains(where: isOurs) else { return settings }
        let kept = groups.filter { !isOurs($0) }
        hooks[event] = kept.isEmpty ? nil : kept
        var result = settings
        result["hooks"] = hooks
        return result
    }
}
