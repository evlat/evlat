import Foundation

/// Evlat's own door on this Mac: a unix socket in a directory only the user
/// can enter. Pure — where it is, and the `curl` words that reach it; binding
/// and connecting are the shell's (`HookListener`, `UnixSocket`).
///
/// A socket file takes its mode from the umask (`755` measured), so the file
/// itself guards nothing: the directory does. It is made `0700` and refused
/// when it is a link or someone else's (`UnixSocket.prepareDirectory`).
public enum EvlatSocket {
    /// An absolute path here is the socket, wherever it is: a test's, a
    /// second Evlat's.
    public static let environmentKey = "EVLAT_SOCKET"

    /// Under the home: the folder a server's and this Mac's commands both
    /// name, so the installed bytes can be one.
    public static let relativePath = ".config/evlat/run/evlat.sock"

    /// A unix address holds 104 bytes, the last a NUL (`sockaddr_un.sun_path`).
    public static let pathLimit = 103

    /// The socket this environment points at, or `nil` for none.
    ///
    /// `EVLAT_SOCKET`, when set, is the answer: an absolute path, or none at
    /// all — a relative one is not quietly replaced by the user's socket,
    /// and a second Evlat (`Isolation.hasOwnSocket`) never takes the user's.
    /// Otherwise it is under the home: `EVLAT_HOME` (tilde expanded), else
    /// `home`. A path too long for an address is none: it could never be
    /// bound or reached.
    public static func path(environment: [String: String], home: String?) -> String? {
        let value = { (name: String) -> String? in
            let raw = environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? nil : raw
        }
        let path: String
        if let given = value(environmentKey) {
            guard given.hasPrefix("/") else { return nil }
            path = given
        } else {
            guard let root = value("EVLAT_HOME").map({ ($0 as NSString).expandingTildeInPath }) ?? home,
                  !root.isEmpty else { return nil }
            path = (root as NSString).appendingPathComponent(relativePath)
        }
        return fits(path) ? path : nil
    }

    /// Whether `path` fits a unix address, NUL included.
    public static func fits(_ path: String) -> Bool {
        let count = path.utf8.count
        return count > 0 && count <= pathLimit
    }

    // MARK: - The bytes from before it

    /// Whether `value` — a settings file's JSON, or any part of it — holds
    /// bytes an earlier copy of Evlat wrote, from before the socket: a
    /// string that names Evlat's url (`Curl.url`) and not the socket. That
    /// is the loopback port's command, its usage relay and its `http`
    /// approval hook; nobody listens on that port now, so each is silent
    /// until a press moves it. Every string is asked, at any depth, so one
    /// rule serves every agent's file shape.
    public static func predates(_ value: Any) -> Bool {
        switch value {
        case let text as String: return text.contains(Curl.url("/")) && !text.contains("--unix-socket")
        case let list as [Any]: return list.contains(where: predates)
        case let object as [String: Any]: return object.values.contains(where: predates)
        default: return false
        }
    }

    // MARK: - The curl words

    /// The words every `curl` that reaches the socket is made of — the chat
    /// turn's hook here, the installed commands on the same pieces — so a
    /// fix to one is a fix to all, each still pinned by its own golden test.
    public enum Curl {
        /// `-q` first: no `.curlrc`, which could add output, a proxy or a
        /// retry the command never asked for.
        public static let program = "curl -q"
        /// A proxy variable must never take a loopback request elsewhere.
        /// Single-quoted: the shell must not expand the `*`.
        public static let noProxy = "--noproxy '*'"

        /// `--unix-socket '<path>'`: the path quoted for `sh`, since a home
        /// can hold a space.
        public static func socket(_ path: String) -> String {
            "--unix-socket " + quoted(path)
        }

        /// `--unix-socket "$HOME/<relativePath>"`: the installed commands'
        /// socket, read where the command runs — this Mac or a server — so
        /// one string serves both. Double quotes: `$HOME` expands when the
        /// hook runs, a space in it stays one word, and the words fit inside
        /// a single-quoted `sh -c '…'` (the status line relay).
        public static let homeSocket = "--unix-socket \"$HOME/\(relativePath)\""

        /// The URL a request names. With `--unix-socket` the host only fills
        /// `Host:`, which must read as loopback (`LocalAPI.isLoopback`).
        public static func url(_ route: String) -> String {
            "http://127.0.0.1:\(LocalAPI.defaultPort)\(route)"
        }

        /// `value` as one `sh` word: single quotes, each `'` closed, escaped
        /// and opened again.
        public static func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
    }
}
