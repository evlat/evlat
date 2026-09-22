import Foundation

/// The agent an event came from. A closed set: adapters are compiled Swift and
/// nothing is loaded from outside (`Provider`'s rule, for the same reason).
/// `rawValue` is the wire identity — it spells the path in `/hook/{rawValue}`.
///
/// **The canonical vocabulary is Claude Code's**: event names, field names and
/// tool names. Every rule downstream reads only that and never learns a source
/// name; anything source-specific stays inside `canonical(_:)`. A rule that
/// branches on the source is a finding in this repo (`proje.md` → tuzaklar).
public enum AgentSource: String, CaseIterable {
    case claude, codex

    /// Claude's path is `/hook` and it cannot move: it is written into the
    /// command already installed in the user's settings file. Every other
    /// source is named in its path. `/hook/claude` is accepted as well, as a
    /// synonym (`LocalAPI.dispatch`).
    public var hookPath: String { self == .claude ? "/hook" : "/hook/\(rawValue)" }

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
        }
    }
}

/// Codex's differences from the canonical vocabulary, and nothing else. Its
/// schema is already shaped like Claude Code's; only what was **measured** to
/// differ is translated here (v1, set 008 → M4).
enum CodexHookAdapter {
    static func canonical(_ json: [String: Any]) -> [String: Any] {
        var translated = json
        // Codex sends no `Stop` when the user interrupts a turn; it sends
        // `Interrupt`. Untranslated, the session would keep reporting `working`
        // long after it stopped, and nothing else would ever correct it.
        if translated["hook_event_name"] as? String == "Interrupt" {
            translated["hook_event_name"] = "Stop"
        }
        return translated
    }
}
