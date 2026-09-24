import Foundation

/// The settings writers, over `ssh`: a server's `~/.claude/settings.json` and
/// `~/.codex/hooks.json` change the way this Mac's do (`SettingsFile`), with
/// the same guarantees — a missing directory is not created, an unchanged
/// file is not written, the first backup is kept, a file that changed since
/// it was read is left alone, a modified wrapper is not taken apart.
///
/// Pure: this type only writes shell scripts and reads what they printed.
/// Running them (`ssh -- HOST sh -s`, the script on stdin) is the shell's
/// (`RemoteInstaller`). One change is two calls:
///
/// 1. `readScript` prints the file's bytes and its POSIX `cksum`.
/// 2. `plan` transforms the bytes here, with the local writers' own
///    transformations and encoder; `nil` means nothing to write.
/// 3. `writeScript` carries the new bytes and the `cksum` from step 1; the
///    server refuses the write if its file no longer has that `cksum`.
///
/// The scripts use POSIX `sh` and tools only (`cksum`, `cp -p`, `mv -f`,
/// `readlink` or `ls`), and build every path from the server's `$HOME`; this
/// Mac's home never enters them.
public enum RemoteSettings {
    /// A remote change fails as a local one does, or before it gets there.
    public enum Failure: Error, Equatable {
        case file(SettingsFile.Failure)
        /// `ssh` could not run the script: its own 255, or any exit the
        /// scripts never use (no `sh`, a broken pipe, a signal).
        case unreachable
    }

    /// What is installed or removed; each lives in one file.
    public enum Change: Hashable {
        case hooks(AgentSource)
        case statusLine

        /// The file, relative to the server's `$HOME`.
        public var path: String {
            switch self {
            case .hooks(let source): return source.settingsPath
            case .statusLine: return AgentSource.claude.settingsPath
            }
        }
    }

    public enum Action: Equatable { case install, remove }

    /// The same options as the tunnel's where they apply: never a prompt,
    /// never someone else's master connection, and none of the host's
    /// configured forwards — one of them could be the tunnel's own port —
    /// and the tunnel's three config overrides (`RemoteTunnel.arguments`):
    /// no configured `RemoteCommand`, empty stdin or fork — the script *is*
    /// stdin.
    public static func arguments(target: String) -> [String] {
        ["-T",
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3",
         "-o", "ControlMaster=no",
         "-o", "ControlPath=none",
         "-o", "ClearAllForwardings=yes",
         "-o", "RemoteCommand=none",
         "-o", "StdinNull=no",
         "-o", "ForkAfterAuthentication=no",
         "--", target, "sh -s"]
    }

    // MARK: - Exit codes

    /// The scripts' own codes. 0 is success; nothing else is used, so a code
    /// outside this table did not come from them.
    static let exitCodes: [Int32: SettingsFile.Failure] = [
        10: .noDirectory,
        11: .unreadable,
        12: .changedUnderneath,
        13: .unwritable,
    ]

    static func code(_ failure: SettingsFile.Failure) -> Int32 {
        exitCodes.first { $0.value == failure }!.key
    }

    /// `nil` for success.
    public static func failure(exitCode: Int32) -> Failure? {
        if exitCode == 0 { return nil }
        if let failure = exitCodes[exitCode] { return .file(failure) }
        return .unreachable
    }

    // MARK: - Read

    /// The file as the server has it: `bytes` is `nil` when it does not exist.
    public struct Snapshot: Equatable {
        public let bytes: Data?
        /// `cksum`'s line for the bytes, or `absent`; handed back to the write
        /// untouched, never computed here.
        public let checksum: String
    }

    /// Prints `<nonce> <cksum>` on a line of its own, then the bytes. The
    /// nonce finds that line behind whatever a login script printed first.
    public static func readScript(path: String, nonce: String) -> String {
        """
        n=\(quoted(nonce))
        \(prelude(path: path))
        s=$(sum) || exit \(code(.unreadable))
        printf '%s %s\\n' "$n" "$s"
        if [ -e "$t" ]; then cat "$t" || exit \(code(.unreadable)); fi
        exit 0

        """
    }

