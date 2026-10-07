import Foundation
import EvlatCore

/// A chat turn's own permission hook: the inline settings a
/// `claude -p` turn is started with, the request it posts, and the decision
/// Evlat answers with.
///
/// The turn runs with `--permission-prompts none`, so anything that would
/// prompt is denied unless a `PermissionRequest` hook allows it. What would
/// prompt depends on the chat's `PermissionMode` (auto by default: a
/// classifier's block is a denial, not a prompt) and on `askRules`, which
/// prompt in every mode. The hook is
/// Claude Code's `type: "command"` kind: a `curl` to the socket Evlat's
/// listener bound (`EvlatSocket`), whose answer — the hook's stdout — is
/// held until the user presses a button on the card. Every way that goes
/// wrong — Evlat gone, the connection dropped, the hook's time up, a non-2xx
/// answer (`-f`: nothing printed) — leaves the hook without a decision,
/// which under `none` is a denial: the safe side (measured, as an empty
/// output, under `-p --permission-prompts none`).
///
/// The shapes are the ones Claude Code 2.1.281 validates (read from its
/// schema): the input carries `tool_name`, `tool_input` and
/// `permission_suggestions`; the output is
/// `hookSpecificOutput.decision.behavior` with `updatedPermissions`.
///
/// Pure: strings and dictionaries in and out.
enum PermissionHook {
    /// The route (`ChatRequest.path`). Local only: a tunnel answers it `404`
    /// (`LocalAPI`).
    static let path = ChatRequest.path
    /// The header the token rides in — written as a **plain value** into
    /// the inline settings, not as an environment variable: a variable in the
    /// turn's environment would be inherited by every command its Bash tool
    /// runs. That is not secrecy: the inline settings are in the turn's
    /// argv, which any process of this user (the Bash tool's too) reads with
    /// `ps`. The token tells turns apart; what guards a grant is the user's
    /// press on a card that shows everything "always" keeps.
    static let tokenHeader = ChatRequest.tokenHeader
    /// How long Claude Code holds the request open, in seconds, and how
    /// long `curl` waits: the documented default for a hook, written out so
    /// a change of default does not change how long a card can wait.
    static let timeout = 600

    /// The only destination Evlat ever grants to: in memory, this session.
    /// The user's settings files (`localSettings`, `userSettings`, …) are
    /// never written through a card.
    static let destination = "session"

    /// Where a turn's hook posts, and the token that says which turn it is.
    struct Endpoint: Equatable {
        let socket: String
        let token: String

        init(socket: String, token: String) {
            self.socket = socket
            self.token = token
        }

        var settings: String { PermissionHook.settings(socket: socket, token: token) }
    }

    /// The hook's command: the request on stdin to the socket, the answer
    /// on stdout. `-f` prints nothing for a refusal, `2>/dev/null` keeps
    /// curl's own words out, and `|| true` makes every failure an empty
    /// output — no decision, never a hook error. The token is a plain value
    /// in a header: the same visibility as in the `--settings` argv it rides.
    static func command(socket: String, token: String) -> String {
        let curl = EvlatSocket.Curl.self
        return [curl.program, "-sf", curl.noProxy, curl.socket(socket), "-m", "\(timeout)",
                "-H", curl.quoted("\(tokenHeader): \(token)"), "-H", curl.quoted("Content-Type: application/json"),
                "--data-binary", "@-", curl.url(path), "2>/dev/null || true"].joined(separator: " ")
    }

    // MARK: - The settings

    /// The commands a chat's turn always asks about, whatever its mode:
    /// the ones that cannot be taken back. Written as `permissions.ask` into
    /// the turn's own `--settings`, never into the user's files. An ask rule
    /// prompts even in auto mode, and a rule matches any subcommand of a
    /// compound command (`cd x && rm -r y` asks) — documented, and `rm -r`
    /// measured to reach the card. `Bash(x:*)` is the
    /// same prefix rule as `Bash(x *)`: it also matches a bare `x`.
    ///
    /// The one list; the tests read it from here.
    static let askRules = [
        "Bash(rm:*)", "Bash(rmdir:*)", "Bash(sudo:*)", "Bash(git push:*)", "Bash(git reset --hard:*)",
        "Bash(chmod:*)", "Bash(chown:*)", "Bash(kill:*)", "Bash(killall:*)",
    ]

