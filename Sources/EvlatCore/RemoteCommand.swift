import Foundation

/// The `evlat` command on a remote machine: `evlat watch …` and
/// `evlat signal …` on a server put a row on the bar of the Mac the server
/// was added to, through the socket the machine's channel carries there
/// (`RemoteTunnel`, `RemoteTunnels`). Pure: a string, installed by the shell
/// and pinned by `RemoteCommandScriptTests`, which run it under `sh`, `dash`
/// and `bash` against a machine's socket listener.
///
/// No key: the socket's directory is the user's alone on the server, and
/// what reaches the Mac through it is that machine's, as its hooks are.
///
/// The words, defaults and exit codes are `SignalCommand`'s — its parser is
/// the judge the tests hold the script to — and the route, header and port
/// are interpolated from their Swift owners, so the script is not a second
/// copy of the contract that could drift from it.
///
/// The script is POSIX `sh` plus `curl` and standard tools (`tr`, `sed`,
/// `ls`, `sleep`), for Linux and macOS servers alike. What a shell cannot
/// promise that `Evlat watch` does (`Watch`):
/// a shell defers a trapped signal until its foreground command
/// ends, so a `TERM` sent to the wrapper alone is not passed on.
public enum RemoteCommand {
    /// Line 2 of the script: what makes `~/.local/bin/evlat` Evlat's own, so
    /// an install never overwrites somebody else's `evlat`.
    public static let marker = "# evlat-remote-signal"
    /// Line 3 (`# version N`); raised whenever the script changes. 2: the
    /// socket, and no key.
    public static let version = 2
    /// Where version 1 kept the machine's key, under `$HOME`. Read by
    /// nothing now; an install and a removal take it away.
    public static let keyPath = ".config/evlat/signal.token"

    /// `SignalCommand.usage` as the server's command says it, and `--list`.
    public static let usage = SignalCommand.usage
        .replacingOccurrences(of: "usage: Evlat ", with: "usage: evlat ")
        .replacingOccurrences(of: "       Evlat ", with: "       evlat ")
        + """


        evlat --list says in one line whether Evlat on the Mac hears this
        machine: through the socket its ssh connection carries.
        """

    /// The whole of `~/.local/bin/evlat`.
    ///
    /// - It speaks to `$EVLAT_SOCKET`, else the socket under the home —
    ///   the installed hooks' own (`EvlatSocket.relativePath`).
    /// - `curl -q` first (no `~/.curlrc`), `--noproxy '*'`, `-m 2`, and
    ///   nothing of `curl`'s reaches the command's streams.
    /// - Every variable is `_evlat_*` and none is exported: the command's
    ///   environment is the one `evlat` was started with.
    /// - `watch` runs the command in the **foreground** — same process
    ///   group, streams and terminal untouched — because a background child
    ///   of a POSIX shell ignores Ctrl-C for good (measured under
    ///   `sh`, `dash` and `bash`).
    ///   The first `working` and the heartbeat run beside it with their
    ///   streams on `/dev/null`, so a `$(evlat watch …)` is not held open.
    public static let script = #"""
        #!/bin/sh
        \#(marker)
        # version \#(version)
        #
        # Evlat's command on this machine. `evlat watch COMMAND...` and
        # `evlat signal ID ...` put a row on the bar of the Mac this machine
        # was added to, through the socket its ssh connection carries.
        # Installed by Evlat: an edit is lost on the next install. `evlat
        # --help` for the words, `evlat --list` to see whether the Mac hears
        # this machine.

