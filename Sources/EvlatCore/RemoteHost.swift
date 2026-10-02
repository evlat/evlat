import Foundation

/// Where a remote session's terminal is, asked of its server: a read-only
/// script, run over the machine's tunnel master, finds the session's process
/// from the agent's own records (`SessionRecords`) and says which ssh
/// connection it runs under. The Mac then looks for its own `ssh` holding
/// that connection (`SessionHost`, in the shell).
///
/// Nothing is installed and nothing is versioned: the script is sent whole
/// on each call and writes nothing on the server. It names no agent — the
/// record folder and its keys are the agent's values.
public enum RemoteHost {
    /// What the server said about the session.
    public enum Reply: Equatable {
        /// The ssh connection the session's process runs under.
        case connection(Connection)
        /// The process runs under no ssh connection the script can see — a
        /// console, a service, a socket-activated `sshd -i`. Said outright,
        /// so it is never mistaken for "the one ssh there is".
        case noConnection
    }

    /// One ssh connection as the server sees it.
    public struct Connection: Equatable {
        /// `SSH_CONNECTION`'s client port: the Mac's own port, unless a NAT
        /// on the way rewrote it — at home it usually does.
        public let clientPort: Int
        /// `SSH_CONNECTION`'s server port.
        public let serverPort: Int
        /// When the connection's `sshd` started, on the server's clock: it
        /// starts on the accept, so it is within a moment of the Mac's `ssh`.
        public let startedAt: Date
        /// The server's clock minus this Mac's, as far as one reply can tell:
        /// the script's own time against the moment its answer arrived.
        /// `nil` when the server printed no usable time.
        public let offset: TimeInterval?

        public init(clientPort: Int, serverPort: Int, startedAt: Date, offset: TimeInterval?) {
            self.clientPort = clientPort
            self.serverPort = serverPort
            self.startedAt = startedAt
            self.offset = offset
        }

        /// The connection's start on this Mac's clock; `nil` without an
        /// offset, and then no start is compared.
        public var localStart: Date? {
            offset.map { startedAt.addingTimeInterval(-$0) }
        }
    }

    // MARK: - The session

