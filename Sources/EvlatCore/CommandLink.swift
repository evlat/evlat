import Foundation

/// `~/.local/bin/evlat` (`014`, R4): a symbolic link to this bundle's binary,
/// so `evlat watch …` works in a terminal. What is at the path now, the line
/// that makes it by hand and the line that takes it away. The writer is the
/// app's (`CommandLinkWriter`); this reads.
///
/// Every path is handed in, never defaulted — the writers' rule: a test
/// roots it in a temporary home, and only the app resolves the user's.
public enum CommandLink {
    public enum State: Equatable {
        /// A link to this binary.
        case current
        /// A link to another Evlat's binary — `build/` ↔ `/Applications`, or
        /// v1 (same bundle id). Made this one's only with the consent line
        /// saying so.
        case otherCopy(target: String)
        /// A link whose target is gone. Replaced only with consent, too.
        case broken(target: String)
        /// Anything that is not Evlat's: a file, a script, a link elsewhere.
        /// Never touched.
        case foreign
        case missing
    }

    /// Where the link goes, as the user reads it (and as the manual lines
    /// spell it: `~` is the shell's `HOME`).
    public static let displayPath = "~/.local/bin/" + LaunchMode.linkName
    public static let directoryDisplayPath = "~/.local/bin"

    /// The bundle id every Evlat carries (v1 and v2, `bundle-app.sh`).
    public static let bundleID = "dev.kalaomer.evlat"

    public static func directory(home: URL) -> URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static func link(home: URL) -> URL {
        directory(home: home).appendingPathComponent(LaunchMode.linkName)
    }

    /// What is at `link` now, against `binary` (this process's own).
    /// Reads, never writes.
    public static func state(at link: URL, binary: URL) -> State {
        let fm = FileManager.default
        // `attributesOfItem` does not follow the last link: a broken link
        // is still something, and it is not ours to call missing.
        guard (try? fm.attributesOfItem(atPath: link.path)) != nil else { return .missing }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return .foreign }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        guard fm.fileExists(atPath: target.path) else { return .broken(target: target.standardizedFileURL.path) }
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path == binary.resolvingSymlinksInPath().standardizedFileURL.path { return .current }
        return isEvlatBinary(resolved) ? .otherCopy(target: resolved.path) : .foreign
    }

    /// `….app/Contents/MacOS/<name>` whose `Info.plist` carries Evlat's
    /// bundle id. The name is not trusted alone: anyone may call a binary
    /// `Evlat`.
    public static func isEvlatBinary(_ url: URL) -> Bool {
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["CFBundleIdentifier"] as? String == bundleID
    }

    /// The line a user pastes instead: the same link the writer makes.
    /// `-f`: the block is also offered over another copy's or a broken link
    /// (`outdated`), where a bare `ln -s` stops at "File exists". A foreign
    /// file gets no block.
    public static func manualLine(binary: URL) -> String {
        "mkdir -p \(directoryDisplayPath) && ln -sf \(RemoteSettings.quoted(binary.path)) \(displayPath)"
    }

    /// Taking it away by hand.
    public static let removeLine = "rm \(displayPath)"

    /// Whether a `PATH` (the login shell's, `ClaudeLocator`) finds the link's
    /// directory under `home`. `~` and `$HOME` are spelled out as a profile
    /// may leave them.
    public static func isOnPath(_ path: String, home: URL) -> Bool {
        let wanted = directory(home: home).standardizedFileURL.path
        return path.split(separator: ":").contains { raw in
            var entry = String(raw)
            for prefix in ["~", "$HOME", "${HOME}"] where entry == prefix || entry.hasPrefix(prefix + "/") {
                entry = home.path + entry.dropFirst(prefix.count)
                break
            }
            return URL(fileURLWithPath: entry, isDirectory: true).standardizedFileURL.path == wanted
        }
    }
}
