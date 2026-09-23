import Foundation

/// The file half every writer of an agent's settings shares: resolve, read,
/// transform, back up, re-read, write. `HookSettings` and `StatusLineRelay`
/// only say *what* changes; how the user's file is touched is decided here,
/// once, with the user's data as the first concern — a refused write is always
/// better than a lost setting.
///
/// No path has a default and nothing is read from the environment: the caller
/// hands in the file, and a test hands in a temporary one.
public enum SettingsFile {
    /// What a write did. `unchanged` means the file was never opened for
    /// writing and its backups were not touched.
    public enum Outcome: Equatable { case written, unchanged }

    /// A closed set: the menu maps each case to a catalog string, so the text
    /// the user sees never comes from `localizedDescription`.
    public enum Failure: Error, Equatable {
        /// The file exists but could not be read.
        case unreadable
        /// Not JSON, the root is not an object, or the value to change sits in
        /// a shape the writer does not overwrite.
        case malformed
        /// The directory the file lives in does not exist; it is not created.
        case noDirectory
        /// The file changed between the read and the write; theirs is kept.
        case changedUnderneath
        /// A backup or the file itself could not be written.
        case unwritable
    }

    /// The settings as they are now; an absent or blank file is `[:]`.
    static func read(_ url: URL) throws -> [String: Any] {
        try parse(try bytes(at: try resolve(url)))
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
    /// - `backUp` is a writer's own backup, handed the settings as read and
    ///   the target's mode; it runs after that check, only when the file is
    ///   about to change.
    ///
    /// `beforeWrite` exists for the test that changes the file in that gap.
    static func apply(
        at url: URL,
        beforeWrite: () -> Void = {},
        backUp: (_ settings: [String: Any], _ mode: Any) throws -> Void = { _, _ in },
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

        // The backups carry the target's mode: `settings.json` can hold keys
        // under `env`, and a 0644 copy of a 0600 file would expose them.
        let manager = FileManager.default
        let mode = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o600
        if let original {
            let backup = url.appendingPathExtension("evlat.bak")
            // `attributesOfItem` does not follow links: a dangling link there
            // still counts as a backup and is not written through.
            if (try? manager.attributesOfItem(atPath: backup.path)) == nil {
                guard manager.createFile(atPath: backup.path, contents: original,
                                         attributes: [.posixPermissions: mode]) else {
                    throw Failure.unwritable
                }
            }
        }

        beforeWrite()
        guard try bytes(at: target) == original else { throw Failure.changedUnderneath }
        // After the re-read: a write refused for a change underneath must not
        // have replaced the writer's backup either.
        try backUp(settings, mode)
        do { try data.write(to: target, options: .atomic) } catch { throw Failure.unwritable }
        return .written
    }

    /// Writes `contents` at `url` with `mode`, replacing a file or a link
    /// there (the link itself, never its target) in one `rename`: until it
    /// succeeds the previous file stays whole, and a directory at `url` makes
    /// it fail rather than be removed.
    static func replace(_ url: URL, with contents: Data, mode: Any) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: contents,
                                 attributes: [.posixPermissions: mode]) else {
            throw Failure.unwritable
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw Failure.unwritable
        }
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
