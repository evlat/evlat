import Foundation

/// A file Evlat writes whole, because it is Evlat's own: the agent loads it
/// from a folder it scans (a plugin), so there is no user file to merge into.
/// It is the second way a unit is installed, beside the hooks written into an
/// agent's settings (`AgentIntegration.Parts`).
///
/// The rules that keep the user's data first, in the order they matter:
///
/// - **The marker says whose it is.** A file at the path without Evlat's
///   marker is the user's, whatever else it holds: it is read as `foreign`,
///   never written over and never deleted. So is anything that is not a
///   plain file at the path (a link a dotfile manager made, a directory).
/// - **State is read from the bytes.** Equal to this build's → `current`;
///   marked and different → `outdated`; and a marked file of a later version
///   is `current` too, as `RemoteCommand` reads a server's: another copy of
///   Evlat that is newer installed it, and this one does not call it old.
/// - **A write is one `rename`.** The previous file stays whole until it
///   succeeds, and no backup is kept: the file is Evlat's, regenerated from
///   constants, so there is nothing of the user's to keep.
/// - **A removal takes the one marked file** and nothing around it: not the
///   directory, not its neighbours.
///
/// The marker and the version are two consecutive lines at the head, in the
/// shape of `RemoteCommand.script`'s second and third. Nothing here names an
/// agent or has a default path: `home` is the caller's.
public struct OwnedFile: Equatable {
    public enum State: Equatable { case missing, current, outdated, foreign }

    /// Relative to a home.
    public let path: String
    /// The marker line's whole text, comment prefix included.
    public let marker: String
    /// The version line's text up to the number.
    public let versionPrefix: String
    public let version: Int
    public let contents: String

    /// The marker is looked for in the first lines only: it is a header
    /// (`RemoteCommand`'s is line 2, behind a shebang; a file with none has
    /// room to move), and a user's file that happens to quote it further down
    /// is still theirs.
    static let headerLines = 5

    /// The file is `<comment> <marker>`, `<comment> version <n>`, then
    /// `body`. `comment` is the language's line-comment prefix (`//`, `#`).
    public init(path: String, comment: String, marker: String, version: Int, body: String) {
        self.path = path
        self.marker = "\(comment) \(marker)"
        self.versionPrefix = "\(comment) version "
        self.version = version
        contents = "\(self.marker)\n\(versionPrefix)\(version)\n\(body)"
    }

    public func url(home: URL) -> URL {
        home.appendingPathComponent(path)
    }

    /// The state of the bytes found at the path; `nil` is no file.
    public func state(of bytes: Data?) -> State {
        guard let bytes else { return .missing }
        if bytes == Data(contents.utf8) { return .current }
        let found = Self.header(of: bytes, marker: marker, versionPrefix: versionPrefix)
        guard found.marked else { return .foreign }
        if let later = found.version, later > version { return .current }
        return .outdated
    }

    /// Whether the head carries `marker`, and the version on the line after
    /// it (`nil` when that line is not one).
    static func header(of bytes: Data, marker: String, versionPrefix: String) -> (marked: Bool, version: Int?) {
        let head = String(decoding: bytes.prefix(2048), as: UTF8.self)
            .split(separator: "\n", maxSplits: headerLines, omittingEmptySubsequences: false)
            .prefix(headerLines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let at = head.firstIndex(of: marker) else { return (false, nil) }
        guard at + 1 < head.count, head[at + 1].hasPrefix(versionPrefix) else { return (true, nil) }
        return (true, Int(head[at + 1].dropFirst(versionPrefix.count)))
    }

    // MARK: - On disk

    /// Read fresh. A missing file, or a missing folder, is `missing`; anything
    /// that is not a plain file is `foreign` and is not opened; a plain file
    /// that cannot be read is thrown, not guessed at.
    public func state(home: URL) throws -> State {
        try read(home: home).state
    }

    private func read(home: URL) throws -> (state: State, bytes: Data?) {
        let target = url(home: home)
        let type: FileAttributeType?
        do {
            type = try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return (.missing, nil)
        } catch {
            throw SettingsFile.Failure.unreadable
        }
        guard type == .typeRegular else { return (.foreign, nil) }
        guard let bytes = try? Data(contentsOf: target) else { throw SettingsFile.Failure.unreadable }
        return (state(of: bytes), bytes)
    }

    /// Writes the file unless it is current. A `foreign` file is refused
    /// (`malformed`: not a shape this writer overwrites). The folder is made
    /// only when `opensDirectory` says so; otherwise a missing one is
    /// `noDirectory`, as for a settings file.
    @discardableResult
    public func install(home: URL, opensDirectory: Bool) throws -> SettingsFile.Outcome {
        let before = try read(home: home)
        switch before.state {
        case .current: return .unchanged
        case .foreign: throw SettingsFile.Failure.malformed
        case .missing, .outdated: break
        }
        let target = url(home: home)
        let directory = target.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard opensDirectory else { throw SettingsFile.Failure.noDirectory }
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw SettingsFile.Failure.unwritable }
        } else if !isDirectory.boolValue {
            throw SettingsFile.Failure.noDirectory
        }
        // Read again just before the write, bytes and all, as a settings
        // file is: what appeared or changed in between is the user's, and it
        // wins.
        let again = try read(home: home)
        guard again.state == before.state, again.bytes == before.bytes else {
            throw SettingsFile.Failure.changedUnderneath
        }
        // A new file is 0644, not a settings file's 0600: it holds code, not
        // the user's keys, and the agent reads it as the user.
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o644
        try SettingsFile.replace(target, with: Data(contents.utf8), mode: mode)
        return .written
    }

    /// Takes the file out when it is Evlat's (`current` or `outdated`);
    /// anything else is left as it is.
    @discardableResult
    public func remove(home: URL) throws -> SettingsFile.Outcome {
        switch try state(home: home) {
        case .missing, .foreign: return .unchanged
        case .current, .outdated: break
        }
        do { try FileManager.default.removeItem(at: url(home: home)) } catch { throw SettingsFile.Failure.unwritable }
        return .written
    }
}
