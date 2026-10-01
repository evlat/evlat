import Foundation

/// The agent an event came from. A closed set: adapters are compiled Swift and
/// nothing is loaded from outside (`Provider`'s rule, for the same reason).
/// `rawValue` is the wire identity — it spells the path in `/hook/{rawValue}`.
///
/// **The canonical vocabulary is Claude Code's**: event names, field names and
/// tool names. Every rule downstream reads only that and never learns a source
/// name; anything source-specific stays inside `canonical(_:)`. A rule that
/// branches on the source is a finding in this repo (`AGENTS.md` → Pitfalls).
public enum AgentSource: String, CaseIterable {
    case claude, codex, antigravity

    /// Claude's path is `/hook` and it cannot move: it is written into the
    /// command already installed in the user's settings file. Every other
    /// source is named in its path. `/hook/claude` is accepted as well, as a
    /// synonym (`LocalAPI.dispatch`).
    public var hookPath: String { self == .claude ? "/hook" : "/hook/\(rawValue)" }

    /// Where the agent's rate-limit windows are posted, when its status line
    /// carries them: Claude's `rate_limits`, and the Antigravity CLI's
    /// `quota` (measured, `agy` 1.2.14). Codex has no route here (`nil`);
    /// its windows are read from its own file instead
    /// (`CodexUsageProvider`). Named like `hookPath`'s later rows.
    public var usagePath: String? { self == .codex ? nil : "/usage/\(rawValue)" }

    /// The events Evlat's command is installed on, byte for byte v1's lists.
    /// `SubagentStart`/`SubagentStop` are left out on purpose: a subagent's tool
    /// events already arrive on the parent's row (`HooksProvider`).
    /// Codex's `Interrupt` is there because Codex sends no `Stop` on an
    /// interrupt; the adapter translates it (`CodexHookAdapter`).
    public var hookEvents: [String] {
        switch self {
        case .claude:
            return ["SessionStart", "SessionEnd", "UserPromptSubmit",
                    "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "PermissionRequest", "PermissionDenied",
                    "Notification", "Stop", "StopFailure"]
        case .codex:
            return ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PermissionRequest", "Stop", "Interrupt"]
        // All five Antigravity has (measured, CLI 1.2.14 and app 2.18.1).
        // None asks the user anything, so an Antigravity row never waits.
        case .antigravity:
            return ["PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation", "Stop"]
        }
    }

    /// Whether the agent is on this Mac: a directory only it creates. For
    /// Antigravity that is not the hooks file's directory — `~/.gemini`
    /// belongs to Gemini CLI as well — but the app's or the CLI's own.
    public func isPresent(home: URL) -> Bool {
        let directories: [String]
        switch self {
        case .claude, .codex: directories = [configDirectoryName]
        case .antigravity: directories = [".gemini/antigravity", ".gemini/antigravity-cli"]
        }
        return directories.contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// The agent's own directory under `home`. Its existence is what says the
    /// agent is installed at all; the writer never creates it.
    public func configDirectory(home: URL) -> URL {
        home.appendingPathComponent(configDirectoryName)
    }

    /// The file the agent reads its hooks from. `home` has no default: a caller
    /// that forgets to pass one must not land on the user's real settings.
    public func settingsFile(home: URL) -> URL {
        configDirectory(home: home).appendingPathComponent(settingsFileName)
    }

    /// The file the agent reads its `statusLine` from, where Evlat's usage
    /// relay goes (`StatusLineRelay`): Claude's settings, and the Antigravity
    /// CLI's own settings — not the hooks file, which the app and IDE share
    /// and which has no status line. Codex has none (`nil`).
    public func statusLineFile(home: URL) -> URL? {
        statusLinePath.map { home.appendingPathComponent($0) }
    }

    /// The same file relative to a home, as the setup names it.
    public var statusLinePath: String? {
        switch self {
        case .claude: return settingsPath
        case .codex: return nil
        case .antigravity: return ".gemini/antigravity-cli/settings.json"
        }
    }

    /// The same file relative to a home: a server's `$HOME`, which only the
    /// server's shell knows (`RemoteSettings`).
    public var settingsPath: String { configDirectoryName + "/" + settingsFileName }

    private var configDirectoryName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        // Shared by Antigravity's app, IDE and CLI (documented; seen as `{}`).
        case .antigravity: return ".gemini/config"
        }
    }
    private var settingsFileName: String { self == .claude ? "settings.json" : "hooks.json" }

    /// Translates a source's hook body into the canonical vocabulary. An event
    /// this adapter does not know is passed through **unchanged** rather than
    /// dropped: an unrecognised name stays visible downstream, where it matches
    /// no rule, instead of disappearing here.
    ///
    /// `HookEvent.taskKey` and `HookEvent.pidKey` are already in the body when
    /// this runs — the server writes them before translating — so an adapter
    /// must carry them through.
    public func canonical(_ json: [String: Any]) -> [String: Any] {
        switch self {
        case .claude: return json
        case .codex: return CodexHookAdapter.canonical(json)
        case .antigravity: return AntigravityHookAdapter.canonical(json)
        }
    }
}

