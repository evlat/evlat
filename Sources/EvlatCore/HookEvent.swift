import Foundation

/// The typed view of a hook body. Fields are read from the **canonical**
/// vocabulary (Claude Code's); another source's body arrives here after
/// `AgentSource.canonical`.
///
/// Only what `002` needs is read. v1 also carried `tool_name`, `tool_input`,
/// `message`, `last_assistant_message`, `error` and `stop_hook_active`'s
/// neighbours, but those fed bubbles, tool summaries and voice lines — none of
/// which v2 has yet. They were left out deliberately, not overlooked; a phase
/// that needs one adds it next to these.
///
/// **A missing or empty field is `nil`.** The typed view invents no stand-in:
/// v1 called a session without an id `"unknown"`, which quietly merged every
/// such event onto a single row. `name` is the one exception and its default is
/// the empty string, because an event with no name matches no rule anywhere and
/// so cannot be mistaken for one.
public struct HookEvent: Equatable {
    /// `hook_event_name`, canonical spelling. Kept as text rather than an enum:
    /// a name this version does not know stays **visible** instead of being
    /// swallowed by a `default:` at the parse step.
    public let name: String
    /// `session_id`. This is the `Signal.entity` the row is merged on, and both
    /// sources produce a UUID for it.
    public let sessionID: String?
    public let cwd: String?
    /// `agent_id`. Filled when a subagent produced the event; whether such
    /// events are used is `phase-4`'s rule, decided on a measurement.
    public let agentID: String?
    /// `notification_type`. Which values block the user is `phase-4`'s rule.
    public let notificationType: String?
    /// Claude Code sets this when the `Stop` hook is itself what continued the
    /// session; treating it as a real stop loops.
    public let stopHookActive: Bool
    /// The Evlat errand that produced this event, from `X-Evlat-Task`.
    /// **Absent** in the user's own sessions rather than empty: with
    /// `EVLAT_TASK` unset the installed command's value expands to nothing and
    /// curl then drops the header instead of sending it blank (measured,
    /// curl 8.7.1). Both readings land on `nil`, so only the comment was wrong.
    public let taskID: String?
    /// The agent process that sent the event, from `X-Evlat-Pid`. A source that
    /// keeps no file record has nothing else to prove it is still alive.
    public let pid: Int32?
    /// Where the event came from; a session takes it from its first event.
    public let source: AgentSource

    /// The key under which the server writes the `X-Evlat-Task` header.
    public static let taskKey = "evlat_task"

    /// The key under which the server writes the `X-Evlat-Pid` header.
    public static let pidKey = "evlat_pid"

    /// `.claude` by default: fixtures are written in the canonical vocabulary
    /// and naming the source each time would only repeat it.
    public init(json: [String: Any], source: AgentSource = .claude) {
        self.source = source
        name = json["hook_event_name"] as? String ?? ""
        sessionID = Self.text(json["session_id"])
        cwd = Self.text(json["cwd"])
        agentID = Self.text(json["agent_id"])
        notificationType = Self.text(json["notification_type"])
        stopHookActive = json["stop_hook_active"] as? Bool ?? false
        taskID = Self.text(json[Self.taskKey])
        // The pid arrives as text, because the header it comes from is text.
        // Anything that is not a plausible process is ignored: a session's
        // whereabouts are resolved by walking up from this pid, and `1`
        // (launchd) or `0` would send that walk somewhere no agent ever ran.
        if let text = Self.text(json[Self.pidKey]), let value = Int32(text), value > 1 {
            pid = value
        } else {
            pid = nil
        }
    }

    /// A string field, with empty read as absent. The header case cannot
    /// actually produce an empty value — curl omits `X-Evlat-Task` entirely
    /// when `EVLAT_TASK` is unset — but a **body** field can still arrive as
    /// `""`, and the two must read the same.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