        _evlat_sock=${EVLAT_SOCKET:-$HOME/\#(EvlatSocket.relativePath)}
        _evlat_url=\#(EvlatSocket.Curl.url(SignalReport.path))
        _evlat_nl='
        '

        _evlat_usage() {
          cat <<'EVLAT_USAGE'
        \#(usage)
        EVLAT_USAGE
        }

        _evlat_fail() {
          printf 'evlat: %s\n' "$1" >&2
          _evlat_usage >&2
          exit \#(SignalCommand.usageExitCode)
        }

        # A curl that can reach a socket: present, and knows --unix-socket
        # (7.40). An option it does not know is exit 2; one it knows fails
        # to connect to a directory instead.
        _evlat_curl() {
          command -v curl >/dev/null 2>&1 || return 1
          curl -q -s -m 1 --unix-socket / -o /dev/null http://127.0.0.1/ >/dev/null 2>&1
          [ $? -ne 2 ]
        }

        # A JSON string's inside: line breaks and tabs become spaces, other
        # control bytes go, \ and " are escaped. The route cleans the rest.
        _evlat_json() {
          printf '%s' "$1" | LC_ALL=C tr '\011\012\013\014\015' '     ' \
            | LC_ALL=C tr -d '\000-\037' | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'
        }

        # _evlat_body ID TTL [PHASE LABEL DETAIL SENDER PROGRESS] -> _evlat_b
        _evlat_body() {
          _evlat_b="{\"id\":\"$1\",\"ttl\":$2"
          if [ -n "$3" ]; then _evlat_b="$_evlat_b,\"phase\":\"$3\""; fi
          if [ -n "$4" ]; then _evlat_b="$_evlat_b,\"label\":\"$(_evlat_json "$4")\""; fi
          if [ -n "$5" ]; then _evlat_b="$_evlat_b,\"detail\":\"$(_evlat_json "$5")\""; fi
          if [ -n "$6" ]; then _evlat_b="$_evlat_b,\"sender\":\"$(_evlat_json "$6")\""; fi
          if [ -n "$7" ]; then _evlat_b="$_evlat_b,\"progress\":$7"; fi
          _evlat_b="$_evlat_b}"
        }

        # One POST, nothing kept. The caller silences the streams.
        _evlat_send() {
          curl -q -s -m 2 --noproxy '*' --unix-socket "$_evlat_sock" -o /dev/null \
            -H 'Content-Type: application/json' --data-binary "$1" "$_evlat_url"
        }

        # One POST whose answer is read: the body, a line break, the status
        # (000 when nothing answered).
        _evlat_ask() {
          curl -q -s -m 2 --noproxy '*' --unix-socket "$_evlat_sock" -w '\n%{http_code}' \
            -H 'Content-Type: application/json' --data-binary "$1" "$_evlat_url" 2>/dev/null
        }

        # 0...1 as JSON, or failure: 0, 1, .5, 0.25, +1.0.
        _evlat_fraction() {
          _evlat_f=${1#+}
          case $_evlat_f in
            ''|.|*[!0123456789.]*|*.*.*) return 1 ;;
          esac
          _evlat_i=${_evlat_f%%.*}
          case $_evlat_f in
            *.*) _evlat_d=${_evlat_f#*.} ;;
            *) _evlat_d= ;;
          esac
          _evlat_i=${_evlat_i:-0}
          _evlat_d=${_evlat_d:-0}
          while :; do
            case $_evlat_i in
              0?*) _evlat_i=${_evlat_i#0} ;;
              *) break ;;
            esac
          done
          case $_evlat_i in
            0) ;;
            1) case $_evlat_d in *[!0]*) return 1 ;; esac ;;
            *) return 1 ;;
          esac
          printf '%s.%s\n' "$_evlat_i" "$_evlat_d"
        }

        # Whole seconds 0...\#(SignalReport.ttlLimit) as JSON, or failure.
        _evlat_seconds() {
          _evlat_t=${1#+}
          case $_evlat_t in
            ''|*[!0123456789]*) return 1 ;;
          esac
          while :; do
            case $_evlat_t in
              0?*) _evlat_t=${_evlat_t#0} ;;
              *) break ;;
            esac
          done
          [ ${#_evlat_t} -le 5 ] && [ "$_evlat_t" -le \#(SignalReport.ttlLimit) ] || return 1
          printf '%s\n' "$_evlat_t"
        }

        _evlat_is_id() {
          case $1 in
            ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;;
          esac
          [ ${#1} -le \#(SignalReport.idLimit) ]
        }

        # The folder as a prompt says it: ~ for the home.
        _evlat_folder() {
          _evlat_dir=${PWD:-$(pwd)}
          _evlat_home=$HOME
          case $_evlat_home in
            ?*/) _evlat_home=${_evlat_home%/} ;;
          esac
          if [ -z "$_evlat_home" ] || [ "$_evlat_home" = / ]; then
            _evlat_where=$_evlat_dir
          elif [ "$_evlat_dir" = "$_evlat_home" ]; then
            _evlat_where='~'
          else
            case $_evlat_dir in
              "$_evlat_home"/*) _evlat_where="~${_evlat_dir#"$_evlat_home"}" ;;
              *) _evlat_where=$_evlat_dir ;;
            esac
          fi
        }

        # The heartbeat, in the background: `working` again every minute
        # while the wrapper lives. TERM (the wrapper's, when the command is
        # done) takes its sleep with it.
        _evlat_beat() {
          _evlat_s=
          trap '[ -n "$_evlat_s" ] && kill "$_evlat_s" 2>/dev/null; exit 0' TERM HUP
          while :; do
            sleep \#(Int(SignalCommand.heartbeat)) &
            _evlat_s=$!
            wait "$_evlat_s"
            _evlat_s=
            kill -0 $$ 2>/dev/null || exit 0
            _evlat_send "$_evlat_running"
          done
        }

        _evlat_watch() {
          _evlat_label=
          _evlat_has_label=
          _evlat_sender=
          while [ $# -gt 0 ]; do
            case $1 in
              --) shift; break ;;
              -h|--help) _evlat_usage; exit 0 ;;
              --label|--sender)
                [ $# -ge 2 ] || _evlat_fail "$1 needs a value"
                if [ "$1" = --label ]; then _evlat_label=$2; _evlat_has_label=1; else _evlat_sender=$2; fi
                shift 2 ;;
              -*) _evlat_fail "unknown flag $1 (use -- before a command that starts with -)" ;;
              *) break ;;
            esac
          done
          [ $# -gt 0 ] && [ -n "$1" ] || _evlat_fail "no command to watch"

          # Nobody to tell, or no such command: the command as it is.
          [ -S "$_evlat_sock" ] && command -v curl >/dev/null 2>&1 || exec "$@"
          command -v "$1" >/dev/null 2>&1 || exec "$@"

          if [ -z "$_evlat_has_label" ]; then
            for _evlat_w in "$@"; do
              _evlat_label=$_evlat_label${_evlat_label:+ }$_evlat_w
              [ ${#_evlat_label} -gt 1024 ] && break
            done
          fi
          [ -n "$_evlat_sender" ] || _evlat_sender=${1##*/}
          _evlat_folder
          _evlat_id=watch-$$
          _evlat_body "$_evlat_id" \#(SignalCommand.watchTTL) working "$_evlat_label" "$_evlat_where" "$_evlat_sender"
          _evlat_running=$_evlat_b

          # Started before the traps below: dash lets a subshell run the
          # parent's trap until it sets its own, and the heartbeat's TERM
          # would only note a signal and keep beating.
          _evlat_send "$_evlat_running" </dev/null >/dev/null 2>&1 &
          _evlat_first=$!
          _evlat_beat </dev/null >/dev/null 2>&1 &
          _evlat_beating=$!

          # Noted, not passed on: a terminal's signal reaches the command
          # itself, and the shell runs these once the command is done.
          _evlat_caught=
          _evlat_number=
          trap '_evlat_caught=INT _evlat_number=2' INT
          trap '_evlat_caught=TERM _evlat_number=15' TERM
          trap '_evlat_caught=HUP _evlat_number=1' HUP
          trap '_evlat_caught=QUIT _evlat_number=3' QUIT

          "$@"
          _evlat_code=$?

          kill "$_evlat_beating" 2>/dev/null
          wait "$_evlat_beating" 2>/dev/null
          wait "$_evlat_first" 2>/dev/null
          if [ "$_evlat_code" -eq 0 ]; then
            _evlat_body "$_evlat_id" \#(SignalCommand.finishedTTL) done "$_evlat_label" "$_evlat_where" "$_evlat_sender"
          elif [ -n "$_evlat_number" ] && [ "$_evlat_code" -eq $((128 + _evlat_number)) ]; then
            _evlat_body "$_evlat_id" \#(SignalCommand.finishedTTL) failed "$_evlat_label" "signal $_evlat_number · $_evlat_where" "$_evlat_sender"
          else
            _evlat_body "$_evlat_id" \#(SignalCommand.finishedTTL) failed "$_evlat_label" "exit $_evlat_code · $_evlat_where" "$_evlat_sender"
          fi
          _evlat_send "$_evlat_b" </dev/null >/dev/null 2>&1

          # The command's end is the wrapper's: a Ctrl-C that killed the
          # command kills the wrapper with it (a loop around it stops); a
          # TERM or HUP sent to the wrapper is obeyed once the command is
          # done; QUIT's own death would dump core, its code says it.
          case $_evlat_caught in
            INT) if [ "$_evlat_code" -eq 130 ]; then trap - INT; kill -s INT $$; fi ;;
            TERM|HUP) trap - "$_evlat_caught"; kill -s "$_evlat_caught" $$ ;;
          esac
          exit "$_evlat_code"
        }

        _evlat_signal() {
          _evlat_id=
          _evlat_word=
          _evlat_clear=
          _evlat_ttl=
          _evlat_label=
          _evlat_detail=
          _evlat_sender=
          _evlat_given=
          _evlat_progress=
          _evlat_ended=
          while [ $# -gt 0 ]; do
            if [ -n "$_evlat_ended" ]; then _evlat_a=; else _evlat_a=$1; fi
            case $_evlat_a in
              --) _evlat_ended=1 ;;
              -h|--help) _evlat_usage; exit 0 ;;
              --waiting|--done|--failed|--clear)
                [ -z "$_evlat_word$_evlat_clear" ] || _evlat_fail "one of --waiting, --done, --failed, --clear"
                case $1 in
                  --clear) _evlat_clear=1 ;;
                  *) _evlat_word=${1#--} ;;
                esac ;;
              --label|--detail|--sender)
                [ $# -ge 2 ] || _evlat_fail "$1 needs a value"
                case $1 in
                  --label) _evlat_label=$2 ;;
                  --detail) _evlat_detail=$2 ;;
                  *) _evlat_sender=$2 ;;
                esac
                _evlat_given=1
                shift ;;
              --progress)
                [ $# -ge 2 ] || _evlat_fail "$1 needs a value"
                _evlat_progress=$(_evlat_fraction "$2") || _evlat_fail "--progress must be a number from 0 to 1"
                shift ;;
              --ttl)
                [ $# -ge 2 ] || _evlat_fail "$1 needs a value"
                _evlat_ttl=$(_evlat_seconds "$2") || _evlat_fail "--ttl must be whole seconds from 0 to \#(SignalReport.ttlLimit)"
                shift ;;
              *)
                if [ -z "$_evlat_ended" ]; then
                  case $1 in
                    -*) _evlat_fail "unknown flag $1 (use -- before an id that starts with -)" ;;
                  esac
                fi
                [ -z "$_evlat_id" ] || _evlat_fail "one id only (got $_evlat_id and $1)"
                _evlat_is_id "$1" || _evlat_fail "id must match [A-Za-z0-9._-]{1,\#(SignalReport.idLimit)}"
                _evlat_id=$1 ;;
            esac
            shift
          done
          [ -n "$_evlat_id" ] || _evlat_fail "no id"
          if [ -n "$_evlat_clear" ]; then
            [ -z "$_evlat_given$_evlat_progress$_evlat_ttl" ] || _evlat_fail "--clear takes no other flag"
            _evlat_body "$_evlat_id" 0
          else
            _evlat_word=${_evlat_word:-working}
            if [ -z "$_evlat_ttl" ]; then
              case $_evlat_word in
                done|failed) _evlat_ttl=\#(SignalCommand.finishedTTL) ;;
                *) _evlat_ttl=\#(SignalCommand.liveTTL) ;;
              esac
            fi
            _evlat_body "$_evlat_id" "$_evlat_ttl" "$_evlat_word" "$_evlat_label" "$_evlat_detail" "$_evlat_sender" "$_evlat_progress"
          fi

          # Nobody to tell is not a mistake; a refusal is the sender's.
          command -v curl >/dev/null 2>&1 || exit 0
          _evlat_answer=$(_evlat_ask "$_evlat_b" </dev/null)
          _evlat_status=${_evlat_answer##*"$_evlat_nl"}
          case $_evlat_status in
            200|000|'') exit 0 ;;
          esac
          printf 'evlat: signal %s refused (%s)\n' "$_evlat_id" "$(_evlat_reason "${_evlat_answer%"$_evlat_nl"*}")" >&2
          exit 1
        }

        # `403 forbidden: …` from the route's error body, printable ASCII only.
        _evlat_reason() {
          _evlat_r=$_evlat_status
          _evlat_c=$(printf '%s' "$1" | LC_ALL=C sed -n 's/.*"code":"\([A-Za-z0-9_]*\)".*/\1/p')
          _evlat_m=$(printf '%s' "$1" | LC_ALL=C sed -n 's/.*"message":"\([^"\\]*\)".*/\1/p' | LC_ALL=C tr -cd ' -~')
          if [ -n "$_evlat_c" ]; then _evlat_r="$_evlat_r $_evlat_c${_evlat_m:+: $_evlat_m}"; fi
          printf '%s' "$_evlat_r"
        }

        # One line: does the Mac hear this machine? A removal of a row
        # nobody has is the probe.
        _evlat_list() {
          _evlat_about="evlat \#(version), $_evlat_sock"
          if ! command -v curl >/dev/null 2>&1; then
            printf 'no curl - evlat sends with curl; install it (%s)\n' "$_evlat_about"
            exit 1
          fi
          if ! _evlat_curl; then
            printf 'curl too old - it cannot reach a socket (--unix-socket, curl 7.40); update it (%s)\n' "$_evlat_about"
            exit 1
          fi
          if [ ! -S "$_evlat_sock" ]; then
            printf 'no socket - is Evlat running on the Mac with this machine connected? (%s)\n' "$_evlat_about"
            exit 1
          fi
          _evlat_body evlat-list 0
          _evlat_answer=$(_evlat_ask "$_evlat_b" </dev/null)
          _evlat_status=${_evlat_answer##*"$_evlat_nl"}
          case $_evlat_status in
            200) printf 'ok (%s)\n' "$_evlat_about"; exit 0 ;;
            404) printf 'no route (404) - Evlat on the Mac is older: update it (%s)\n' "$_evlat_about" ;;
            000|'') printf 'no answer - the socket is left from an earlier connection; Evlat on the Mac takes it back when it connects (%s)\n' "$_evlat_about" ;;
            *) printf 'unexpected answer (%s) (%s)\n' "$_evlat_status" "$_evlat_about" ;;
          esac
          exit 1
        }

        case ${1-} in
          watch) shift; _evlat_watch "$@" ;;
          signal) shift; _evlat_signal "$@" ;;
          --list) _evlat_list ;;
          -h|--help) _evlat_usage; exit 0 ;;
          *)
            if [ $# -eq 0 ]; then _evlat_fail "no subcommand"; fi
            _evlat_fail "unknown subcommand $1" ;;
        esac

        """#
}

// MARK: - Installing over ssh

/// The install and removal as `RemoteSettings`' writers do theirs: pure
/// scripts, run by the shell (`RemoteInstaller`, `ssh -- HOST sh -s`, the
/// script on stdin) and read back here. One call each: a file that is
/// Evlat's own needs no read-then-write.
///
/// The command travels as a single-quoted word inside the script, never in
/// an argv.
extension RemoteCommand {
    /// What a finished install or removal found. A removal's `curl` is `true`.
    public struct Report: Equatable {
        /// Install: the command was written (`false`: it was current).
        /// Removal: something was removed.
        public let wrote: Bool
        /// A `curl` that reaches a socket is on the server's `PATH`
        /// (`--unix-socket`, 7.40): the command sends nothing without it.
        public let curl: Bool

        public init(wrote: Bool, curl: Bool) {
            self.wrote = wrote
            self.curl = curl
        }
    }

    public enum Failure: Error, Equatable {
        /// `~/.local/bin/evlat` is somebody else's (no marker on line 2, or a
        /// link): left as it is. An install writes nothing; a removal still
        /// takes version 1's key, whose path is Evlat's.
        case foreign
        /// A folder or file could not be written on the server.
        case unwritable
        /// `ssh` could not run the script: its own 255, any exit the scripts
        /// never use, or no answer line.
        case unreachable
    }

    /// The scripts' own exit codes; 0 is success, nothing else is used.
    static let foreignExit: Int32 = 10
    static let unwritableExit: Int32 = 13

    /// The manual block's heredoc delimiter: no line of `script` may be it.
    public static let delimiter = "EVLAT"

    /// Where the command goes, under `$HOME`.
    public static let commandPath = ".local/bin/evlat"

    /// Writes `~/.local/bin/evlat` unless it is current, and takes version
    /// 1's key away: nothing reads it, and a secret left on a server is one
    /// too many.
    ///
    /// `~/.local/bin` is made under the server's own umask (it is the user's
    /// folder, and the manual block makes it the same way). The command is
    /// written next to its target and moved over it, so a half-written file
    /// is never the command.
    public static func installScript(nonce: String) -> String {
        """
        n=\(RemoteSettings.quoted(nonce))
        \(paths)
        mkdir -p "$b" || exit \(unwritableExit)
        \(foreignCheck)
        s=\(RemoteSettings.quoted(script))
        tmp=
        trap 'rm -f ${tmp:+"$tmp"}' EXIT
        w=0
        if [ ! -f "$e" ] || [ "$(cat "$e" && echo .)" != "$s." ]; then
          tmp=$b/.evlat.$$.tmp
          printf '%s' "$s" > "$tmp" || exit \(unwritableExit)
          chmod 755 "$tmp" || exit \(unwritableExit)
          mv -f "$tmp" "$e" || exit \(unwritableExit)
          tmp=
          w=1
        fi
        chmod 755 "$e" || exit \(unwritableExit)
        if [ -e "$t" ] || [ -h "$t" ]; then rm -f "$t" || exit \(unwritableExit); fi
        \(curlCheck)
        printf '%s %s %s\\n' "$n" "$w" "$u"
        exit 0

        """
    }

    /// Takes the command if it is Evlat's, version 1's key, and the key's
    /// folder if that leaves it empty. `~/.local/bin` stays: it is not
    /// Evlat's.
    public static func removeScript(nonce: String) -> String {
        """
        n=\(RemoteSettings.quoted(nonce))
        \(paths)
        r=0
        f=0
        if [ -e "$e" ] || [ -h "$e" ]; then
          if [ ! -h "$e" ] && [ -f "$e" ] && [ "$(sed -n 2p "$e" 2>/dev/null)" = \(RemoteSettings.quoted(marker)) ]; then
            rm -f "$e" || exit \(unwritableExit)
            r=1
          else
            f=1
          fi
        fi
        if [ -e "$t" ] || [ -h "$t" ]; then
          rm -f "$t" || exit \(unwritableExit)
          r=1
        fi
        if [ -d "$d" ] && [ ! -h "$d" ]; then rmdir "$d" 2>/dev/null; fi
        [ "$f" = 0 ] || exit \(foreignExit)
        printf '%s %s 1\\n' "$n" "$r"
        exit 0

        """
    }

    /// The script's answer: its exit code, then `<nonce> <wrote> <curl>` on
    /// a line of its own, found behind whatever a login script printed first.
    public static func result(exitCode: Int32, output: Data, nonce: String) -> Result<Report, Failure> {
        switch exitCode {
        case 0: break
        case foreignExit: return .failure(.foreign)
        case unwritableExit: return .failure(.unwritable)
        default: return .failure(.unreachable)
        }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 3, words[0] == nonce[...],
                  let wrote = flag(words[1]), let curl = flag(words[2]) else { continue }
            return .success(Report(wrote: wrote, curl: curl))
        }
        return .failure(.unreachable)
    }

    private static func flag(_ word: Substring) -> Bool? {
        switch word {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    // MARK: - Reading

    /// The command on a server as a read found it (`RemoteSettings.readingScript`).
    public enum Status: Equatable {
        case missing
        /// A link, or a file without the marker on line 2: never written over.
        case foreign
        /// Evlat's: line 3's version (`nil` when it is not one).
        case installed(version: Int?)

        /// Today's version or a later one: a newer Evlat on another Mac
        /// installed it, and this one does not call it old.
        public var isCurrent: Bool {
            guard case .installed(let version?) = self else { return false }
            return version >= RemoteCommand.version
        }
    }

    /// Prints `<nonce> command <key 1|0> missing|foreign|ours <version|->`.
    /// Reads only: `sed` on the command's lines 2 and 3. The key's word is
    /// version 1's file, still said so the line keeps its shape.
    static func statusProbe(nonce: String) -> String {
        """
        (
        n=\(RemoteSettings.quoted(nonce))
        \(paths)
        v=-
        if [ -h "$e" ]; then c=foreign
        elif [ ! -e "$e" ]; then c=missing
        elif [ -f "$e" ] && [ "$(sed -n 2p "$e" 2>/dev/null)" = \(RemoteSettings.quoted(marker)) ]; then
          c=ours
          l=$(sed -n 3p "$e" 2>/dev/null)
          case $l in
            '# version '*) v=${l#'# version '} ;;
          esac
          case $v in
            ''|*[!0123456789]*) v=- ;;
          esac
        else c=foreign
        fi
        if [ -f "$t" ] && [ -r "$t" ] && [ -s "$t" ]; then k=1; else k=0; fi
        printf '%s command %s %s %s\\n' "$n" "$k" "$c" "$v"
        )
        """
    }

    /// The probe's line, found behind whatever a login script printed.
    static func status(output: Data, nonce: String) -> Status? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 5, words[0] == nonce[...], words[1] == "command",
                  flag(words[2]) != nil else { continue }
            switch words[3] {
            case "missing": return .missing
            case "foreign": return .foreign
            case "ours": return .installed(version: Int(words[4]))
            default: continue
            }
        }
        return nil
    }

    /// `b`/`e`: the command's folder and file; `d`/`t`: the key's.
    private static var paths: String {
        let folder = (commandPath as NSString).deletingLastPathComponent
        let keyFolder = (keyPath as NSString).deletingLastPathComponent
        return """
        b="$HOME"/\(RemoteSettings.quoted(folder))
        e="$HOME"/\(RemoteSettings.quoted(commandPath))
        d="$HOME"/\(RemoteSettings.quoted(keyFolder))
        t="$HOME"/\(RemoteSettings.quoted(keyPath))
        """
    }

    /// `u`: 1 when a `curl` that reaches a socket is on the `PATH`
    /// (`--unix-socket`, 7.40) — one that does not know the option exits 2
    /// before connecting anywhere — else 0.
    static var curlCheck: String {
        """
        u=0
        if command -v curl >/dev/null 2>&1; then
          curl -q -s -m 1 --unix-socket / -o /dev/null http://127.0.0.1/ >/dev/null 2>&1
          [ $? -eq 2 ] || u=1
        fi
        """
    }

    /// Somebody else's `evlat` stops the install before anything is written:
    /// a link (even to this script) or a file without the marker on line 2.
    private static var foreignCheck: String {
        """
        if [ -h "$e" ]; then exit \(foreignExit); fi
        if [ -e "$e" ]; then
          [ -f "$e" ] && [ "$(sed -n 2p "$e" 2>/dev/null)" = \(RemoteSettings.quoted(marker)) ] || exit \(foreignExit)
        fi
        """
    }

    // MARK: - By hand

    /// What a user pastes into the server's shell instead: two blocks that
    /// leave the automatic install's files — the command byte for byte,
    /// version 1's key gone — and the way back. The sentences around them
    /// are the catalog's.
    public struct Manual: Equatable {
        /// `~/.local/bin/evlat`: the script in a quoted heredoc (nothing in
        /// it is expanded), then `chmod 755`; version 1's key removed.
        public let script: String
        /// The command if it carries the marker, version 1's key, and its
        /// folder when that leaves it empty.
        public let remove: String
    }

    public static func manual() -> Manual {
        let keyFolder = "~/" + (keyPath as NSString).deletingLastPathComponent
        let bin = "~/" + (commandPath as NSString).deletingLastPathComponent
        return Manual(
            script: "mkdir -p \(bin) && cat > ~/\(commandPath) <<'\(delimiter)' && chmod 755 ~/\(commandPath)"
                + " && rm -f ~/\(keyPath)\n"
                + script + delimiter + "\n",
            remove: "grep -qx \(RemoteSettings.quoted(marker)) ~/\(commandPath) 2>/dev/null && rm -f ~/\(commandPath); "
                + "rm -f ~/\(keyPath); rmdir \(keyFolder) 2>/dev/null; true\n")
    }
}
