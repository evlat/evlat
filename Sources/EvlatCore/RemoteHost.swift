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
        /// console, a service, a socket-activated `sshd -i` — or it is in a
        /// tmux or herdr pane no client is attached to. Said outright, so
        /// it is never mistaken for "the one ssh there is".
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
        /// The forwarded variables (`script`'s `forwarded`) the connection's
        /// process has, as `NAME=value` lines in the order asked. Not
        /// checked here beyond their shape: what a value may be is the
        /// shell's rule.
        public let forwarded: [String]
        /// The herdr pane the session runs in on the server, and whether
        /// the click can select it (`selectScript`); `nil` when it runs in
        /// no herdr pane there.
        public let herdrPane: Pane?

        public init(clientPort: Int, serverPort: Int, startedAt: Date, offset: TimeInterval?,
                    forwarded: [String] = [], herdrPane: Pane? = nil) {
            self.clientPort = clientPort
            self.serverPort = serverPort
            self.startedAt = startedAt
            self.offset = offset
            self.forwarded = forwarded
            self.herdrPane = herdrPane
        }

        /// The connection's start on this Mac's clock; `nil` without an
        /// offset, and then no start is compared.
        public var localStart: Date? {
            offset.map { startedAt.addingTimeInterval(-$0) }
        }
    }

    /// A herdr pane on the server, as the lookup found it.
    public enum Pane: Equatable {
        /// herdr takes it as an agent's pane (`agent get`): `agent focus`
        /// selects it.
        case selectable
        /// In herdr, but herdr would not select it — not taken as an
        /// agent's, not found among the server's panes, or a server that
        /// cannot be asked. The window still comes; the card says so.
        case unselectable
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

    // MARK: - Forwarded variables

    /// The most names one script reads.
    public static let maxForwarded = 16
    /// The longest value the script prints and the Mac reads, in bytes.
    public static let maxForwardedValue = 512

    /// Whether `name` may be read on the server: an `LC_` name, the only
    /// kind `ssh` carries by default (`SendEnv`/`AcceptEnv LANG LC_*`), and
    /// nothing a shell or a `sed` pattern could take for more than a word.
    public static func isForwardedName(_ name: String) -> Bool {
        let tail = name.utf8.dropFirst(3)
        return name.hasPrefix("LC_") && (1...64).contains(tail.count)
            && tail.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
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
    /// session, takes its live `pidKey` — one whose start is within 120 s of
    /// the record's `startedAtKey`, when both are there, as
    /// `Platform.sameProcess` holds it: pids are recycled, and a record a
    /// crash left behind may name another process — and reads that process's
    /// environment and parents under `proc` (a parameter so a test can hand
    /// it a tree of its own). The process whose connection is said is:
    /// - in a tmux pane (`TMUX`), the client of the pane's session that did
    ///   something last, with a terminal — asked of the server's own
    ///   executable (`<proc>/<pid>/exe`, never `PATH`), the same question
    ///   and the same rule as this Mac's (`TmuxQuery`);
    /// - in a herdr pane (`HERDR_ENV`), the newest client connected to the
    ///   server's `herdr-client.sock`, with a terminal: the server's ends of
    ///   that socket from `<proc>/net/unix` and its `fd` links, their peers
    ///   from `ss -x` (`/proc` names no peer). herdr's own ssh bridge counts
    ///   without one — `herdr [--session <name>] remote-client-bridge
    ///   [--idle-timeout-v1]`, exactly, which `herdr --remote` runs under
    ///   `sshd` with no terminal and the ssh connection's environment
    ///   (herdr 0.9.3, measured); any other herdr with no terminal is a
    ///   closed tab's ghost and still does not. The agent's pane is found
    ///   too (`herdrFunctions`) and one more line says whether herdr would
    ///   select it — `agent get`, which only reads;
    /// - otherwise the agent itself. A pane's environment is the server's
    ///   first client's, which may be long gone, so a pane never falls back
    ///   to it.
    /// From that process the parents are walked up to the connection's
    /// `sshd` — the one whose parent is the listener (`sshd`, parent 1),
    /// whatever it is called (`sshd`, or `sshd-session` from 9.8) — and its
    /// start is printed with `SSH_CONNECTION`'s ports and the script's own
    /// time. No such `sshd`, or a pane with no client attached: `none`.
    /// Not Linux (no `<proc>/self`), no record, no live process, a pane whose
    /// values do not check out or whose server cannot be asked: nothing.
    /// Every process the script runs only reads: `tmux` lists, `ss` lists,
    /// herdr lists and gets.
    ///
    /// Before the connection's line, each of `forwarded` that process has is
    /// printed, its value cut one byte past `maxForwardedValue` — so a cut
    /// one is refused by `reply`, never taken for whole — and otherwise
    /// untouched.
    /// It is the same process whose `SSH_CONNECTION` is read, so a pane's
    /// stale values never are. A name that is not `isForwardedName` never
    /// reaches the script; past `maxForwarded`, neither does the rest. The
    /// names are the caller's: this script knows no terminal.
    public static func script(sessionID: String, records: SessionRecords, nonce: String,
                              forwarded: [String] = [], proc: String = "/proc") -> String? {
        guard let prelude = prelude(sessionID: sessionID, records: records, nonce: nonce, proc: proc) else { return nil }
        let q = RemoteSettings.quoted
        let names = forwarded.filter(isForwardedName).prefix(maxForwarded).joined(separator: " ")
        return prelude + herdrFunctions + #"""
        fw=\#(q(names))
        above() {
          x=$1
          k=0
          while [ $k -lt 64 ]; do
            st "$x" || return 1
            [ "$P" = "$2" ] && return 0
            [ "$P" -gt 1 ] 2>/dev/null || return 1
            x=$P
            k=$((k + 1))
          done
          return 1
        }
        socks() {
          ls -l "$r/$1/fd" 2>/dev/null | sed -n 's/.*socket:\[\([0-9][0-9]*\)\].*/\1/p'
        }
        hbridge() {
          set -f
          set -- $(tr '\000' ' ' < "$r/$1/cmdline" 2>/dev/null)
          set +f
          [ "${1##*/}" = herdr ] || return 1
          shift
          if [ "$1" = --session ] && [ $# -ge 3 ]; then shift 2; fi
          [ "$1" = remote-client-bridge ] || return 1
          shift
          [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --idle-timeout-v1 ]; }
        }
        say() {
          x=$1
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
                  set -- $(val SSH_CONNECTION)
                  set +f
                  [ $# -eq 4 ] || exit 0
                  for fn in $fw; do
                    fv=$(val "$fn")
                    [ -z "$fv" ] || printf '%s env %s %.\#(maxForwardedValue + 1)s\n' "$n" "$fn" "$fv"
                  done
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
        }
        h=
        hs=-1
        hd=
        if printf '%s\n' "$e" | grep -q '^TMUX='; then
          v=$(val TMUX)
          w=$(val TMUX_PANE)
          v=${v%,*}
          sv=${v##*,}
          so=${v%,*}
          case $so in /*) ;; *) exit 0 ;; esac
          num "$sv" && [ "$sv" -gt 1 ] || exit 0
          case $w in %*) ;; *) exit 0 ;; esac
          num "${w#%}" && [ ${#w} -le 12 ] || exit 0
          above "$p" "$sv" || exit 0
          isexe "$sv" tmux || exit 0
          a=$($o "$r/$sv/exe" -S "$so" display-message -p -t "$w" '#{session_id}' \; \
            list-clients -F '#{client_pid} #{client_activity} #{session_id}' 2>/dev/null) || exit 0
          set -f
          set -- $a
          set +f
          case $1 in \$*) ;; *) exit 0 ;; esac
          se=$1
          shift
          while [ $# -ge 3 ]; do
            if [ "$3" = "$se" ] && num "$1" && num "$2" && [ "$1" -gt 1 ] && st "$1" && [ "$Y" != 0 ]; then
              if [ "$2" -gt "$hs" ] || { [ "$2" -eq "$hs" ] && [ "$1" -gt "$h" ]; }; then
                h=$1
                hs=$2
              fi
            fi
            shift 3
          done
        elif printf '%s\n' "$e" | grep -q '^HERDR_ENV='; then
          hserver || exit 0
          hd=1
          i=" $(socks "$sv" | tr '\n' ' ') "
          [ "$i" != "  " ] || exit 0
          ac=
          for x in $(awk '$6 == "03" && $NF ~ /(^|\/)herdr-client\.sock$/ { print $7 }' "$r/net/unix" 2>/dev/null); do
            case $i in *" $x "*) ac="$ac $x" ;; esac
          done
          if [ -n "$ac" ]; then
            command -v ss >/dev/null 2>&1 || exit 0
            pe=" $(ss -xn 2>/dev/null | awk -v want="$ac" '
              function u(x) { x += 0; if (x < 0) x += 4294967296; return sprintf("%.0f", x) }
              BEGIN { m = split(want, w, " "); for (j = 1; j <= m; j++) W[w[j]] = 1 }
              NF >= 4 { l = u($(NF - 2)); if (l in W) print u($NF) }' | tr '\n' ' ') "
            [ "$pe" != "  " ] || exit 0
            for f in $(grep -l '^[0-9][0-9]* (herdr) ' "$r"/[0-9]*/stat 2>/dev/null); do
              x=${f%/stat}
              x=${x##*/}
              [ "$x" != "$sv" ] && st "$x" && { [ "$Y" != 0 ] || hbridge "$x"; } || continue
              z=$T
              for y in $(socks "$x"); do
                case $pe in
                  *" $y "*)
                    if [ "$z" -gt "$hs" ] || { [ "$z" -eq "$hs" ] && [ "$x" -gt "$h" ]; }; then
                      h=$x
                      hs=$z
                    fi
                    break
                    ;;
                esac
              done
            done
          fi
        else
          say "$p"
        fi
        if [ -z "$h" ]; then
          printf '%s none\n' "$n"
          exit 0
        fi
        if [ -n "$hd" ]; then
          if hexe && hpane && hcall agent get "$hp" >/dev/null; then hy=on; else hy=off; fi
          printf '%s herdr %s\n' "$n" "$hy"
        fi
        e=$(tr '\000' '\n' < "$r/$h/environ" 2>/dev/null) || exit 0
        say "$h"

        """#
    }

    /// The click's script, or `nil` for an id that is not a session id: it
    /// finds the session's process as `script` does, and in a herdr pane
    /// finds that pane again — now, not as the lookup saw it, since a moved
    /// pane takes another id — and selects it with the server's own
    /// executable and socket: `agent focus`, herdr's CLI, the one command
    /// either script runs that changes anything. herdr moves every attached
    /// client to the pane. Says `<nonce> focused` once herdr took it, and
    /// nothing otherwise — not in herdr, a server that is not herdr, no
    /// pane, a pane herdr does not take as an agent's.
    public static func selectScript(sessionID: String, records: SessionRecords, nonce: String,
                                    proc: String = "/proc") -> String? {
        guard let prelude = prelude(sessionID: sessionID, records: records, nonce: nonce, proc: proc) else { return nil }
        return prelude + herdrFunctions + #"""
        printf '%s\n' "$e" | grep -q '^HERDR_ENV=' || exit 0
        hserver && hexe && hpane || exit 0
        hcall agent focus "$hp" >/dev/null || exit 0
        printf '%s focused\n' "$n"

        """#
    }

    /// Whether the select script said herdr took the pane.
    public static func selected(exitCode: Int32, output: Data, nonce: String) -> Bool {
        exitCode == 0 && String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).contains { $0 == "\(nonce) focused" }
    }

    /// Both scripts' beginning: the session's record, its live process
    /// (`p`), that process's environment (`e`), and the `stat` reader
    /// (`st`: name `C`, parent `P`, terminal `Y`, start `T`). `nil` for an
    /// id that is not a session id.
    private static func prelude(sessionID: String, records: SessionRecords, nonce: String,
                                proc: String) -> String? {
        guard isSessionID(sessionID) else { return nil }
        let q = RemoteSettings.quoted
        return #"""
        n=\#(q(nonce))
        r=\#(q(proc))
        d="$HOME"/\#(q(records.directory))
        id=\#(q(sessionID))
        ik=\#(q(records.idKey))
        pk=\#(q(records.pidKey))
        sk=\#(q(records.startedAtKey ?? ""))
        [ -d "$r/self" ] || exit 0
        st() {
          s=$(cat "$r/$1/stat" 2>/dev/null) || return 1
          C=${s#*\(}
          C=${C%\)*}
          set -f
          set -- ${s##*\) }
          set +f
          [ $# -ge 20 ] || return 1
          P=$2
          Y=$5
          shift 19
          T=$1
        }
        val() {
          printf '%s\n' "$e" | sed -n "s/^$1=//p" | head -n 1
        }
        num() {
          case $1 in ''|*[!0-9]*) return 1 ;; esac
        }
        b=$(sed -n 's/^btime //p' "$r/stat" 2>/dev/null)
        p=
        for f in "$d"/*.json; do
          [ -f "$f" ] || continue
          grep -q "\"$ik\"[[:space:]]*:[[:space:]]*\"$id\"" "$f" 2>/dev/null || continue
          x=$(sed -n "s/.*\"$pk\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -n 1)
          [ -n "$x" ] && [ -d "$r/$x" ] || continue
          m=
          [ -z "$sk" ] || m=$(sed -n "s/.*\"$sk\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -n 1)
          if num "$m" && [ ${#m} -le 15 ] && num "$b" && st "$x" && num "$T"; then
            g=$(( (b * 100 + T) / 100 - m / 1000 ))
            [ "$g" -lt 120 ] && [ "$g" -gt -120 ] || continue
          fi
          p=$x
          break
        done
        [ -n "$p" ] || exit 0
        e=$(tr '\000' '\n' < "$r/$p/environ" 2>/dev/null) || exit 0
        o=
        if command -v timeout >/dev/null 2>&1; then o='timeout 2'; fi
        isexe() {
          x=$(readlink "$r/$1/exe" 2>/dev/null) || return 1
          x=${x% (deleted)}
          [ "${x##*/}" = "$2" ]
        }

        """#
    }

    /// The herdr pane, found from the process as this Mac finds it
    /// (`Herdr.pane`), and so herdr's pane is found only as surely as it
    /// is selected — by its id, and only an agent's (`agent get`, `agent
    /// focus`: herdr's CLI focuses a pane by id no other way, and a raw
    /// socket client is not sure to be on a server). `hserver` walks from
    /// `p` to the `herdr server` above
    /// it (`sv`), keeping the last process before it (`hr`, the pane's
    /// root) and the pane's API socket (`hk`, `HERDR_SOCKET_PATH`); `hexe`
    /// takes the server's own executable (`hx`, never `PATH`); `hpane`
    /// asks it for the pane whose shell is the root, else the first whose
    /// foreground processes hold the root or the agent (`hp`), trying the
    /// agent's `HERDR_PANE_ID` first — its id at launch, stale once the pane
    /// moved; the list is asked only when that id is not the root's, and
    /// the pane it answered for is not asked again. The id
    /// kept is the one herdr answers with: it still answers `process-info`
    /// for a moved pane's old id, by alias, while `agent` takes only the
    /// current one (measured on herdr 0.9.3). Every call is cut at 2 s by
    /// `timeout`, and without one herdr is not asked: a stuck server must
    /// not cost the lookup its connection line. Past a cut call, no more
    /// are made. Only reads.
    private static let herdrFunctions = #"""
        hserver() {
          hk=$(val HERDR_SOCKET_PATH)
          case $hk in /*) ;; *) return 1 ;; esac
          sv=
          x=$p
          k=0
          while [ $k -lt 64 ]; do
            st "$x" || return 1
            [ "$P" -gt 1 ] 2>/dev/null || return 1
            hr=$x
            x=$P
            set -f
            set -- $(tr '\000' ' ' < "$r/$x/cmdline" 2>/dev/null)
            set +f
            if [ "${1##*/}" = herdr ] && [ "$2" = server ]; then sv=$x; return 0; fi
            k=$((k + 1))
          done
          return 1
        }
        hexe() {
          isexe "$sv" herdr || return 1
          hx="$r/$sv/exe"
        }
        hcall() {
          [ -n "$o" ] || return 125
          HERDR_SOCKET_PATH=$hk $o "$hx" "$@" 2>/dev/null
        }
        htry() {
          case $1 in ''|-*|*[!a-zA-Z0-9:_-]*) return 1 ;; esac
          [ ${#1} -le 64 ] || return 1
          a=$(hcall pane process-info --pane "$1")
          case $? in 0) ;; 1|2) return 1 ;; *) return 2 ;; esac
          q=$(printf '%s\n' "$a" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')
          case $q in ''|-*|*[!a-zA-Z0-9:_-]*) return 1 ;; esac
          [ ${#q} -le 64 ] || return 1
          if [ "$(printf '%s\n' "$a" | sed -n 's/.*"shell_pid":\([0-9][0-9]*\).*/\1/p')" = "$hr" ]; then
            hp=$q
            return 0
          fi
          [ -z "$hf" ] || return 1
          for y in $(printf '%s\n' "$a" | grep -o '"pid":[0-9][0-9]*' | sed 's/.*://'); do
            if [ "$y" = "$hr" ] || [ "$y" = "$p" ]; then hf=$q; break; fi
          done
          return 1
        }
        hpane() {
          hp=
          hf=
          q=
          htry "$(val HERDR_PANE_ID)"
          case $? in 0) return 0 ;; 2) return 1 ;; esac
          h0=$q
          hl=$(hcall pane list)
          case $? in 0) ;; 1|2) hl= ;; *) return 1 ;; esac
          set -f
          set -- $(printf '%s\n' "$hl" | grep -o '"pane_id":"[^"]*"' | sed 's/^"pane_id":"//; s/"$//')
          set +f
          for hv in "$@"; do
            [ "$hv" != "$h0" ] || continue
            htry "$hv"
            case $? in 0) return 0 ;; 2) return 1 ;; esac
          done
          hp=$hf
          [ -n "$hp" ]
        }

        """#

    // MARK: - The answer

    /// The process start's unit in `/proc/<pid>/stat`: Linux's `USER_HZ`,
    /// which is 100 everywhere it is exposed.
    static let ticksPerSecond = 100.0

    /// The script's lines behind whatever a login script printed first;
    /// `nil` for no line, a failed call, or a line that does not parse —
    /// all of them "not known", never a guess. `arrivedAt` is when the
    /// answer reached this Mac: the clock offset is read against it. A
    /// forwarded variable whose line does not parse is left out; the
    /// connection stands without it. So does the herdr pane's.
    public static func reply(exitCode: Int32, output: Data, nonce: String, arrivedAt: Date) -> Reply? {
        guard exitCode == 0 else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        var forwarded: [String] = []
        var herdrPane: Pane?
        var said: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix(nonce + " ") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 2, parts[1] == "herdr" {
                // A word not known is no pane: the card then promises nothing
                // it would not keep, and the click selects nothing.
                if parts.count == 3 { herdrPane = parts[2] == "on" ? .selectable : parts[2] == "off" ? .unselectable : nil }
                continue
            }
            if parts.count >= 2, parts[1] == "env" {
                if parts.count == 4, isForwardedName(String(parts[2])), !parts[3].isEmpty,
                   parts[3].utf8.count <= maxForwardedValue,
                   !parts[3].unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    forwarded.append("\(parts[2])=\(parts[3])")
                }
                continue
            }
            said.append(line)
        }
        guard said.count == 1, let line = said.first else { return nil }
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
        return .connection(Connection(clientPort: client, serverPort: server, startedAt: started, offset: offset,
                                      forwarded: forwarded, herdrPane: herdrPane))
    }
}
