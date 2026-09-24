import Foundation

/// A chat turn's own permission hook (`011`, Karar 1): the inline settings a
/// `claude -p` turn is started with, the request it posts, and the decision
/// Evlat answers with.
///
/// The turn runs with `--permission-prompts none`, so anything that would
/// prompt is denied unless a `PermissionRequest` hook allows it. The hook is
/// Claude Code's documented `type: "http"` kind, pointed at Evlat's loopback
/// listener; its answer is held until the user presses a button on the card.
/// Every way that goes wrong — Evlat gone, the connection dropped, the hook's
/// time up, a non-2xx answer — leaves the hook without a decision, which
/// under `none` is a denial: the safe side.
///
/// The shapes are the ones Claude Code 2.1.281 validates (read from its
/// schema, `011/phase-3`): the input carries `tool_name`, `tool_input` and
/// `permission_suggestions`; the output is
/// `hookSpecificOutput.decision.behavior` with `updatedPermissions`.
///
/// Pure: strings and dictionaries in and out.
public enum PermissionHook {
    /// The route. Local only: a tunnel answers it `404` (`LocalAPI`).
    public static let path = "/permission"
    /// The header the token rides in — written as a **plain value** into
    /// the inline settings, not as an environment variable: a variable in the
    /// turn's environment would be inherited by every command its Bash tool
    /// runs. That is not secrecy: the inline settings are in the turn's
    /// argv, which any process of this user (the Bash tool's too) reads with
    /// `ps`. The token tells turns apart; what guards a grant is the user's
    /// press on a card that shows everything "always" keeps.
    public static let tokenHeader = "X-Evlat-Permission"
    /// How long Claude Code holds the request open, in seconds. The
    /// documented default for an http hook, written out so a change of
    /// default does not change how long a card can wait.
    public static let timeout = 600

    /// The only destination Evlat ever grants to: in memory, this session.
    /// The user's settings files (`localSettings`, `userSettings`, …) are
    /// never written through a card (Karar 8).
    static let destination = "session"

    /// Where a turn's hook posts, and the token that says which turn it is.
    public struct Endpoint: Equatable {
        public let port: UInt16
        public let token: String

        public init(port: UInt16, token: String) {
            self.port = port
            self.token = token
        }

        public var settings: String { PermissionHook.settings(port: port, token: token) }
    }

    // MARK: - The settings

    /// `--settings`' value: one `PermissionRequest` hook, `type: "http"`, on
    /// the port the listener actually bound. Sorted keys and unescaped
    /// slashes, so the string is the same on every run and readable in a
    /// process list.
    public static func settings(port: UInt16, token: String) -> String {
        let hook: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)\(path)",
            "headers": [tokenHeader: token],
            "timeout": timeout,
        ]
        let settings: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [hook]]]]]
        // Strings, an integer and nested containers of them always encode.
        let data = (try? JSONSerialization.data(withJSONObject: settings,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The request

    /// A permission rule: a tool, and optionally what it is limited to.
    public struct Rule: Equatable, Hashable {
        public let toolName: String
        public let ruleContent: String?

        public init(toolName: String, ruleContent: String? = nil) {
            self.toolName = toolName
            self.ruleContent = ruleContent
        }

        /// The rule as `--allowedTools` spells it: `Bash(ls:*)`, or the bare
        /// tool.
        public var text: String {
            guard let ruleContent, !ruleContent.isEmpty else { return toolName }
            return "\(toolName)(\(ruleContent))"
        }

        var json: [String: Any] {
            var json: [String: Any] = ["toolName": toolName]
            if let ruleContent { json["ruleContent"] = ruleContent }
            return json
        }
    }

    /// What Claude asks: one tool call, and the grants it suggests.
    public struct Request: Equatable {
        /// Evlat's name for this request, given when it is read: the held
        /// connection and the card are both keyed by it.
        public let id: String
        /// Which turn it belongs to; `nil` when the header was missing.
        public let token: String?
        public let tool: String
        /// `HookEvent.subject(of:)` over the input: the one line a card says.
        /// The input itself is not kept (`Write` carries a whole file).
        public let subject: String?
        /// The `addRules` suggestions that allow, flattened. Other kinds
        /// (`setMode`, `replaceRules`, …) are dropped here and never granted.
        public let rules: [Rule]
        /// The `addDirectories` suggestions: a folder outside the chat's.
        public let directories: [String]
        public let sessionID: String?
        public let cwd: String?

        public init(id: String, token: String?, tool: String, subject: String?, rules: [Rule] = [],
                    directories: [String] = [], sessionID: String? = nil, cwd: String? = nil) {
            self.id = id
            self.token = token
            self.tool = tool
            self.subject = subject
            self.rules = rules
            self.directories = directories
            self.sessionID = sessionID
            self.cwd = cwd
        }

        /// The hook's body. `nil` when it is not a `PermissionRequest` with a
        /// tool — a body Evlat cannot put on a card is refused, not guessed.
        public init?(json: [String: Any], token: String?, id: String = UUID().uuidString) {
            guard json["hook_event_name"] as? String ?? "PermissionRequest" == "PermissionRequest",
                  let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
            var rules: [Rule] = []
            var directories: [String] = []
            for suggestion in json["permission_suggestions"] as? [[String: Any]] ?? [] {
                switch suggestion["type"] as? String {
                case "addRules" where suggestion["behavior"] as? String == "allow":
                    for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
                        guard let name = rule["toolName"] as? String, !name.isEmpty else { continue }
                        let made = Rule(toolName: name, ruleContent: rule["ruleContent"] as? String)
                        if !rules.contains(made) { rules.append(made) }
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
            self.init(id: id, token: token, tool: tool,
                      subject: HookEvent.subject(of: json["tool_input"] as? [String: Any]),
                      rules: rules, directories: directories,
                      sessionID: json["session_id"] as? String, cwd: json["cwd"] as? String)
        }
    }

    // MARK: - The decision

    public enum Decision: Equatable {
        /// Allowed; the rules and folders are granted for the session too.
        case allow(rules: [Rule], directories: [String])
        /// `interrupt` ends the turn with it: the user pressed Stop.
        case deny(interrupt: Bool)
    }

    /// The message a denial carries back to Claude.
    static let deniedMessage = "The user denied this in Evlat."
    static let stoppedMessage = "The user stopped the turn in Evlat."

    /// The answer's body: `hookSpecificOutput.decision`, and in
    /// `updatedPermissions` only `addRules` and `addDirectories`, only to
    /// `session`.
    public static func body(_ decision: Decision) -> String {
        var inner: [String: Any]
        switch decision {
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
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": inner]]
        let data = (try? JSONSerialization.data(withJSONObject: output,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
