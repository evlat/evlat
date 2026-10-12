import Foundation
import EvlatCore

/// The canonical `PermissionRequest` body read as a request the card holds —
/// Claude Code's shape, which Codex's and OpenCode's channels reach by way of
/// their adapters (`CodexApprovals`, `OpenCodeApprovals`). It lives beside no
/// one agent: what it reads (the tool, its subject, the suggestions that are
/// rules and folders) is the vocabulary, not a particular hook.
extension HeldRequest {
    /// The hook's body. `nil` when it is not a `PermissionRequest` with a
    /// tool — a body Evlat cannot put on a card is refused, not guessed.
    init?(json: [String: Any], token: String?, id: String = UUID().uuidString) {
        guard json["hook_event_name"] as? String ?? "PermissionRequest" == "PermissionRequest",
              let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
        var rules: [PermissionHook.Rule] = []
        var directories: [String] = []
        for suggestion in json["permission_suggestions"] as? [[String: Any]] ?? [] {
            switch suggestion["type"] as? String {
            case "addRules" where suggestion["behavior"] as? String == "allow":
                for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
                    guard let name = rule["toolName"] as? String, !name.isEmpty else { continue }
                    let made = PermissionHook.Rule(toolName: name, ruleContent: rule["ruleContent"] as? String)
                    if !rules.contains(made), !PermissionHook.isOverruled(made) { rules.append(made) }
                }
            case "addDirectories":
                for directory in suggestion["directories"] as? [String] ?? []
                where !directory.isEmpty && !directories.contains(directory) {
                    directories.append(directory)
                }
            default:
                // `setMode` would switch the whole session to accepting
                // edits; nothing but a rule or a folder is ever granted.
                continue
            }
        }
        let input = json["tool_input"] as? [String: Any]
        let questions = tool == AskQuestion.tool ? AskQuestion.questions(in: input) : nil
        let kept = questions == nil ? nil : input.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        self.init(id: id, token: token, tool: tool,
                  subject: HookEvent.subject(of: input), command: HookEvent.fullCommand(of: input),
                  rules: rules, directories: directories,
                  sessionID: json["session_id"] as? String, cwd: json["cwd"] as? String,
                  subagent: (json["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  questions: questions, input: kept)
    }
}
