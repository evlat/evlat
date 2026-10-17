import Foundation

/// Local repository identity for presentation. Reads only bounded Git metadata;
/// never runs Git, follows config includes, contacts a remote, or reads titles.
public enum GitRepository {
    public struct Identity: Equatable, Hashable {
        /// Transport-independent host/path, with credentials and query removed.
        public let key: String
        public let name: String
        public init(key: String, name: String) { self.key = key; self.name = name }
    }

    /// The first URL of `origin`. Linked worktrees share their common config.
    /// Unsupported or missing configuration is unknown, so callers use folders.
    public static func origin(in folder: String) -> Identity? {
        guard folder.hasPrefix("/"), var git = GitHead.gitDirectory(above: folder) else { return nil }
        let commonPath = git + "/commondir"
        if FileManager.default.fileExists(atPath: commonPath) {
            guard let common = read(commonPath, limit: 512)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !common.isEmpty, !common.contains("\n") else { return nil }
            git = common.hasPrefix("/") ? common : (git as NSString).appendingPathComponent(common)
        }
        guard let config = read(git + "/config", limit: 65_536), let url = originURL(in: config) else { return nil }
        return identity(url, relativeTo: (git as NSString).deletingLastPathComponent)
    }

    static func originURL(in config: String) -> String? {
        var origin = false
        for raw in config.components(separatedBy: .newlines) {
            guard let decoded = value(raw) else { return nil }
            let line = decoded.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                // Decode quotes before matching, but keep remote names case-sensitive.
                origin = line.range(of: #"^\[\s*(?i:remote)\s+origin\s*\]$"#, options: .regularExpression) != nil
                continue
            }
            guard origin else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
            guard parts.count == 2, parts[0].lowercased() == "url" else { continue }
            let url = parts[1].trimmingCharacters(in: .whitespaces).drop(while: { $0 == "=" || $0.isWhitespace })
            return url.isEmpty ? nil : String(url)
        }
        return nil
    }

    /// Git config quoting/comments, restricted to one-line values. Includes,
    /// substitutions and continuations deliberately remain unsupported.
    private static func value(_ line: String) -> String? {
        var quoted = false, escaped = false, result = ""
        for char in line {
            if escaped {
                guard char == "\\" || char == "\"" else { return nil }
                result.append(char); escaped = false
            } else if char == "\\" { escaped = true }
            else if char == "\"" { quoted.toggle() }
            else if !quoted && (char == "#" || char == ";") { break }
            else { result.append(char) }
        }
        return quoted || escaped ? nil : result
    }

    static func identity(_ raw: String, relativeTo folder: String) -> Identity? {
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        let key: String
        if raw.contains("://") {
            guard let url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "file"].contains(scheme), !url.path.isEmpty else { return nil }
            if scheme == "file" {
                guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                key = "file:" + (url.path as NSString).standardizingPath
            } else {
                guard let host = url.host, !host.isEmpty else { return nil }
                let defaults = ["https": 443, "http": 80, "ssh": 22, "git": 9418]
                let port = url.port.flatMap { $0 == defaults[scheme] ? nil : ":\($0)" } ?? ""
                key = host.lowercased() + port + "/" + url.path.drop(while: { $0 == "/" })
            }
        } else if !raw.hasPrefix("/"), let colon = raw.firstIndex(of: ":") {
            guard !raw.contains("::") else { return nil }
            let authority = String(raw[..<colon])
            guard !authority.contains("/"), let host = authority.split(separator: "@").last, !host.isEmpty else { return nil }
            let path = raw[raw.index(after: colon)...].drop(while: { $0 == "/" })
            guard !path.isEmpty else { return nil }
            key = host.lowercased() + "/" + path
        } else {
            let path = raw.hasPrefix("/") ? raw : (folder as NSString).appendingPathComponent(raw)
            key = "file:" + (path as NSString).standardizingPath
        }
        var canonical = key
        while canonical.hasSuffix("/") { canonical.removeLast() }
        if canonical.hasSuffix(".git") { canonical.removeLast(4) }
        let name = (canonical as NSString).lastPathComponent
        guard !name.isEmpty, !canonical.hasSuffix(":"), !canonical.hasSuffix("/"),
              name != ".", name != ".." else { return nil }
        return Identity(key: canonical, name: name)
    }

    private static func read(_ path: String, limit: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), data.count < limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