    public static func snapshot(exitCode: Int32, output: Data, nonce: String) throws -> Snapshot {
        if let failure = failure(exitCode: exitCode) { throw failure }
        let mark = Data((nonce + " ").utf8)
        var start = output.startIndex
        // The nonce's line starts the output or follows a newline.
        while let found = output.range(of: mark, in: start..<output.endIndex) {
            if found.lowerBound == output.startIndex || output[output.index(before: found.lowerBound)] == 0x0A,
               let end = output[found.upperBound...].firstIndex(of: 0x0A) {
                let checksum = String(decoding: output[found.upperBound..<end], as: UTF8.self)
                let bytes = Data(output[output.index(after: end)...])
                return Snapshot(bytes: checksum == absent ? nil : bytes, checksum: checksum)
            }
            start = found.upperBound
        }
        throw Failure.file(.unreadable)
    }

    // MARK: - Plan

    /// What the write carries. `backup` is the statusLine install's own
    /// backup, written in the same call.
    public struct Write: Equatable {
        public let contents: Data
        public let backup: Data?
    }

    /// Parse → transform → `nil` if nothing changed → encode, exactly as
    /// `SettingsFile.apply` does before it writes.
    public static func plan(original: Data?, _ transform: ([String: Any]) -> [String: Any]) throws -> Data? {
        let settings = try SettingsFile.parse(original)
        let changed = transform(settings)
        if NSDictionary(dictionary: changed).isEqual(to: settings) { return nil }
        return try SettingsFile.encode(changed)
    }

    /// The local writers' `install`/`remove`, on bytes. A refusal is
    /// `malformed`, decided here from the bytes just read, as the local
    /// writers decide it from the file.
    public static func plan(_ change: Change, _ action: Action, original: Data?) throws -> Write? {
        do {
            let settings = try SettingsFile.parse(original)
            switch (change, action) {
            case (.hooks(let source), .install):
                guard let data = try plan(original: original, { HookSettings.installing(into: $0, for: source) })
                else {
                    if HookSettings.state(of: settings, for: source) != .current { throw SettingsFile.Failure.malformed }
                    return nil
                }
                return Write(contents: data, backup: nil)
            case (.hooks(let source), .remove):
                return try plan(original: original, { HookSettings.removing(from: $0, for: source) })
                    .map { Write(contents: $0, backup: nil) }
            case (.statusLine, .install):
                guard let data = try plan(original: original, { StatusLineRelay.installing(into: $0) ?? $0 }) else {
                    if StatusLineRelay.state(of: settings) != .current { throw SettingsFile.Failure.malformed }
                    return nil
                }
                return Write(contents: data, backup: try StatusLineRelay.backupContents(of: settings))
            case (.statusLine, .remove):
                guard let data = try plan(original: original, { StatusLineRelay.removing(from: $0) ?? $0 }) else {
                    if StatusLineRelay.state(of: settings) == .modified { throw SettingsFile.Failure.malformed }
                    return nil
                }
                return Write(contents: data, backup: nil)
            }
        } catch let failure as SettingsFile.Failure {
            throw Failure.file(failure)
        }
    }

    // MARK: - Write

