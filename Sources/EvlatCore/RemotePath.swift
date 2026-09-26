import Foundation

/// Whether a server's own shell finds the `evlat` command (`RemoteCommand`),
/// and the one line that makes it: `~/.local/bin` is where the command goes
/// for every user, root too, but it is not on every login's `PATH` — Ubuntu
/// adds it in a normal user's `~/.profile` only, so root's `evlat watch`
/// said "command not found" while the row said installed (`014` ek).
///
/// Pure: script parts, read back here, and the line's plan on bytes. The
/// write is `RemoteSettings`' own (`Change.pathLine`): read, plan, a write
/// that refuses a file changed since, the first `.evlat.bak`.
public enum RemotePath {
    /// What makes the line Evlat's; removing by hand is deleting the line
    /// that ends with it.
    public static let marker = "# evlat-path"
    /// The command's folder, under `$HOME`.
    public static let directory = (RemoteCommand.commandPath as NSString).deletingLastPathComponent
    /// The whole line, as the file and the block carry it.
    public static let line = "export PATH=\"$HOME/\(directory):$PATH\"  \(marker)"
    /// How long a login shell may take to answer the read, in seconds.
    public static let patience = 8

    /// What the read found.
    public struct Status: Equatable {
        /// A new login shell's `PATH` has `~/.local/bin`; `nil` when no shell
        /// answered (no `$SHELL`, a startup file that hangs or fails).
        public let onPath: Bool?
        /// The startup file a line goes into, under `$HOME`: `.bashrc` for
        /// a bash login, `.zshrc` for zsh, `.profile` for any other.
        public let file: String
        /// `file` has Evlat's line.
        public let added: Bool

        public init(onPath: Bool?, file: String, added: Bool) {
            self.onPath = onPath
            self.file = file
            self.added = added
        }
    }

    static let files: Set<String> = [".bashrc", ".zshrc", ".profile"]

    /// `$HOME`-relative `r` from `$SHELL`'s name: the same choice in the
    /// read and in the block the user pastes.
    static let fileChoice = """
        case ${SHELL##*/} in
          bash) r=.bashrc ;;
          zsh) r=.zshrc ;;
          *) r=.profile ;;
        esac
        """

    /// `case` arms that match a `PATH` holding the folder, with or without
    /// its trailing `/`.
    static let onPathPattern = "*\":$HOME/\(directory):\"*|*\":$HOME/\(directory)/:\"*"

    // MARK: - Reading

    /// Prints `<nonce> path <1|0|-> <1|0> <file>`: whether a new login shell
    /// finds the folder on its `PATH`, whether the file has Evlat's line,
    /// and which file. Reads only; nothing is written, not even a
    /// temporary file.
    ///
    /// `ssh … sh -s` is not the shell the user types into — its `PATH` is
    /// the server's default, without what the startup files add — so the
    /// user's `$SHELL` is run as a login and interactive shell (`-lic`),
    /// stdin on `/dev/null`, stderr dropped, and asked for its `PATH`
    /// behind the nonce: what a startup file prints is not the answer. A
    /// shell that has not answered in `patience` seconds is killed with its
    /// children, and the answer is `-`. A grandchild that keeps the pipe
    /// open still holds the read until it ends — POSIX `sh` has no process
    /// group to kill.
    ///
    /// The watcher is started before any trap and keeps no stream of the
    /// read's (`AGENTS.md` → Tuzaklar: a stray `sleep` holding the caller's
    /// pipe; dash running the parent's trap in a subshell).
    static func probe(nonce: String, patience: Int) -> String {
        """
        (
        n=\(RemoteSettings.quoted(nonce))
        l=\(RemoteSettings.quoted(line))
        c=\(RemoteSettings.quoted("printf '\\n%s ipath %s\\n' '\(nonce)' \"$PATH\""))
        \(fileChoice)
        if [ -f "$HOME/$r" ] && grep -qxF -e "$l" "$HOME/$r" 2>/dev/null; then a=1; else a=0; fi
        v=
        if [ -n "${SHELL-}" ] && [ -x "$SHELL" ]; then
          o=$(
            "$SHELL" -lic "$c" </dev/null 2>/dev/null &
            p=$!
            (
              trap 'kill "$w" 2>/dev/null; exit 0' TERM
              sleep \(patience) &
              w=$!
              wait "$w"
              pkill -9 -P "$p" 2>/dev/null
              kill -9 "$p" 2>/dev/null
            ) </dev/null >/dev/null 2>&1 &
            g=$!
            wait "$p"
            kill "$g" 2>/dev/null
          )
          v=$(printf '%s\\n' "$o" | sed -n "s/^$n ipath /x/p" | sed -n '$p')
        fi
        if [ -z "$v" ]; then
          on=-
        else
          case ":${v#x}:" in
            \(onPathPattern)) on=1 ;;
            *) on=0 ;;
          esac
        fi
        printf '%s path %s %s %s\\n' "$n" "$on" "$a" "$r"
        )
        """
    }

