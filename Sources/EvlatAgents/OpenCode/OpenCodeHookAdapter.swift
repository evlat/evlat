import Foundation
import EvlatCore

/// What OpenCode's events mean in the canonical vocabulary (Claude Code's),
/// and nothing else: the plugin (`OpenCodePlugin`) posts OpenCode's own
/// event names with the fields it pulled out, and this says what each one
/// does to a row. A name this version does not know passes **unchanged**, so
/// it stays visible downstream instead of being swallowed.
///
/// The two version lines name the same things differently, so one table
/// serves both (measured on 1.18.34, 1.19.0, 2.0.22 and 2.0.27):
///
/// | OpenCode | canonical |
/// |---|---|
/// | `session.created` (a root session) | `SessionStart`, `startup` |
/// | `session.deleted` | `SessionEnd` |
/// | `session.status` `busy`, 2.x `session.execution.started` | `UserPromptSubmit` |
/// | `session.idle`, 2.x `execution.succeeded`/`interrupted` | `Stop` |
/// | `session.error` (not an abort), 2.x `execution.failed` | `StopFailure` |
/// | `session.error` that is `MessageAbortedError` | `Stop` |
/// | a tool part `running`, 2.x `session.tool.called` | `PreToolUse` |
/// | `completed`, `session.tool.success` | `PostToolUse` |
/// | `error`, `session.tool.failed` | `PostToolUseFailure` |
/// | `permission.asked`, `question.asked`, a question `form.created` | `PermissionRequest` |
/// | an answer (`*.replied`, `question.rejected`) | `PostToolUse`, or `PermissionDenied` for a refusal |
///
/// An answer is what ends a wait: OpenCode fires nothing else until the tool
/// finishes, and a long tool would leave the row `waiting` after the user
/// answered. Its tool is not named, so it counts no step.
enum OpenCodeHookAdapter {
    /// The canonical events a session's row is moved by here.
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Stop", "StopFailure"]

    static func canonical(_ json: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        // The server's own keys pass through (`HookChannel.canonical`).
        for key in [HookEvent.pidKey, HookEvent.servicePidKey, HookEvent.taskKey] { out[key] = json[key] }
        out["session_id"] = json["session"]
        out["cwd"] = json["directory"]
        out["agent_id"] = json["child"]
        out["agent_version"] = json["opencode_version"]
        let event = json["event"] as? String ?? json["hook_event_name"] as? String ?? ""
        let status = json["status"] as? String
        switch event {
        case "session.created":
            out["hook_event_name"] = "SessionStart"
            out["source"] = "startup"
        case "session.deleted":
            out["hook_event_name"] = "SessionEnd"
        case "session.status":
            // The plugin sends a turn's first `busy` only; `idle` arrives as `session.idle`.
            out["hook_event_name"] = status == "busy" ? "UserPromptSubmit" : event
        case "session.execution.started":
            out["hook_event_name"] = "UserPromptSubmit"
        case "session.idle", "session.execution.succeeded", "session.execution.interrupted":
            out["hook_event_name"] = "Stop"
        case "session.execution.failed":
            out["hook_event_name"] = "StopFailure"
        case "session.error":
            // An interrupt is the user's, not a failure.
            out["hook_event_name"] = (json["error"] as? String) == "MessageAbortedError" ? "Stop" : "StopFailure"
        case "message.part.updated":
            switch status {
            case "running": out["hook_event_name"] = "PreToolUse"
            case "completed": out["hook_event_name"] = "PostToolUse"
            case "error": out["hook_event_name"] = "PostToolUseFailure"
            default: out["hook_event_name"] = event
            }
            tool(json, into: &out)
        case "session.tool.called":
            out["hook_event_name"] = "PreToolUse"
            tool(json, into: &out)
        case "session.tool.success":
            out["hook_event_name"] = "PostToolUse"
            tool(json, into: &out)
        case "session.tool.failed":
            out["hook_event_name"] = "PostToolUseFailure"
            tool(json, into: &out)
        case "permission.asked", "question.asked":
            out["hook_event_name"] = "PermissionRequest"
            ask(json["ask"] as? [String: Any], into: &out)
        case "form.created":
            // Only a form that is a question carries an ask (the plugin
            // passes any other kind as a word): one that asks nothing is
            // not a wait, and stays visible under its own name.
            guard json["ask"] is [String: Any] else {
                out["hook_event_name"] = event
                break
            }
            out["hook_event_name"] = "PermissionRequest"
            ask(json["ask"] as? [String: Any], into: &out)
        case "permission.replied", "question.replied", "question.rejected", "form.replied":
            out["hook_event_name"] = (json["reply"] as? String) == "reject" ? "PermissionDenied" : "PostToolUse"
        default:
            out["hook_event_name"] = event
        }
        return out
    }

    // MARK: - Tools

    /// OpenCode's tool names in Claude's spelling. 1.x and 2.x name some
    /// differently (`bash`/`shell`, `task`/`subagent`); one that is not here
    /// keeps its own name.
    static let tools: [String: String] = [
        "bash": "Bash", "shell": "Bash", "edit": "Edit", "write": "Write", "read": "Read",
        "grep": "Grep", "glob": "Glob", "webfetch": "WebFetch", "websearch": "WebSearch",
        "task": "Agent", "subagent": "Agent", "question": "AskUserQuestion", "skill": "Skill",
    ]

    /// Input keys in Claude's spelling (`HookEvent.subjectKeys`): 1.x names a
    /// file `filePath`, 2.x `path`.
    static let arguments: [String: String] = ["filePath": "file_path", "path": "file_path"]

    private static func tool(_ json: [String: Any], into out: inout [String: Any]) {
        if let name = json["tool"] as? String, !name.isEmpty { out["tool_name"] = tools[name] ?? name }
        guard let input = json["input"] as? [String: Any] else { return }
        var canonical: [String: Any] = [:]
        for (key, value) in input { canonical[arguments[key] ?? key] = value }
        out["tool_input"] = canonical
    }

    // MARK: - Asks

    /// A permission or a question, as the tool it is about: the kind names
    /// it (`bash`, `edit`, `question`, …), its patterns say what on.
    private static func ask(_ ask: [String: Any]?, into out: inout [String: Any]) {
        guard let ask else { return }
        let kind = ask["kind"] as? String ?? ""
        let patterns = ask["patterns"] as? [String] ?? []
        let name = tools[kind] ?? kind
        if !name.isEmpty { out["tool_name"] = name }
        var input: [String: Any] = [:]
        switch name {
        case "Bash":
            // 1.x says the command in its metadata, 2.x as the resource.
            if let command = ask["command"] as? String ?? patterns.first { input["command"] = command }
        case "Edit", "Write", "Read":
            if let file = ask["file"] as? String ?? patterns.first { input["file_path"] = file }
        case "AskUserQuestion":
            if let questions = ask["questions"] { input["questions"] = questions }
        default:
            if let pattern = patterns.first { input["pattern"] = pattern }
        }
        out["tool_input"] = input
    }
}
