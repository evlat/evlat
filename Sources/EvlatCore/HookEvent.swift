import Foundation

/// The typed view of a hook body. Fields are read from the **canonical**
/// vocabulary (Claude Code's); another source's body arrives here after
/// its `HookChannel.canonical`.
///
/// Only what a rule or the detail card reads is kept. The card added
/// `tool_name`, a one-line subject taken from `tool_input`, and
/// `last_assistant_message` — all three measured on Claude Code 2.1.280 and
/// documented. **The raw `tool_input` is not kept**: `Write` carries the whole
/// file in it, so it is reduced to its subject here, at the moment it arrives,
/// and nothing downstream ever holds more. v1's `message` and `error` fed
/// bubbles and voice lines v2 does not have and stay out.
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
    /// events are used is `HooksProvider`'s rule, decided on a measurement.
    public let agentID: String?
    /// `notification_type`. Which values block the user is `HooksProvider`'s rule.
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
    public let source: AgentID
    /// `tool_name`, canonical spelling (the agent's `HookChannel.canonical`
    /// has already translated its own names).
    public let toolName: String?
    /// One line that says what the tool is working on: the first non-blank
    /// value among `subjectKeys` in `tool_input`, first line only, trimmed and
    /// capped at `subjectLimit`. `nil` when the input has none of them.
    public let toolSubject: String?
    /// `last_assistant_message` (on `Stop`), reduced to a one-line preview and
    /// capped at `replyLimit`. Claude's transcript is never read for it;
    /// Antigravity sends no reply, and this Mac's server reads its one from
    /// the transcript's tail (`AntigravityTranscript`).
    public let lastReply: String?

    /// Where a tool's subject is looked for, in order. One list rather than a
    /// table per tool: the keys already say what they hold, and a tool this
    /// version does not know still gets a subject if it uses one of them.
    public static let subjectKeys = ["command", "file_path", "pattern", "url", "query", "description"]

    /// The longest subject kept. A one-line script can be any size.
    public static let subjectLimit = 200

    /// The longest reply kept, in characters. Named so the privacy promise has
    /// a number and a test: the card needs a sentence, not the answer.
    public static let replyLimit = 280

    /// The key under which the server writes the `X-Evlat-Task` header.
    public static let taskKey = "evlat_task"

    /// The key under which the server writes the `X-Evlat-Pid` header.
    public static let pidKey = "evlat_pid"

    /// `json` is in the canonical vocabulary already: the agent's
    /// translation runs before this (`LocalAPI.handle`).
    public init(json: [String: Any], source: AgentID) {
        self.source = source
        name = json["hook_event_name"] as? String ?? ""
        sessionID = Self.text(json["session_id"])
        cwd = Self.text(json["cwd"])
        agentID = Self.text(json["agent_id"])
        notificationType = Self.text(json["notification_type"])
        stopHookActive = json["stop_hook_active"] as? Bool ?? false
        taskID = Self.text(json[Self.taskKey])
        toolName = Self.text(json["tool_name"])
        toolSubject = Self.subject(of: json["tool_input"] as? [String: Any])
        lastReply = Self.replyPreview(json["last_assistant_message"] as? String)
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

    /// A tool input's one-line subject. Public because a chat's stream
    /// (`ChatParser`) carries the same `tool_use` input and its line must read
    /// the same as a session's card.
    public static func subject(of input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in subjectKeys {
            guard let value = input[key] as? String else { continue }
            let line = lines(of: value).first
            if let line { return capped(line, at: subjectLimit) }
        }
        return nil
    }

    /// A `command`, whole and as written: what a permission card shows,
    /// so no part of it is allowed unseen — the one-line subject is capped
    /// and a card cut it, and a real `claude` (2.1.281) wrote `\` + newline
    /// between the parts of a command whose third part was `rm`, while the
    /// card said `\`. Only blank lines at either end go; nothing is capped
    /// (the request itself is bounded by the listener) and nothing is
    /// rejoined — inside quotes or a heredoc a `\` stays literal.
    public static func fullCommand(of input: [String: Any]?) -> String? {
        guard let command = input?["command"] as? String else { return nil }
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
              let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        return lines[first...last].joined(separator: "\n")
    }

    /// A value's non-blank lines, trimmed, with a shell line continuation
    /// (`\` at a line's end) read as the shell reads it: one line. Without
    /// it a command that opens with `\` + newline had `\` for its subject.
    private static func lines(of value: String) -> [String] {
        var joined: [String] = []
        var pending = ""
        for raw in value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\"), !line.hasSuffix("\\\\") {
                pending += (pending.isEmpty ? "" : " ") + line.dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }
            let whole = (pending.isEmpty ? line : pending + (line.isEmpty ? "" : " " + line))
                .trimmingCharacters(in: .whitespaces)
            pending = ""
            if !whole.isEmpty { joined.append(whole) }
        }
        let tail = pending.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { joined.append(tail) }
        return joined
    }

    /// A reply as the card previews it: its paragraphs run together on one
    /// line, cut at `replyLimit`. The first paragraph alone was often a
    /// greeting ("Done!") with the substance behind it. Public for the same
    /// reason as `subject(of:)`: a chat's last reply keeps the same privacy
    /// promise as a session's.
    public static func replyPreview(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return capped(words, at: replyLimit)
    }

    /// A cut text says it was cut.
    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
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