/// Codex's differences from the canonical vocabulary, and nothing else. Its
/// schema is already shaped like Claude Code's; only what was **measured** to
/// differ is translated here (v1, set 008 → M2, M4, M5). A tool failure is not
/// translated: Codex sends no stable error field (`tool_response` is plain
/// text) and nothing is guessed from text.
enum CodexHookAdapter {
    static func canonical(_ json: [String: Any]) -> [String: Any] {
        var translated = json
        // Codex sends no `Stop` when the user interrupts a turn; it sends
        // `Interrupt`. Untranslated, the session would keep reporting `working`
        // long after it stopped, and nothing else would ever correct it.
        if translated["hook_event_name"] as? String == "Interrupt" {
            translated["hook_event_name"] = "Stop"
        }
        switch translated["tool_name"] as? String {
        case "apply_patch": patch(&translated)
        case "collaborationspawn_agent", "collaborationwait_agent": agent(&translated)
        default: break
        }
        return translated
    }

    /// Patch headers and their canonical tools. The first header wins: the
    /// card names one file.
    private static let headers: [(prefix: String, tool: String)] = [
        ("*** Add File: ", "Write"), ("*** Update File: ", "Edit"), ("*** Delete File: ", "Edit"),
    ]

    /// `apply_patch` → `Write` or `Edit`, with `file_path` from the patch
    /// header (a relative path). Codex's most frequent tool would otherwise
    /// reach the card as `apply_patch` and a patch body. A patch with no
    /// header is still an `Edit`.
    ///
    /// Unlike v1, the patch text itself (`command`) is **dropped**: it comes
    /// first in `HookEvent.subjectKeys`, so leaving it would make the subject
    /// `*** Begin Patch`, and it is the file's content besides — the part the
    /// card promises not to hold.
    private static func patch(_ json: inout [String: Any]) {
        var input = json["tool_input"] as? [String: Any] ?? [:]
        let text = input.removeValue(forKey: "command") as? String ?? ""
        var tool = "Edit"
        search: for line in text.split(whereSeparator: \.isNewline) {
            for header in headers where line.hasPrefix(header.prefix) {
                tool = header.tool
                input["file_path"] = String(line.dropFirst(header.prefix.count))
                break search
            }
        }
        json["tool_name"] = tool
        json["tool_input"] = input
    }

    /// Spawning and waiting on a subagent → `Agent`. The spawn's `message` is
    /// opaque; the subject, when there is one, is `task_name`, and sometimes
    /// there is none (M5) — then the card shows the name alone.
    private static func agent(_ json: inout [String: Any]) {
        var input = json["tool_input"] as? [String: Any] ?? [:]
        if let name = input["task_name"] as? String { input["description"] = name }
        json["tool_name"] = "Agent"
        json["tool_input"] = input
    }
}
