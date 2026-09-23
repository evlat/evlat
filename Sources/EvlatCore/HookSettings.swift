import Foundation

/// Adds, updates and removes Evlat's hook command in an agent's settings file.
/// Claude Code and Codex share the same three-level shape: event → groups →
/// `{type, command, timeout}`.
///
/// The command written is `LocalAPI.installedHookCommand(for:)` and nothing
/// else, so the golden test that pins it pins what lands in the user's file.
/// No path has a default and nothing is read from the environment: the caller
/// hands in the file, and a test hands in a temporary one.
///
/// The transformations are pure (dictionary in, dictionary out); the file
/// half reads, transforms and writes with the user's data as the first
/// concern — a refused write is always better than a lost setting.
public enum HookSettings {
    public enum State: Equatable { case missing, current, outdated }

    /// What a write did. `unchanged` means the file was never opened for
    /// writing and its backup was not touched.
    public enum Outcome: Equatable { case written, unchanged }

    /// A closed set: the menu maps each case to a catalog string, so the text
    /// the user sees never comes from `localizedDescription`.
    public enum Failure: Error, Equatable {
        /// The file exists but could not be read.
        case unreadable
        /// Not JSON, the root is not an object, or the hooks sit in a shape
        /// the writer does not overwrite.
        case malformed
        /// The directory the file lives in does not exist; it is not created.
        case noDirectory
        /// The file changed between the read and the write; theirs is kept.
        case changedUnderneath
        /// The backup or the file itself could not be written.
        case unwritable
    }

    /// Ownership prefix. Derived, never spelled: it follows the port and the
    /// route the command itself is built from. Every source's path starts with
    /// Claude's `/hook`, and each source has its own file, so a match in a file
    /// belongs to that file's source.
    static var marker: String { "127.0.0.1:\(LocalAPI.defaultPort)\(AgentSource.claude.hookPath)" }

