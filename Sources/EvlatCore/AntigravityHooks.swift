import Foundation

/// Antigravity's differences from the canonical vocabulary. The app, the IDE
/// and the `agy` CLI share one hook system (measured: CLI 1.2.14, app
/// 2.18.1), and its bodies are camelCase and name no event; the command
/// sends the name as a header, which the server has written into
/// `hook_event_name` before this runs (`LocalAPI.handle`).
///
/// What was measured, per turn: `PreInvocation` (one per model call,
/// `invocationNum` from 0 each turn) → `PreToolUse` / `PostToolUse` →
/// `PostInvocation` → … → `Stop` (`fullyIdle`, `terminationReason`). There is
/// no permission or notification event: a tool waiting for the user's
/// approval has had its `PreToolUse` and nothing more, so the row reads
/// `working` on it. The hook's parent is the agent's own process — `agy`, or
/// the app's `language_server`, shared by every conversation of the app.
public enum AntigravityHookAdapter {
    public static func canonical(_ json: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        // The server's own keys pass through (`HookChannel.canonical`).
        // So does the reply the server read from the transcript
        // (`AntigravityTranscript`).
        for key in [HookEvent.pidKey, HookEvent.taskKey, "hook_event_name", "last_assistant_message"] {
            out[key] = json[key]
        }
        out["session_id"] = json["conversationId"]
        if let first = (json["workspacePaths"] as? [String])?.first { out["cwd"] = first }
        switch json["hook_event_name"] as? String {
        case "PreInvocation":
            // A turn's first model call is its start: the tool count resets
            // there, as on Claude's `UserPromptSubmit`. The later calls of a
            // turn change nothing.
            if (json["invocationNum"] as? Int) == 0 { out["hook_event_name"] = "UserPromptSubmit" }
        case "PreToolUse", "PostToolUse":
            tool(json["toolCall"] as? [String: Any], into: &out)
        default:
            break
        }
        return out
    }

    /// Tool names whose canonical name is known (measured: `run_command`).
    static let tools: [String: String] = ["run_command": "Bash"]

    /// Argument keys that hold a subject, in Claude's spelling
    /// (`HookEvent.subjectKeys`). Antigravity's arguments are PascalCase.
    static let arguments: [String: String] = [
        "CommandLine": "command", "AbsolutePath": "file_path", "TargetFile": "file_path",
        "FilePath": "file_path", "Query": "query", "Url": "url",
    ]

    private static func tool(_ call: [String: Any]?, into json: inout [String: Any]) {
        guard let call, let name = call["name"] as? String, !name.isEmpty else { return }
        json["tool_name"] = tools[name] ?? name
        var input: [String: Any] = [:]
        for (key, value) in call["args"] as? [String: Any] ?? [:] {
            if let canonical = arguments[key] { input[canonical] = value }
        }
        json["tool_input"] = input
    }
}

/// Adds, reads and removes Evlat's hooks in Antigravity's
/// `~/.gemini/config/hooks.json`. Its shape is its own: the file is keyed by
/// hook name, and Evlat's is `name`, with one command per event (the event
/// rides in a header, `LocalAPI.installedHookCommand(for:event:)`). Tool
/// events take matcher groups; the others take hooks directly — the shape
/// the measured runs used. Another tool's names are never touched.
///
/// Pure: dictionary in, dictionary out; the file is `LocalHooks`'.
public enum AntigravityHooks {
    public typealias State = HookSettings.State

    static let name = "evlat"
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Evlat's entry as written, for the agent's `hooks`; the golden test
    /// pins it.
    public static func installed(hooks: HookChannel) -> [String: Any] {
        var entry: [String: Any] = ["enabled": true]
        for event in hooks.events {
            let hook: [String: Any] = ["type": "command", "timeout": 5,
                                       "command": LocalAPI.installedHookCommand(for: hooks, event: event)]
            entry[event] = toolEvents.contains(event) ? [["matcher": "*", "hooks": [hook]]] : [hook]
        }
        return entry
    }

    public static func state(of settings: [String: Any], hooks: HookChannel) -> State {
        guard let ours = settings[name] else { return .missing }
        guard let entry = ours as? [String: Any] else { return .outdated }
        return NSDictionary(dictionary: entry).isEqual(to: installed(hooks: hooks)) ? .current : .outdated
    }

    public static func installing(into settings: [String: Any], hooks: HookChannel) -> [String: Any] {
        var result = settings
        result[name] = installed(hooks: hooks)
        return result
    }

    public static func removing(from settings: [String: Any], hooks: HookChannel) -> [String: Any] {
        var result = settings
        result.removeValue(forKey: name)
        return result
    }
}

/// The one reply an Antigravity card shows. Claude's `Stop` carries its last
/// reply; Antigravity's carries none, only `transcriptPath`, so at `Stop` the
/// transcript's tail is read for the last model reply — the only place Evlat
/// reads a transcript. Nothing else in it is kept: not the user's words, not
/// tool output.
///
/// Only a transcript under one of `roots` is read: the path comes from a
/// loopback body any local process could send, and a tunneled body names a
/// file on another computer, so a remote row never reads one
/// (`LocalAPI.handle`). The roots are the listener's parameter, never a
/// constant (`roots(home:)`).
///
/// A line is a step: `{"source": "MODEL", "type": "PLANNER_RESPONSE",
/// "content": "…"}` is a reply, and the one that ends a turn is the last with
/// text (a reply before a tool call can be empty). Measured on CLI 1.2.14
/// and app 2.18.1.
public enum AntigravityTranscript {
    /// Enough for the last reply; a transcript grows with the conversation.
    static let tailBytes = 64 * 1024

    /// Where the app, the CLI and the IDE keep their conversations.
    public static func roots(home: URL) -> [URL] {
        ["antigravity", "antigravity-cli", "antigravity-ide"].map {
            home.appendingPathComponent(".gemini/\($0)/brain", isDirectory: true)
        }
    }

    /// Inside a root after `..` and symlinks are resolved, and a `.jsonl`.
    static func isAllowed(_ path: String, roots: [URL]) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.pathExtension == "jsonl" else { return false }
        return roots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    public static func lastReply(at path: String, roots: [URL]) -> String? {
        guard isAllowed(path, roots: roots), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return lastReply(in: data, cut: start > 0)
    }

    /// `cut`: the data starts mid-file, so its first line is a fragment.
    static func lastReply(in data: Data, cut: Bool) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if cut, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let step = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  step["source"] as? String == "MODEL", step["type"] as? String == "PLANNER_RESPONSE",
                  let content = step["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return content
        }
        return nil
    }
}
