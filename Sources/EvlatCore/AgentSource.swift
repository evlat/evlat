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

    /// Whether the agent is on this Mac: a directory only it creates.
    public func isPresent(home: URL) -> Bool {
        presenceDirectories.contains { Self.isDirectory(home.appendingPathComponent($0)) }
    }

    /// The directories, relative to a home, whose existence says the agent
    /// is installed; any one is enough. For Antigravity they are not the
    /// hooks file's directory — `~/.gemini` belongs to Gemini CLI as well —
    /// but the app's and the CLI's own. A server's shell asks the same
    /// question (`RemoteSettings`).
    public var presenceDirectories: [String] {
        switch self {
        case .claude, .codex: return [configDirectoryName]
        case .antigravity: return [".gemini/antigravity", ".gemini/antigravity-cli"]
        }
    }

    /// Whether the install makes the hooks file's directory when it is
    /// missing. Claude's and Codex's is the agent's own and says it is
    /// installed, so it is never made; Antigravity's is a shared folder its
    /// presence does not depend on, and it may not exist yet. The rule is
    /// the same on this Mac (`LocalHooks.install`) and on a server
    /// (`RemoteSettings`), where it also waits for `presenceDirectories`.
    public var opensHooksDirectory: Bool { self == .antigravity }

    /// Whether Evlat's approval hook goes in beside the command
    /// (`ApprovalHook`): Claude's alone; the others have no such event.
    public var supportsApprovals: Bool { self == .claude }

    /// Whether the agent's status line can be relayed here: it has one
    /// (`statusLinePath`), and for Antigravity the CLI that reads it is
    /// installed — the app and the IDE have no status line.
    public func hasStatusLine(home: URL) -> Bool {
        switch self {
        case .claude: return statusLinePath != nil
        case .codex: return false
        case .antigravity: return Self.isDirectory(home.appendingPathComponent(".gemini/antigravity-cli"))
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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

    // MARK: - Usage

    /// How a status line's JSON carries one window's numbers.
    public enum UsageReading {
        /// `used_percentage` (0–100) and `resets_at` (epoch seconds):
        /// Claude Code's documented `rate_limits`.
        case usedPercentage
        /// `remaining_fraction` (0–1, what is left) and `reset_time`
        /// (RFC 3339): the Antigravity CLI's `quota` (measured, `agy`
        /// 1.2.14, undocumented).
        case remainingFraction
    }

    /// The part of a status line the windows are read from
    /// (`UsageReport`).
    public struct StatusLineUsage {
        /// The key under which the windows sit.
        public let root: String
        /// The windows drawn, and how long each one is. A key under `root`
        /// that is not here stays unrecognized and visible in `--capture`.
        public let windows: [(key: String, minutes: Int)]
        public let reading: UsageReading
    }

    /// Where an agent's usage windows come from and what they are called on
    /// the bar.
    public struct Usage {
        /// The local provider's id; a machine's instance derives its own.
        public let providerID: String
        /// The name the windows are grouped under on the bar. A proper
        /// name, not catalogue text (`Signal.Usage.group`).
        public let group: String
        public let fidelity: Signal.Fidelity
        /// `nil` when the windows are not posted by a status line: Codex's
        /// are read from its own file (`CodexUsageProvider`).
        public let statusLine: StatusLineUsage?
    }

    public var usage: Usage {
        switch self {
        // Claude Code's documented status line input: `.official`.
        case .claude:
            return Usage(providerID: "claude-usage", group: "Claude", fidelity: .official,
                         statusLine: StatusLineUsage(root: "rate_limits",
                                                     windows: [("five_hour", 300), ("seven_day", 10080)],
                                                     reading: .usedPercentage))
        // An undocumented rollout file: `.derived`, drawn with `~`.
        case .codex:
            return Usage(providerID: "codex-usage", group: "Codex", fidelity: .derived, statusLine: nil)
        // Its `quota` holds two pools of the same two lengths: `gemini-*`
        // and `3p-*` (the other vendors' models it offers). Only Gemini's
        // is drawn — the bar has room for one more group of two windows
        // (`UsageBlockModel.maxLines`) — so `3p-*` stays unrecognized. The
        // group is named for that pool; "Gemini" also sorts after Claude
        // and Codex (`Snapshot`'s order), so the bar's cap drops it first.
        // Undocumented, so `.derived`.
        case .antigravity:
            return Usage(providerID: "antigravity-usage", group: "Gemini", fidelity: .derived,
                         statusLine: StatusLineUsage(root: "quota",
                                                     windows: [("gemini-5h", 300), ("gemini-weekly", 10080)],
                                                     reading: .remainingFraction))
        }
    }

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
