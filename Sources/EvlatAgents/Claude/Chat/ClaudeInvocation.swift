import Foundation
import EvlatCore

/// How one chat turn is started: `claude -p`'s arguments, the one stdin line
/// and what the environment gains (a process per turn).
///
/// Pure — the shell resolves the binary and the `PATH` and runs it, as the
/// backend's `TurnLaunch` (`ClaudeChat.turn`).
struct ClaudeInvocation: Equatable {
    let arguments: [String]
    /// One documented stream-json user line, newline-terminated. The stream
    /// stays open after it: the shell closes stdin when the `result` arrives,
    /// which is when the process exits (measured).
    let input: Data
    /// Added to the inherited environment.
    let environment: [String: String]
    /// The working directory the turn runs in.
    let directory: String

    /// The variable the installed hook command sends as `X-Evlat-Task`.
    static let taskVariable = TurnLaunch.taskVariable

    /// What a Claude Code session puts in its children's environment to say
    /// "you run inside me" (read off 2.1.281's bundle). An Evlat
    /// started from a Claude Code terminal inherits them; a turn that kept
    /// them would take itself for a child session and reach for the parent's
    /// messaging socket. User settings (`CLAUDE_CODE_USE_BEDROCK`, …) are not
    /// on the list and pass.
    static let parentSessionVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SSE_PORT",
    ]

    /// The turn's whole environment: `inherited` without a parent session's
    /// markers, plus what this turn adds.
    func environment(inheriting inherited: [String: String]) -> [String: String] {
        launch.environment(inheriting: inherited)
    }

    /// The flags every turn carries. `--verbose` is required by stream-json
    /// output on 2.1.281; `--include-partial-messages` is what streams the
    /// reply as it is written.
    static let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                       "--verbose", "--include-partial-messages"]

    /// The first turn names the session (`--session-id`: Evlat picks the id,
    /// so it is known before the process says it), later ones `--resume` it.
    /// `addDirectories` and `allowedTools` are what the chat was granted
    /// before; both flags take a list, so each value gets its own
    /// flag — a bare list would swallow the option after it.
    ///
    /// Both lists come from a card's suggestions, which Claude wrote: a
    /// value that would read as an option (`-…`) is dropped, and a folder
    /// must be absolute. A list flag takes a dash-led value as the next
    /// option, so `--add-dir --dangerously-…` would be a new flag, not a
    /// folder.
    ///
    /// `mode` is the chat's (`PermissionMode`): `--permission-mode`.
    static func turn(chatID: String, sessionID: String, resume: Bool,
                            prompt: String, attachments: [String], directory: String,
                            addDirectories: [String] = [], allowedTools: [String] = [],
                            mode: PermissionMode = .standard) -> ClaudeInvocation {
        // Every turn names its mode, a resumed one too: the chat's mode is
        // Evlat's to keep, not whatever the session or the user's settings
        // would start in.
        var arguments = base + ["--permission-mode", mode.rawValue]
        for directory in addDirectories where directory.hasPrefix("/") {
            arguments += ["--add-dir", directory]
        }
        for rule in allowedTools where !rule.isEmpty && !rule.hasPrefix("-") {
            arguments += ["--allowedTools", rule]
        }
        arguments += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        return ClaudeInvocation(arguments: arguments,
                                input: userLine(prompt: prompt, attachments: attachments),
                                environment: [taskVariable: chatID],
                                directory: directory)
    }

    /// The turn, asking its permissions through `endpoint`:
    /// `--permission-prompts none`, so what would prompt is denied unless
    /// the inline hook allows it, and `--settings` carrying that hook. The
    /// user's own settings still load; hooks merge across them (measured).
    /// Added when the turn starts, because only then is the
    /// listener's port known to be bound.
    ///
    /// `memoryDirectory` goes into the same settings as
    /// `autoMemoryDirectory` (`PermissionHook.settings`): a workspace chat's,
    /// never a chat in the user's folder.
    func asking(_ endpoint: PermissionHook.Endpoint, memoryDirectory: String? = nil) -> ClaudeInvocation {
        let settings = PermissionHook.settings(port: endpoint.port, token: endpoint.token,
                                               memoryDirectory: memoryDirectory)
        return ClaudeInvocation(arguments: arguments + ["--permission-prompts", "none", "--settings", settings],
                                input: input, environment: environment, directory: directory)
    }

    /// The turn as the shell starts it: one stdin line, and a parent
    /// session's markers taken out of what it inherits.
    var launch: TurnLaunch {
        TurnLaunch(arguments: arguments, input: [input], environment: environment,
                   removedEnvironment: Self.parentSessionVariables, directory: directory)
    }

    /// `{"type":"user","message":{"role":"user","content":…}}`. Attached
    /// files are named by path under the prompt; how they are labelled and
    /// suggested is `ChatFolder`'s.
    static func userLine(prompt: String, attachments: [String]) -> Data {
        let content = attachments.isEmpty ? prompt : prompt + "\n\n" + attachments.joined(separator: "\n")
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        // A dictionary of strings always serialises; the fallback is unreachable.
        var data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