    /// The probe's line, found behind whatever a login script printed.
    static func status(output: Data, nonce: String) -> Status? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 5, words[0] == nonce[...], words[1] == "path", files.contains(String(words[4]))
            else { continue }
            let onPath: Bool?
            switch words[2] {
            case "1": onPath = true
            case "0": onPath = false
            case "-": onPath = nil
            default: continue
            }
            switch words[3] {
            case "1": return Status(onPath: onPath, file: String(words[4]), added: true)
            case "0": return Status(onPath: onPath, file: String(words[4]), added: false)
            default: continue
            }
        }
        return nil
    }

    // MARK: - The line's plan

    /// The startup file's new bytes, or `nil` when there is nothing to
    /// write: install appends the line on a line of its own unless it is
    /// there; remove takes every line that is exactly it — a line edited by
    /// hand, or the user's own `PATH` line, stays. A file that is not text
    /// (not UTF-8, or a NUL) is `malformed` and left alone.
    public static func plan(_ action: RemoteSettings.Action, original: Data?) throws -> Data? {
        let bytes = original ?? Data()
        // The writer carries the bytes as a shell word: text only.
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else {
            throw SettingsFile.Failure.malformed
        }
        let mine = Data(line.utf8)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        let has = lines.contains { Data($0) == mine }
        switch action {
        case .install:
            guard !has else { return nil }
            var result = bytes
            if let last = result.last, last != 0x0A { result.append(0x0A) }
            return result + mine + Data([0x0A])
        case .remove:
            guard has else { return nil }
            var kept = lines.filter { Data($0) != mine }.map { Data($0) }
            // A last line without its newline: the one before keeps its own.
            if let last = lines.last, Data(last) == mine { kept.append(Data()) }
            return Data(kept.joined(separator: [0x0A]))
        }
    }

    // MARK: - The one block

    /// The block's part: run in the user's own shell on the server, so it
    /// reads that shell's `PATH` and `$SHELL`. Nothing when the `PATH`
    /// already has the folder or the file already has the line; else the
    /// automatic writer's bytes — the first `.evlat.bak`, a newline if the
    /// last line has none, the line.
    static var combinedPart: String {
        """
        case ":$PATH:" in
          \(onPathPattern)) exit 0 ;;
        esac
        \(fileChoice)
        f="$HOME/$r"
        l=\(RemoteSettings.quoted(line))
        if [ -f "$f" ] && grep -qxF -e "$l" "$f"; then exit 0; fi
        if [ -e "$f" ]; then
          if [ ! -e "$f.evlat.bak" ] && [ ! -h "$f.evlat.bak" ]; then cp -p "$f" "$f.evlat.bak" || exit 13; fi
          if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\\n' >> "$f" || exit 13; fi
        fi
        printf '%s\\n' "$l" >> "$f" || exit 13
        exit 0

        """
    }
}