    /// `SettingsFile.apply`'s order on the server: check → first backup →
    /// temporary file → check again → the writer's backup → `mv`. The check is
    /// the file's `cksum` against `expected`, the read's own line.
    ///
    /// The temporary file sits next to the target and starts as a `cp -p` of
    /// it, so the file keeps its mode; a file that did not exist is created
    /// under the server's umask, as the local atomic write does. The target
    /// is the link's end, so a link stays a link. The contents travel as
    /// single-quoted words, never a heredoc: a heredoc adds a newline the
    /// local writer does not write.
    public static func writeScript(path: String, expected: String, write: Write) -> String {
        let unwritable = code(.unwritable)
        var script = """
        e=\(quoted(expected))
        c=\(quoted(String(decoding: write.contents, as: UTF8.self)))
        \(prelude(path: path))
        s=$(sum) || exit \(code(.unreadable))
        [ "$s" = "$e" ] || exit \(code(.changedUnderneath))
        tmp=${t%/*}/.${t##*/}.evlat.$$.tmp
        btmp=
        trap 'rm -f "$tmp" ${btmp:+"$btmp"}' EXIT
        if [ -e "$t" ]; then
          if [ ! -e "$f.evlat.bak" ] && [ ! -h "$f.evlat.bak" ]; then cp -p "$t" "$f.evlat.bak" || exit \(unwritable); fi
          cp -p "$t" "$tmp" || exit \(unwritable)
        else
          : > "$tmp" || exit \(unwritable)
        fi
        printf '%s' "$c" > "$tmp" || exit \(unwritable)
        s=$(sum) || exit \(code(.unreadable))
        [ "$s" = "$e" ] || exit \(code(.changedUnderneath))

        """
        if let backup = write.backup {
            script += """
            b=\(quoted(String(decoding: backup, as: UTF8.self)))
            bak=$f.\(StatusLineRelay.backupExtension)
            if [ -d "$bak" ] && [ ! -h "$bak" ]; then exit \(unwritable); fi
            btmp=${f%/*}/.${f##*/}.statusline.evlat.$$.tmp
            if [ -e "$t" ]; then cp -p "$t" "$btmp" || exit \(unwritable); else (umask 077 && : > "$btmp") || exit \(unwritable); fi
            printf '%s' "$b" > "$btmp" || exit \(unwritable)
            mv -f "$btmp" "$bak" || exit \(unwritable)

            """
        }
        script += """
        mv -f "$tmp" "$t" || exit \(unwritable)
        exit 0

        """
        return script
    }

    // MARK: - Script parts

    static let absent = "absent"

    /// `f`: the path the user knows. `t`: where its links end — a link whose
    /// end is missing is refused, as `SettingsFile.resolve` refuses it.
    /// `sum`: the target's `cksum` line, `absent`, or failure.
    private static func prelude(path: String) -> String {
        let unreadable = code(.unreadable)
        return """
        f="$HOME"/\(quoted(path))
        [ -d "${f%/*}" ] || exit \(code(.noDirectory))
        link() {
          readlink "$1" 2>/dev/null && return 0
          l=$(ls -ld "$1") || return 1
          printf '%s\\n' "${l#* -> }"
        }
        t=$f
        i=0
        while [ -h "$t" ]; do
          i=$((i + 1))
          [ "$i" -le 40 ] || exit \(unreadable)
          l=$(link "$t") || exit \(unreadable)
          case $l in
            /*) t=$l ;;
            *) t=${t%/*}/$l ;;
          esac
        done
        if [ "$i" -gt 0 ] && [ ! -e "$t" ]; then exit \(unreadable); fi
        sum() {
          if [ -e "$t" ]; then
            [ -f "$t" ] && [ -r "$t" ] || return 1
            cksum < "$t"
          else
            echo \(absent)
          fi
        }
        """
    }

    /// A single-quoted shell word: each `'` closes, is escaped and reopens.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - By hand

    /// What a user pastes into a server's files instead: the blocks the
    /// writers would write into an empty file, in the same bytes. The
    /// sentences around them are the catalog's.
    public struct Manual: Equatable {
        /// Stands for the user's own statusLine command in `wrapping`.
        public static let placeholder = "YOUR-STATUSLINE-COMMAND"

        /// `~/.claude/settings.json`'s `hooks`, as a whole file's JSON.
        public let claudeHooks: String
        /// `~/.codex/hooks.json`, as a whole file's JSON.
        public let codexHooks: String
        /// The `statusLine` for a file that has none.
        public let statusLine: String
        /// The wrapper around an existing command, `placeholder` in its place.
        public let wrapping: String
        /// Every command Evlat writes contains this; removing by hand is
        /// taking out the entries that do.
        public let marker: String
    }

    public static var manual: Manual {
        func text(_ settings: [String: Any]) -> String {
            // The empty object always encodes; `[:]` never reaches this.
            String(decoding: (try? SettingsFile.encode(settings)) ?? Data(), as: UTF8.self)
        }
        return Manual(
            claudeHooks: text(HookSettings.installing(into: [:], for: .claude)),
            codexHooks: text(HookSettings.installing(into: [:], for: .codex)),
            statusLine: text(StatusLineRelay.installing(into: [:]) ?? [:]),
            wrapping: StatusLineRelay.command(wrapping: Manual.placeholder),
            marker: "127.0.0.1:\(LocalAPI.defaultPort)")
    }
}
