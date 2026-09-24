import Foundation

/// Wraps the user's Claude Code `statusLine` command so each status line JSON
/// also reaches Evlat (`POST /usage/claude`), and takes the wrapper out again.
///
/// The wrapper is one `sh -c` line with the original as its `$1`:
///
///     sh -c '<relay> printf %s "$i" | sh -c "$1"' evlat-statusline '<original>'
///
/// `<relay>` reads stdin byte for byte (`printf x` keeps trailing newlines
/// that `$(…)` would strip), posts it in the background with its output
/// thrown away — nothing reaches the status line and nothing waits for Evlat
/// — then hands the same bytes to the original, whose output and exit code
/// are the wrapper's. With no original the wrapper only relays; its empty
/// output is the empty status line Claude Code draws without one.
///
/// The installed string is a fixed point like the hook command: it carries
/// `LocalAPI.defaultPort`, never `EVLAT_PORT`, and its golden test pins it.
/// Anything that contains the marker but is not exactly a wrapper this code
/// would write is `modified`: neither installed over nor taken apart.
public enum StatusLineRelay {
    public enum State: Equatable { case missing, current, modified }

    /// `$0` of the wrapper's shell; it names the line in `ps`.
    static let name = "evlat-statusline"

    private static var path: String {
        // Only Claude has a usage route; `LocalAPITests` pins it.
        AgentSource.claude.usagePath!
    }

    /// Ownership mark: derived from the port and the route, never spelled.
    static var marker: String { "127.0.0.1:\(LocalAPI.defaultPort)\(path)" }

    private static func relay(port: UInt16) -> String {
        #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -s -m 2 -X POST"#
            + #" -H "Content-Type: application/json" --data-binary @-"#
            + " http://127.0.0.1:\(port)\(path) >/dev/null 2>&1 &"
    }

    /// Everything before the quoted original.
    private static func head(port: UInt16) -> String {
        "sh -c '" + relay(port: port) + #" printf %s "$i" | sh -c "$1"' "# + name + " "
    }

    /// A single-quoted shell word: each `'` closes, is escaped and reopens.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The wrapper around `original`; `nil` when there was no command.
    public static func command(wrapping original: String?, port: UInt16 = LocalAPI.defaultPort) -> String {
        guard let original else { return "sh -c '" + relay(port: port) + "'" }
        return head(port: port) + quoted(original)
    }

    /// What `command` wraps: `.some(nil)` for the relay alone, `nil` when it
    /// is not exactly a wrapper `command(wrapping:)` writes.
    static func original(in command: String) -> String?? {
        if command == self.command(wrapping: nil) { return .some(nil) }
        let head = head(port: LocalAPI.defaultPort)
        guard command.hasPrefix(head) else { return nil }
        let word = String(command.dropFirst(head.count))
        guard word.count >= 2, word.hasPrefix("'"), word.hasSuffix("'") else { return nil }
        let text = String(word.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        // The round trip rejects anything this code would not have written.
        return quoted(text) == word ? .some(text) : nil
    }

    // MARK: - Pure

    public static func state(of settings: [String: Any]) -> State {
        guard let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String, command.contains(marker) else { return .missing }
        return original(in: command) == nil ? .modified : .current
    }

    /// The command is wrapped in place; `padding`, `refreshInterval` and any
    /// other neighbour stay. `type` is added only when there was no command
    /// either, so a removal can take both out again. `nil` is a refusal:
    /// a modified wrapper, or a `statusLine` in a shape that is not ours to
    /// overwrite.
    public static func installing(into settings: [String: Any]) -> [String: Any]? {
        var result = settings
        guard let value = settings["statusLine"] else {
            result["statusLine"] = ["type": "command", "command": command(wrapping: nil)]
            return result
        }
        guard var line = value as? [String: Any] else { return nil }
        switch state(of: settings) {
        case .current: return settings
        case .modified: return nil
        case .missing: break
        }
        if let type = line["type"], type as? String != "command" { return nil }
        if let existing = line["command"] {
            guard let existing = existing as? String else { return nil }
            line["command"] = command(wrapping: existing)
        } else {
            if line["type"] == nil { line["type"] = "command" }
            line["command"] = command(wrapping: nil)
        }
        result["statusLine"] = line
        return result
    }

    /// Strict: the original goes back as it was, or the relay alone goes with
    /// the `type` it brought and a `statusLine` left empty. A modified
    /// wrapper is `nil` — no half removal. Nothing of ours: unchanged.
    ///
    /// The one inexact case: a `statusLine` that had `type: command` and no
    /// command loses that `type` too — the wrapper does not record whether
    /// it added it. Such an entry draws nothing either way.
    public static func removing(from settings: [String: Any]) -> [String: Any]? {
        guard var line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String, command.contains(marker) else { return settings }
        guard let original = original(in: command) else { return nil }
        if let original {
            line["command"] = original
        } else {
            line["command"] = nil
            if line["type"] as? String == "command" { line["type"] = nil }
        }
        var result = settings
        result["statusLine"] = line.isEmpty ? nil : line
        return result
    }

    // MARK: - Files

    /// Appended to the settings file's name for the install's own backup.
    static let backupExtension = "statusline.evlat.bak"

    /// What that backup holds: the `statusLine` as it was, `null` for none.
    /// Shared with `RemoteSettings`, so a server's backup has the same bytes.
    static func backupContents(of settings: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: settings["statusLine"] ?? NSNull(),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        } catch {
            throw SettingsFile.Failure.unwritable
        }
    }

    public static func state(at url: URL) throws -> State {
        state(of: try SettingsFile.read(url))
    }

    /// Every install that writes first keeps the `statusLine` it is about to
    /// wrap (`null` when there was none) in `settings.json.statusline.evlat.bak`,
    /// overwriting the last one: the general `.evlat.bak` is taken only once,
    /// and may predate the command the user has now.
    ///
    /// A refusal writes nothing and is `malformed`, as for the hooks.
    @discardableResult
    public static func install(at url: URL) throws -> SettingsFile.Outcome {
        let backup = url.appendingPathExtension(backupExtension)
        let outcome = try SettingsFile.apply(at: url, backUp: { settings, mode in
            try SettingsFile.replace(backup, with: try backupContents(of: settings), mode: mode)
        }) { installing(into: $0) ?? $0 }
        if outcome == .unchanged, try state(at: url) != .current { throw SettingsFile.Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL) throws -> SettingsFile.Outcome {
        let outcome = try SettingsFile.apply(at: url) { removing(from: $0) ?? $0 }
        if outcome == .unchanged, try state(at: url) == .modified { throw SettingsFile.Failure.malformed }
        return outcome
    }
}