    /// Whether `text` is a session id as the hooks send it: a UUID. Nothing
    /// else ever reaches a script.
    public static func isSessionID(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text) != nil
    }

    /// The session's id from a remote row's entity (`remote:<machine>:<id>`,
    /// `HooksProvider`); `nil` for any other entity, or one whose id is not
    /// a session id.
    public static func sessionID(entity: String, machineID: String) -> String? {
        let prefix = "remote:\(machineID):"
        guard entity.hasPrefix(prefix) else { return nil }
        let id = String(entity.dropFirst(prefix.count))
        return isSessionID(id) ? id : nil
    }

    // MARK: - The call

    /// `RemoteSettings.arguments` over the master, and **only** over it: if
    /// the master has gone, `ssh` would connect by itself — a new login on
    /// the server for a button. `ProxyCommand` fails that connection before
    /// it opens anything (measured: exit 255 in ~40 ms, nothing sent), while
    /// a live master never runs it. A command-line option is read before the
    /// user's config, so a configured `ProxyJump` does not take its place.
    public static func arguments(target: String, controlPath: String) -> [String] {
        var arguments = RemoteSettings.arguments(target: target, controlPath: controlPath)
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        arguments.insert(contentsOf: ["-o", "ProxyCommand=/usr/bin/false"], at: end)
        return arguments
    }

    /// The script, or `nil` for an id that is not a session id.
    ///
    /// It finds a record under `$HOME/<directory>` whose `idKey` is the
    /// session, takes its live `pidKey`, and reads that process's
    /// environment and parents under `proc` (a parameter so a test can hand
    /// it a tree of its own):
    /// - a session in tmux or herdr prints **nothing**: its environment is
    ///   the server's first client's, which may be long gone;
    /// - otherwise the parents are walked up to the connection's `sshd` —
    ///   the one whose parent is the listener (`sshd`, parent 1), whatever
    ///   it is called (`sshd`, or `sshd-session` from 9.8) — and its start
    ///   is printed with `SSH_CONNECTION`'s ports and the script's own time;
    /// - no such `sshd`: `none`.
    /// Not Linux (no `<proc>/self`), no record, no live process: nothing.
    /// Only a walk up the parents, never a scan of every process.
    public static func script(sessionID: String, records: SessionRecords, nonce: String,
                              proc: String = "/proc") -> String? {
        guard isSessionID(sessionID) else { return nil }
        let q = RemoteSettings.quoted
        return #"""
        n=\#(q(nonce))
        r=\#(q(proc))
        d="$HOME"/\#(q(records.directory))
        id=\#(q(sessionID))
        ik=\#(q(records.idKey))
        pk=\#(q(records.pidKey))
        [ -d "$r/self" ] || exit 0
        p=
        for f in "$d"/*.json; do
          [ -f "$f" ] || continue
          grep -q "\"$ik\"[[:space:]]*:[[:space:]]*\"$id\"" "$f" 2>/dev/null || continue
          x=$(sed -n "s/.*\"$pk\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -n 1)
          if [ -n "$x" ] && [ -d "$r/$x" ]; then p=$x; break; fi
        done
        [ -n "$p" ] || exit 0
        e=$(tr '\000' '\n' < "$r/$p/environ" 2>/dev/null) || exit 0
        if printf '%s\n' "$e" | grep -Eq '^(TMUX|HERDR_ENV)='; then exit 0; fi
        st() {
          s=$(cat "$r/$1/stat" 2>/dev/null) || return 1
          C=${s#*\(}
          C=${C%\)*}
          set -f
          set -- ${s##*\) }
          set +f
          [ $# -ge 20 ] || return 1
          P=$2
          shift 19
          T=$1
        }
        x=$p
        k=0
        while [ $k -lt 64 ]; do
          st "$x" || break
          c=$C
          u=$P
          t=$T
          case $c in
            sshd|sshd-session)
              if [ "$u" -gt 1 ] 2>/dev/null && st "$u" && [ "$C" = sshd ] && [ "$P" = 1 ]; then
                b=$(sed -n 's/^btime //p' "$r/stat" 2>/dev/null)
                set -f
                set -- $(printf '%s\n' "$e" | sed -n 's/^SSH_CONNECTION=//p' | head -n 1)
                set +f
                [ $# -eq 4 ] || exit 0
                printf '%s ssh %s %s %s %s %s\n' "$n" "$2" "$4" "$b" "$t" "$(date +%s.%N)"
                exit 0
              fi
              ;;
          esac
          [ "$u" -gt 1 ] 2>/dev/null || break
          x=$u
          k=$((k + 1))
        done
        printf '%s none\n' "$n"
        exit 0

        """#
    }

    // MARK: - The answer

    /// The process start's unit in `/proc/<pid>/stat`: Linux's `USER_HZ`,
    /// which is 100 everywhere it is exposed.
    static let ticksPerSecond = 100.0

    /// The script's line behind whatever a login script printed first;
    /// `nil` for no line, a failed call, or a line that does not parse —
    /// all of them "not known", never a guess. `arrivedAt` is when the
    /// answer reached this Mac: the clock offset is read against it.
    public static func reply(exitCode: Int32, output: Data, nonce: String, arrivedAt: Date) -> Reply? {
        guard exitCode == 0 else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix(nonce + " ") }) else { return nil }
        let words = line.split(separator: " ").map(String.init)
        if words == [nonce, "none"] { return .noConnection }
        guard words.count == 7, words[1] == "ssh",
              let client = Int(words[2]), (1...65535).contains(client),
              let server = Int(words[3]), (1...65535).contains(server),
              let boot = Int(words[4]), boot > 0,
              let ticks = Int(words[5]), ticks >= 0 else { return nil }
        let started = Date(timeIntervalSince1970: Double(boot) + Double(ticks) / ticksPerSecond)
        // `date` without `%N` (busybox, BSD) prints a letter there: no offset.
        let offset = Double(words[6]).flatMap { $0.isFinite ? $0 : nil }.map { $0 - arrivedAt.timeIntervalSince1970 }
        return .connection(Connection(clientPort: client, serverPort: server, startedAt: started, offset: offset))
    }
}