    /// Would an ask rule still ask for what `rule` allows? An ask rule wins
    /// over an allow rule (documented precedence), so "always" for
    /// `Bash(rm -r build:*)` would be kept and never take effect: such a
    /// suggestion is not offered. A rule for all of Bash is not an ask
    /// rule's to overrule — it still lets everything else through.
    static func isOverruled(_ rule: Rule) -> Bool {
        guard rule.toolName == "Bash", var content = rule.ruleContent, !content.isEmpty else { return false }
        for suffix in [":*", " *", "*"] where content.hasSuffix(suffix) {
            content = String(content.dropLast(suffix.count))
            break
        }
        let words = content.split(separator: " ").joined(separator: " ")
        return askedCommands.contains { words == $0 || words.hasPrefix($0 + " ") }
    }

    /// The commands `askRules` name: `Bash(git push:*)` → `git push`.
    static let askedCommands: [String] = askRules.map { String($0.dropFirst("Bash(".count).dropLast(":*)".count)) }

    /// `--settings`' value: one `PermissionRequest` hook, `type: "command"`,
    /// to the socket the listener actually bound, and `askRules`. Sorted keys
    /// and unescaped slashes, so the string is the same on every run and
    /// readable in a process list.
    ///
    /// `memoryDirectory`, when given, is `autoMemoryDirectory`: where Claude
    /// keeps what it remembers. Claude derives the folder from the project
    /// root, so each workspace chat (`chats/<UUID>/`) would get a memory of
    /// its own that no later chat reads; given one folder, every workspace
    /// chat shares it (measured on 2.1.281: a note written in one chat was
    /// recalled by a new one). A chat in the user's folder gets none, and
    /// keeps that folder's own memory.
    static func settings(socket: String, token: String, memoryDirectory: String? = nil) -> String {
        let hook: [String: Any] = [
            "type": "command",
            "command": command(socket: socket, token: token),
            "timeout": timeout,
        ]
        var settings: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [hook]]]],
                                       "permissions": ["ask": askRules]]
        if let memoryDirectory { settings["autoMemoryDirectory"] = memoryDirectory }
        // Strings, an integer and nested containers of them always encode.
        let data = (try? JSONSerialization.data(withJSONObject: settings,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The request

    /// A permission rule (`PermissionRule`); its JSON is the hook's
    /// `toolName` / `ruleContent`.
    typealias Rule = PermissionRule

    // MARK: - The decision

    /// The user's answer (`ChatDecision`): `allow` grants the rules and
    /// folders for the session too, `deny(interrupt:)` ends the turn when
    /// the user pressed Stop, `answer` is an `AskUserQuestion` answered —
    /// allowed with `input` (the request's) plus `answers`.
    typealias Decision = ChatDecision

    /// The message a denial carries back to Claude.
    static let deniedMessage = "The user denied this in Evlat."
    static let stoppedMessage = "The user stopped the turn in Evlat."

    /// The answer's body: `hookSpecificOutput.decision`, and in
    /// `updatedPermissions` only `addRules` and `addDirectories`, only to
    /// `session`.
    static func body(_ decision: Decision) -> String {
        var inner: [String: Any]
        switch decision {
        // Claude's "always" is its rules (`AlwaysOption.rules`): it is never
        // asked to keep a command by itself, and a bare allow is its nearest.
        case .allowForSession:
            inner = ["behavior": "allow"]
        case .allow(let rules, let directories):
            inner = ["behavior": "allow"]
            var updates: [[String: Any]] = []
            if !rules.isEmpty {
                updates.append(["type": "addRules", "rules": rules.map(\.json), "behavior": "allow",
                                "destination": destination])
            }
            if !directories.isEmpty {
                updates.append(["type": "addDirectories", "directories": directories,
                                "destination": destination])
            }
            if !updates.isEmpty { inner["updatedPermissions"] = updates }
        case .deny(let interrupt):
            inner = ["behavior": "deny", "message": interrupt ? stoppedMessage : deniedMessage]
            if interrupt { inner["interrupt"] = true }
        case .answer(let input, let answers):
            var updated = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            updated["answers"] = answers
            inner = ["behavior": "allow", "updatedInput": updated]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": inner]]
        let data = (try? JSONSerialization.data(withJSONObject: output,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension PermissionRule {
    /// The rule as the hook's JSON writes it.
    var json: [String: Any] {
        var json: [String: Any] = ["toolName": toolName]
        if let ruleContent { json["ruleContent"] = ruleContent }
        return json
    }
}

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