    /// A group is `Any`: another tool may have written something that is not
    /// an object, and a `[[String: Any]]` cast would drop the whole list —
    /// v1's install then deleted that tool's groups.
    private static func isOurs(_ group: Any) -> Bool {
        guard let group = group as? [String: Any],
              let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: - Pure

    /// Outdated means one of our commands differs from today's, or an event is
    /// missing one — either way a single install brings it back.
    public static func state(of settings: [String: Any], for source: AgentSource) -> State {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let ours = source.hookEvents.map { event in
            (hooks[event] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
                .filter { $0.contains(marker) }
        }
        guard ours.contains(where: { !$0.isEmpty }) else { return .missing }
        // A duplicate (two installs stacked on one event) fires every hook
        // twice; calling it outdated is what offers the install that folds it.
        guard !ours.contains(where: { $0.count != 1 }) else { return .outdated }
        let command = LocalAPI.installedHookCommand(for: source)
        return ours.joined().allSatisfy { $0 == command } ? .current : .outdated
    }

    /// Our first group changes in place, any further one is dropped, and an
    /// event without one gets it appended. Other tools' groups keep their
    /// index: Codex keys the trust it records for a hook by that index, and
    /// removing-then-appending shifted every group behind ours.
    public static func installing(into settings: [String: Any], for source: AgentSource) -> [String: Any] {
        let ours: [String: Any] = ["hooks": [[
            "type": "command", "command": LocalAPI.installedHookCommand(for: source), "timeout": 5,
        ]]]
        // A `hooks` that is not an object is someone else's data, same rule
        // as for an event's value below: it is left and nothing is installed.
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in source.hookEvents {
            // A value that is not an array is not ours to overwrite. It is
            // left, the event stays uninstalled and the state says outdated.
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            let groups = hooks[event] as? [Any] ?? []
            if let first = groups.firstIndex(where: isOurs) {
                hooks[event] = groups.enumerated().compactMap { index, group -> Any? in
                    index == first ? ours : (isOurs(group) ? nil : group)
                }
            } else {
                hooks[event] = groups + [ours]
            }
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    /// Only our groups go; an event key we emptied goes with them. An event
    /// that held none of ours is left exactly as it was.
    public static func removing(from settings: [String: Any], for source: AgentSource) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in source.hookEvents {
            guard let groups = hooks[event] as? [Any], groups.contains(where: isOurs) else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    // MARK: - Files

    public static func state(at url: URL, for source: AgentSource) throws -> State {
        let target = try resolve(url)
        return state(of: try parse(try bytes(at: target)), for: source)
    }

    /// An install that changes nothing yet leaves the hooks short of current
    /// met a value that is not ours to overwrite (a `hooks` that is not an
    /// object, an event that is not an array). Returning `unchanged` would
    /// clear the menu's line and offer the same entry forever; it is refused.
    @discardableResult
    public static func install(at url: URL, for source: AgentSource) throws -> Outcome {
        let outcome = try apply(at: url) { installing(into: $0, for: source) }
        if outcome == .unchanged, try state(at: url, for: source) != .current { throw Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL, for source: AgentSource) throws -> Outcome {
        try apply(at: url) { removing(from: $0, for: source) }
    }

    /// Resolve → read → transform → back up → re-read → write.
    ///
    /// - The link is resolved first: an atomic write replaces the file at its
    ///   path, so writing to the link would turn a dotfile manager's link into
    ///   a plain file.
    /// - The backup sits next to the path the user knows (`url`), is made
    ///   from the target's bytes (a copy of the link would be a link) and only
    ///   when there is none: the first backup is the one worth keeping.
    /// - The bytes are read again just before the write; if they differ, the
    ///   user or the agent saved in between and their version wins.
    ///
    /// `beforeWrite` exists for the test that changes the file in that gap.
    static func apply(
        at url: URL,
        beforeWrite: () -> Void = {},
        _ transform: ([String: Any]) -> [String: Any]
    ) throws -> Outcome {
        let target = try resolve(url)
        let original = try bytes(at: target)
        let settings = try parse(original)
        let changed = transform(settings)
        if NSDictionary(dictionary: changed).isEqual(to: settings) { return .unchanged }

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: changed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw Failure.unwritable
        }

        if let original {
            let backup = url.appendingPathExtension("evlat.bak")
            // `attributesOfItem` does not follow links: a dangling link there
            // still counts as a backup and is not written through.
            // The backup carries the target's mode: `settings.json` can hold
            // keys under `env`, and a 0644 copy of a 0600 file would expose them.
            let manager = FileManager.default
            if (try? manager.attributesOfItem(atPath: backup.path)) == nil {
                let mode = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o600
                guard manager.createFile(atPath: backup.path, contents: original,
                                         attributes: [.posixPermissions: mode]) else {
                    throw Failure.unwritable
                }
            }
        }

        beforeWrite()
        guard try bytes(at: target) == original else { throw Failure.changedUnderneath }
        do { try data.write(to: target, options: .atomic) } catch { throw Failure.unwritable }
        return .written
    }

    /// The path the write goes to. A link whose target is gone resolves to
    /// itself, and the atomic write would then replace the link with a plain
    /// file; it is refused instead.
    private static func resolve(_ url: URL) throws -> URL {
        let target = url.resolvingSymlinksInPath()
        let type = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw Failure.unreadable }
        return target
    }

    /// `nil` when the file does not exist but its directory does. A missing
    /// directory is an error, not an empty file: it means the agent is not
    /// there, and the write would have to create it.
    private static func bytes(at target: URL) throws -> Data? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Failure.noDirectory }
        guard manager.fileExists(atPath: target.path) else { return nil }
        do { return try Data(contentsOf: target) } catch { throw Failure.unreadable }
    }

    /// An absent or blank file is an empty object; anything else must be a
    /// JSON object, or nothing is written over it.
    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self)
            .allSatisfy({ $0.isWhitespace }) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else { throw Failure.malformed }
        return settings
    }
}
