import Foundation

/// How one chat turn is started: `claude -p`'s arguments, the one stdin line
/// and what the environment gains (`011`, Karar 2: a process per turn).
///
/// Pure — the shell resolves the binary and the `PATH` and runs it
/// (`ClaudeRunner`).
public struct ClaudeInvocation: Equatable {
    public let arguments: [String]
    /// One documented stream-json user line, newline-terminated. The stream
    /// stays open after it: the shell closes stdin when the `result` arrives,
    /// which is when the process exits (measured, `011/phase-1`).
    public let input: Data
    /// Added to the inherited environment.
    public let environment: [String: String]
    /// The working directory the turn runs in.
    public let directory: String

    /// The variable the installed hook command sends as `X-Evlat-Task`
    /// (`LocalAPI.installedHookCommand`), so the user's own hooks mark this
    /// turn's events as an Evlat errand and `HooksProvider` leaves them out.
    public static let taskVariable = "EVLAT_TASK"

    /// The flags every turn carries. `--verbose` is required by stream-json
    /// output on 2.1.281; `--include-partial-messages` is what streams the
    /// reply as it is written.
    public static let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                       "--verbose", "--include-partial-messages"]

    /// The first turn names the session (`--session-id`: Evlat picks the id,
    /// so it is known before the process says it), later ones `--resume` it.
    /// `addDirectories` and `allowedTools` are what the chat was granted
    /// before (`phase-3`); both flags take a list, so each value gets its own
    /// flag — a bare list would swallow the option after it.
    public static func turn(chatID: String, sessionID: String, resume: Bool,
                            prompt: String, attachments: [String], directory: String,
                            addDirectories: [String] = [], allowedTools: [String] = []) -> ClaudeInvocation {
        var arguments = base
        for directory in addDirectories { arguments += ["--add-dir", directory] }
        for rule in allowedTools { arguments += ["--allowedTools", rule] }
        arguments += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        return ClaudeInvocation(arguments: arguments,
                                input: userLine(prompt: prompt, attachments: attachments),
                                environment: [taskVariable: chatID],
                                directory: directory)
    }

    /// `{"type":"user","message":{"role":"user","content":…}}`. Attached
    /// files are named by path under the prompt; how they are labelled and
    /// suggested is `phase-4`'s.
    static func userLine(prompt: String, attachments: [String]) -> Data {
        let content = attachments.isEmpty ? prompt : prompt + "\n\n" + attachments.joined(separator: "\n")
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        // A dictionary of strings always serialises; the fallback is unreachable.
        var data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
