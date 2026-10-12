import Foundation

/// The settings writers, over `ssh`: a server's `~/.claude/settings.json` and
/// `~/.codex/hooks.json` change the way this Mac's do (`SettingsFile`), with
/// the same guarantees — a missing directory is not created, an unchanged
/// file is not written, the first backup is kept, a file that changed since
/// it was read is left alone, a modified wrapper is not taken apart.
///
/// An agent whose unit is a file of Evlat's own (`OwnedFile`) is the other
/// kind of change: the file is written whole and taken out whole, from the
/// bytes this Mac's writer would write, and read as its state from the bytes —
/// no JSON, and no backup (nothing of the user's is in it). A file without
/// Evlat's marker is the user's: refused, never written over or removed.
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

    /// What is installed or removed; each lives in one file. Equal by the
    /// agent's id: two values for one agent are one change.
    public enum Change: Hashable {
        case hooks(any Agent)
        /// The agent's status line, where a server gets one (`relays`).
        case statusLine(any Agent)
        /// The agent as one unit (`AgentIntegration`'s rule on a server):
        /// its hooks, and — where the server gets its status line
        /// (`relays`) — the usage line, in one write of its one file.
        case agent(any Agent)
        /// `RemotePath.line` in a startup file (`.bashrc`…): text, not JSON.
        case pathLine(String)

        /// The file, relative to the server's `$HOME`. A status line change
        /// is only made for an agent that has one (`relays`).
        public var path: String {
            switch self {
            case .hooks(let source), .agent(let source): return source.integration.file
            case .statusLine(let source): return source.integration.settings?.relay?.file ?? source.integration.file
            case .pathLine(let file): return file
            }
        }

        /// When the file's folder is missing, the directories (relative to
        /// `$HOME`) any one of which lets the scripts open it — the agent's
        /// presence, for an agent whose folder is opened
        /// (`Settings.opensHooksDirectory`, `OwnedFileParts.opensDirectory`).
        /// Empty: a missing folder is `noDirectory`, the agent is not on the
        /// server.
        public var opening: [String] {
            switch self {
            case .hooks(let source), .agent(let source):
                switch source.integration {
                case .settings(let parts): return parts.opensHooksDirectory ? source.presence : []
                case .ownedFile(let parts): return parts.opensDirectory ? source.presence : []
                }
            case .statusLine, .pathLine:
                return []
            }
        }

        /// Whether the file is Evlat's own, written whole (`OwnedFile`), which
        /// the scripts read and write by their own rules: a link at its path
        /// is the user's.
        public var writesWhole: Bool {
            if case .agent(let source) = self { return source.integration.ownedFile != nil }
            return false
        }

        private var key: String {
            switch self {
            case .hooks(let source): return "hooks:" + source.id.rawValue
            case .statusLine(let source): return "statusLine:" + source.id.rawValue
            case .agent(let source): return "agent:" + source.id.rawValue
            case .pathLine(let file): return "pathLine:" + file
            }
        }

        public static func == (a: Change, b: Change) -> Bool { a.key == b.key }
        public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    /// Whether `source`'s unit on a server includes the usage line
    /// (`Relay.onServers`). The same file as its hooks: such an agent's
    /// status line lives in its settings.
    public static func relays(_ source: some Agent) -> Bool { source.integration.settings?.relay?.onServers == true }

    /// Whether a server's unit covers `source`: every form of unit is
    /// written over `ssh` — JSON merged into the agent's settings, or the
    /// file of Evlat's own written whole. A switch, not `true`, so a form
    /// added to `Parts` does not compile until it says whether it is.
    public static func serves(_ source: some Agent) -> Bool {
        switch source.integration {
        case .settings, .ownedFile: return true
        }
    }

    public enum Action: Equatable { case install, remove }

    /// The same options as the tunnel's where they apply: never a prompt,
    /// never someone else's master connection, and none of the host's
    /// configured forwards — one of them could be the tunnel's own port —
    /// and the tunnel's three config overrides (`RemoteTunnel.arguments`):
    /// no configured `RemoteCommand`, empty stdin or fork — the script *is*
    /// stdin.
    ///
    /// With `controlPath` — the tunnel's own master (`RemoteTunnel.arguments`)
    /// — the call rides it as a client (`-S`, `ControlMaster=no`) and the
    /// server sees no second login. A master that has just gone is no
    /// error: `ssh` then connects by itself, as without one.
    public static func arguments(target: String, controlPath: String? = nil) -> [String] {
        let control = controlPath.map { ["-S", $0, "-o", "ControlMaster=no"] }
            ?? ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        return ["-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3"]
            + control
            + ["-o", "ClearAllForwardings=yes",
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
        // A link at the path of a file of Evlat's own: the user's, as on
        // this Mac. Only the scripts of such a file exit with it.
        14: .malformed,
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
    /// `opening` is the change's (`Change.opening`): a folder it may open
    /// reads as a missing file. `owned`: `Change.writesWhole`.
    public static func readScript(path: String, nonce: String, opening: [String] = [], owned: Bool = false) -> String {
        """
        n=\(quoted(nonce))
        \(prelude(path: path, opening: opening, creating: false, owned: owned))
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
        /// How the server's file changes.
        public enum Form: Equatable {
            /// JSON merged into a file the agent shares with the user: the
            /// first version is kept (`.evlat.bak`).
            case merged
            /// A file of Evlat's own, replaced whole. Nothing of the user's is
            /// in it, so no backup is kept, as on this Mac (`OwnedFile`).
            case whole
            /// A file of Evlat's own, taken out. `contents` is empty.
            case removal
        }

        public let contents: Data
        public let backup: Data?
        public let form: Form

        public init(contents: Data, backup: Data?, form: Form = .merged) {
            self.contents = contents
            self.backup = backup
            self.form = form
        }
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
            if case .pathLine = change {
                return try RemotePath.plan(action, original: original).map { Write(contents: $0, backup: nil) }
            }
            if case .agent(let source) = change, let owned = source.integration.ownedFile {
                return try plan(owned.file, action, original: original)
            }
            switch change {
            case .hooks(let source), .statusLine(let source), .agent(let source):
                // Merging into a settings file is the settings form's: its
                // parts, hooks and usage line, are not a file of Evlat's own.
                guard source.integration.settings != nil else { throw SettingsFile.Failure.malformed }
            case .pathLine: break
            }
            let settings = try SettingsFile.parse(original)
            switch (change, action) {
            case (.hooks(let source), .install):
                // A server's hooks include the approval group where the
                // agent's channel installs it there (`LocalHooks`).
                guard let data = try plan(original: original, {
                    LocalHooks.installing(into: $0, for: source, target: .server)
                }) else {
                    if LocalHooks.state(of: settings, for: source, target: .server) != .current {
                        throw SettingsFile.Failure.malformed
                    }
                    return nil
                }
                return Write(contents: data, backup: nil)
            case (.hooks(let source), .remove):
                return try plan(original: original, { LocalHooks.removing(from: $0, for: source) })
                    .map { Write(contents: $0, backup: nil) }
            case (.statusLine(let source), .install):
                guard let data = try plan(original: original, {
                    StatusLineRelay.installing(into: $0, source: source) ?? $0
                }) else {
                    if StatusLineRelay.state(of: settings, source: source) != .current {
                        throw SettingsFile.Failure.malformed
                    }
                    return nil
                }
                // An earlier copy's wrapper moved takes no backup, as on
                // this Mac (`StatusLineRelay.install`).
                let wraps = StatusLineRelay.state(of: settings, source: source) == .missing
                return Write(contents: data, backup: wraps ? try StatusLineRelay.backupContents(of: settings) : nil)
            case (.statusLine(let source), .remove):
                guard let data = try plan(original: original, {
                    StatusLineRelay.removing(from: $0, source: source) ?? $0
                }) else {
                    if StatusLineRelay.state(of: settings, source: source) == .modified {
                        throw SettingsFile.Failure.malformed
                    }
                    return nil
                }
                return Write(contents: data, backup: nil)
            case (.agent(let source), .install):
                return try installUnit(source, settings: settings)
            case (.agent(let source), .remove):
                return try plan(original: original, { settings in
                    let hooks = LocalHooks.removing(from: settings, for: source)
                    guard relays(source) else { return hooks }
                    // Someone's own wrapper is left as it is (`nil`).
                    return StatusLineRelay.removing(from: hooks, source: source) ?? hooks
                }).map { Write(contents: $0, backup: nil) }
            case (.pathLine, _):
                return nil
            }
        } catch let failure as SettingsFile.Failure {
            throw Failure.file(failure)
        }
    }

    /// A file of Evlat's own, from the bytes read (`OwnedFile.state(of:)`'s
    /// rule, this Mac's): current writes nothing — a later copy's too; missing
    /// or older is written whole; a file without Evlat's marker is refused and
    /// stays, whether asked to write or to remove. A removal takes the one
    /// marked file and nothing around it.
    ///
    /// A link at the path never gets here: the scripts of such a file end on
    /// it (exit 14, `malformed`), where a settings file's link is followed —
    /// this Mac calls it foreign, and so does `Reading`.
    private static func plan(_ file: OwnedFile, _ action: Action, original: Data?) throws -> Write? {
        switch (action, file.state(of: original)) {
        case (.install, .current), (.remove, .missing), (.remove, .foreign):
            return nil
        case (.install, .foreign):
            throw SettingsFile.Failure.malformed
        case (.install, .missing), (.install, .outdated):
            return Write(contents: Data(file.contents.utf8), backup: nil, form: .whole)
        case (.remove, .current), (.remove, .outdated):
            return Write(contents: Data(), backup: nil, form: .removal)
        }
    }

    /// The unit's install: hooks, then the usage line where it is a part
    /// and still missing, or an earlier copy's — a wrapper changed by hand
    /// is never written over. The relay's backup is carried only when this
    /// write wraps a `statusLine` that had none of Evlat's, as on this Mac
    /// (`AgentIntegration`). Nothing to write while a part that should be
    /// there is not: a shape not ours, refused.
    private static func installUnit(_ source: some Agent, settings: [String: Any]) throws -> Write? {
        var next = LocalHooks.installing(into: settings, for: source, target: .server)
        let relay = StatusLineRelay.state(of: settings, source: source)
        let wraps = relays(source) && relay == .missing
        if relays(source), relay == .missing || relay == .outdated,
           let wrapped = StatusLineRelay.installing(into: next, source: source) { next = wrapped }
        guard !NSDictionary(dictionary: next).isEqual(to: settings) else {
            let unit = AgentIntegration.relayState(of: settings, source: source)
            let relayShort = relays(source) && (unit == .missing || unit == .outdated)
            if LocalHooks.state(of: settings, for: source, target: .server) != .current || relayShort {
                throw SettingsFile.Failure.malformed
            }
            return nil
        }
        let wrapped = wraps && StatusLineRelay.state(of: next, source: source) == .current
        return Write(contents: try SettingsFile.encode(next),
                     backup: wrapped ? try StatusLineRelay.backupContents(of: settings) : nil)
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
    /// local writer does not write. `opening` is the change's
    /// (`Change.opening`): the missing folder is made, as this Mac's writer
    /// makes it.
    ///
    /// A file of Evlat's own (`Write.Form`) keeps no first backup, and a link
    /// at its path ends the script (`prelude`'s `owned`). Its removal checks
    /// the `cksum` the same way, then takes the file out: not the folder, not
    /// what sits beside it.
    public static func writeScript(path: String, expected: String, write: Write, opening: [String] = []) -> String {
        let unwritable = code(.unwritable)
        if write.form == .removal {
            return """
            e=\(quoted(expected))
            \(prelude(path: path, opening: opening, creating: false, owned: true))
            s=$(sum) || exit \(code(.unreadable))
            [ "$s" = "$e" ] || exit \(code(.changedUnderneath))
            rm -f "$t" || exit \(unwritable)
            exit 0

            """
        }
        let firstBackup = write.form == .merged
            ? "  if [ ! -e \"$f.evlat.bak\" ] && [ ! -h \"$f.evlat.bak\" ]; then cp -p \"$t\" \"$f.evlat.bak\" || exit \(unwritable); fi\n"
            : ""
        var script = """
        e=\(quoted(expected))
        c=\(quoted(String(decoding: write.contents, as: UTF8.self)))
        \(prelude(path: path, opening: opening, creating: true, owned: write.form == .whole))
        s=$(sum) || exit \(code(.unreadable))
        [ "$s" = "$e" ] || exit \(code(.changedUnderneath))
        tmp=${t%/*}/.${t##*/}.evlat.$$.tmp
        btmp=
        trap 'rm -f "$tmp" ${btmp:+"$btmp"}' EXIT
        if [ -e "$t" ]; then
        \(firstBackup)  cp -p "$t" "$tmp" || exit \(unwritable)
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

    // MARK: - Reading a machine

    /// What one item on a server reads as: its state, or why there is none.
    public enum Found<State: Equatable>: Equatable {
        /// The agent's folder is not on the server: it is not installed there.
        case noDirectory
        /// A file that could not be read or is not JSON.
        case unreadable
        case state(State)
    }

    /// A machine as one call found it (`readingScript`): each agent's
    /// settings file's bytes with their `cksum`, the `evlat` command, and
    /// whether a new login shell finds it.
    public struct Reading: Equatable {
        public let files: [AgentID: Result<Snapshot, SettingsFile.Failure>]
        public let command: RemoteCommand.Status
        /// `nil` when the probe's line was not in the answer.
        public var path: RemotePath.Status?
        /// The channel's end on the server, when the call probed it (the
        /// tunnel's own call, `RemoteTunnel.channelProbe`).
        public var channel: RemoteTunnel.Channel?

        /// The local reader's state, from the bytes read.
        public func hooks(_ source: some Agent) -> Found<HookSettings.State> {
            found(source, settings: { LocalHooks.state(of: $0, for: source, target: .server) },
                  ownedFile: { AgentIntegration.state(ownedFile: $0).hooks })
        }

        /// The agent's usage line, read from its hooks file: meaningful for
        /// an agent a server relays (`relays`), whose line lives there. A
        /// file of Evlat's own has none.
        public func statusLine(_ source: some Agent) -> Found<StatusLineRelay.State> {
            found(source, settings: { StatusLineRelay.state(of: $0, source: source) }, ownedFile: { _ in .missing })
        }

        /// The agent as one unit, by the same rule as this Mac's card
        /// (`AgentIntegration.State`): its hooks, and the usage line where
        /// the server gets one (`relays`) — read from the same file. For a
        /// file of Evlat's own, that file's state from its bytes.
        public func unit(_ source: some Agent) -> Found<AgentIntegration.State> {
            found(source, settings: { settings in
                AgentIntegration.State(
                    hooks: LocalHooks.state(of: settings, for: source, target: .server),
                    relay: RemoteSettings.relays(source)
                        ? AgentIntegration.relayState(of: settings, source: source) : nil)
            }, ownedFile: { AgentIntegration.state(ownedFile: $0) })
        }

        /// The bytes read, as the agent's form of unit reads them: parsed
        /// as settings, or taken whole as a file of Evlat's own, which
        /// is never parsed — it is not JSON. A link at its path is the
        /// user's, `foreign` as on this Mac: the scripts end on it, and the
        /// section reads `malformed`.
        private func found<State>(_ source: some Agent, settings state: ([String: Any]) -> State,
                                  ownedFile owned: (OwnedFile.State) -> State) -> Found<State> {
            switch files[source.id] {
            case .success(let snapshot)?:
                if let parts = source.integration.ownedFile { return .state(owned(parts.file.state(of: snapshot.bytes))) }
                guard let settings = try? SettingsFile.parse(snapshot.bytes) else { return .unreadable }
                return .state(state(settings))
            case .failure(.noDirectory)?: return .noDirectory
            case .failure(.malformed)? where source.integration.ownedFile != nil: return .state(owned(.foreign))
            default: return .unreadable
            }
        }
    }

    /// One script for the whole machine, so one `ssh` call: per settings
    /// file, `<nonce> begin <source> <cksum>`, the bytes, and
    /// `\n<nonce> end <source> <code>`; then the command's line. Each file
    /// runs in its own subshell, so a missing folder ends its part and not
    /// the read. It reads only: nothing is written, not even a temporary
    /// file, and a file that changes while it is read reads as unreadable.
    ///
    /// `probing`: the tunnel's call, the channel's probe first
    /// (`RemoteTunnel.channelProbe`) — the one part that writes, and only
    /// its own folder and a dead socket.
    public static func readingScript(nonce: String, agents: [any Agent],
                                     patience: Int = RemotePath.patience, probing: Bool = false) -> String {
        let unreadable = code(.unreadable)
        var script = probing ? RemoteTunnel.channelProbe(nonce: nonce) + "\n" : ""
        for source in agents where serves(source) {
            script += """
            (
            n=\(quoted(nonce))
            \(prelude(path: source.integration.file, opening: Change.agent(source).opening, creating: false,
                       owned: Change.agent(source).writesWhole))
            s=$(sum) || exit \(unreadable)
            printf '%s begin \(source.id.rawValue) %s\\n' "$n" "$s"
            if [ -e "$t" ]; then cat "$t" || exit \(unreadable); fi
            [ "$(sum)" = "$s" ] || exit \(code(.changedUnderneath))
            exit 0
            )
            printf '\\n%s end \(source.id.rawValue) %s\\n' \(quoted(nonce)) "$?"

            """
        }
        return script + RemoteCommand.statusProbe(nonce: nonce) + "\n"
            + RemotePath.probe(nonce: nonce, patience: patience) + "\nexit 0\n"
    }

    /// The script's answer; `unreachable` when `ssh` failed or no line of
    /// the answer is the script's.
    public static func reading(exitCode: Int32, output: Data, nonce: String, agents: [AgentID]) throws -> Reading {
        guard exitCode == 0, let command = RemoteCommand.status(output: output, nonce: nonce) else {
            throw Failure.unreachable
        }
        var files: [AgentID: Result<Snapshot, SettingsFile.Failure>] = [:]
        for source in agents {
            let end = Data("\n\(nonce) end \(source.rawValue) ".utf8)
            guard let ending = output.range(of: end),
                  let newline = output[ending.upperBound...].firstIndex(of: 0x0A),
                  let code = Int32(String(decoding: output[ending.upperBound..<newline], as: UTF8.self))
            else { throw Failure.unreachable }
            guard code == 0 else {
                files[source] = .failure(exitCodes[code] ?? .unreadable)
                continue
            }
            let begin = Data("\(nonce) begin \(source.rawValue) ".utf8)
            guard let beginning = output.range(of: begin, in: output.startIndex..<ending.lowerBound),
                  beginning.lowerBound == output.startIndex || output[output.index(before: beginning.lowerBound)] == 0x0A,
                  let lineEnd = output[beginning.upperBound..<ending.lowerBound].firstIndex(of: 0x0A)
            else { throw Failure.unreachable }
            let checksum = String(decoding: output[beginning.upperBound..<lineEnd], as: UTF8.self)
            let bytes = Data(output[output.index(after: lineEnd)..<ending.lowerBound])
            files[source] = .success(Snapshot(bytes: checksum == absent ? nil : bytes, checksum: checksum))
        }
        return Reading(files: files, command: command, path: RemotePath.status(output: output, nonce: nonce),
                       channel: RemoteTunnel.channel(output: output, nonce: nonce))
    }

    // MARK: - The one block

    /// The heredoc delimiter of the block's parts: no line of a part is it
    /// (the settings travel as encoded JSON, whose lines are never bare; a
    /// file of Evlat's own is held to it by a test, since an edit of its
    /// text could break the pasted block without a word).
    public static let combinedDelimiter = "EVLAT_SETUP"

    /// Everything the automatic buttons would install, as one block a user
    /// runs in their own shell on the server — made from `reading`, so the
    /// same bytes: a settings file's part is its `writeScript` against the
    /// `cksum` read, and refuses a file that changed since; the command's
    /// part is `RemoteCommand.manual`'s blocks; the PATH part adds
    /// `RemotePath.line` unless the pasting shell's `PATH` has the folder.
    ///
    /// It carries each settings file whole, as read, or the file of Evlat's
    /// own as it is written, and no secret. A part is left out
    /// when there is nothing to write, the agent's folder is missing, the
    /// file could not be read, or the command is somebody else's; a
    /// wrapper changed by hand keeps the file's hooks part and loses only
    /// the usage line. Only `agents` get a part, in their order: the
    /// machine's switches. `nil`: nothing to write at all.
    ///
    /// Each part is a `sh` of its own on a quoted heredoc: `exit` and the
    /// traps stay inside it, nothing is expanded by the user's shell, and a
    /// part that fails says which file on stderr. No line starts with `#`
    /// outside a part: an interactive zsh reads a comment as a command.
    public static func combinedScript(_ reading: Reading, agents: [any Agent]) -> String? {
        var parts: [String] = []
        for source in agents where serves(source) {
            guard case .success(let snapshot)? = reading.files[source.id] else { continue }
            // The automatic button's own transform: the unit, hooks and
            // usage line together.
            guard let write = (try? plan(.agent(source), .install, original: snapshot.bytes)) ?? nil else { continue }
            parts.append(part(file: "~/" + source.integration.file,
                              writeScript(path: source.integration.file, expected: snapshot.checksum, write: write,
                                          opening: Change.agent(source).opening)))
        }
        let commandPart = reading.command != .foreign && !reading.command.isCurrent
        if commandPart {
            let manual = RemoteCommand.manual()
            let marker = quoted(RemoteCommand.marker)
            parts.append(part(file: "~/" + RemoteCommand.commandPath, """
                e="$HOME"/\(quoted(RemoteCommand.commandPath))
                if [ -h "$e" ]; then exit 10; fi
                if [ -e "$e" ] && [ "$(sed -n 2p "$e" 2>/dev/null)" != \(marker) ]; then exit 10; fi
                \(manual.script)\
                [ "$(sed -n 2p "$e" 2>/dev/null)" = \(marker) ] || exit 13
                exit 0

                """))
        }
        // The command's folder on the user's PATH: decided where the block
        // runs, in the user's own shell; left out when the read found it
        // there or Evlat's line already in the file.
        if reading.command != .foreign,
           commandPart || reading.path?.onPath != true,
           reading.path?.added != true {
            parts.append(part(file: "~/" + (reading.path?.file ?? ".profile"), RemotePath.combinedPart))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined()
    }

    private static func part(file: String, _ script: String) -> String {
        "sh <<'\(combinedDelimiter)' || echo \"evlat: \(file) was not written (exit $?)\" >&2\n"
            + "# \(file)\n" + script + combinedDelimiter + "\n"
    }

    // MARK: - Script parts

    static let absent = "absent"

    /// `f`: the path the user knows. `t`: where its links end — a link whose
    /// end is missing is refused, as `SettingsFile.resolve` refuses it.
    /// `sum`: the target's `cksum` line, `absent`, or failure.
    ///
    /// A missing folder is `noDirectory` — the agent is not on the server.
    /// With `opening`, the agent's presence decides instead: none of its
    /// directories is `noDirectory` whatever the folder; one is, and a
    /// missing folder reads as an absent file and a write (`creating`)
    /// makes it.
    ///
    /// `owned`: the file is Evlat's own, written whole. Settings merge into
    /// the file a link points at, but a link here is the user's — this Mac
    /// reads it `foreign` — so the script ends on it, `malformed`.
    private static func prelude(path: String, opening: [String], creating: Bool, owned: Bool = false) -> String {
        let unreadable = code(.unreadable)
        let link = owned ? "[ ! -h \"$f\" ] || exit \(code(.malformed))\n" : ""
        let folder: String
        if opening.isEmpty {
            folder = "[ -d \"${f%/*}\" ] || exit \(code(.noDirectory))"
        } else {
            let present = opening.map { "[ -d \"$HOME\"/\(quoted($0)) ]" }.joined(separator: " || ")
            // Asked even when the folder is there: a shared folder left
            // behind, or made by another tool, does not say the agent is.
            folder = "{ \(present); } || exit \(code(.noDirectory))"
                + (creating ? "\n[ -d \"${f%/*}\" ] || mkdir -p \"${f%/*}\" || exit \(code(.unwritable))" : "")
        }
        return """
        f="$HOME"/\(quoted(path))
        \(folder)
        \(link)link() {
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

        /// Each agent's unit file: its hooks file (`Settings.hooksFile`) as a
        /// whole file's JSON, or the bytes of its file of Evlat's own.
        let hooks: [AgentID: String]
        /// The `statusLine` for a file that has none.
        public let statusLine: String
        /// The wrapper around an existing command, `placeholder` in its place.
        public let wrapping: String
        /// Every command Evlat writes contains this; removing by hand is
        /// taking out the entries that do.
        public let marker: String

        /// The agent's unit file, as a whole file's contents.
        public func hooks(for source: some Agent) -> String { hooks[source.id] ?? "" }

        /// An agent's `statusLine` for a file that has none, and its wrapper
        /// with `placeholder` in the user's command's place; `nil` for an
        /// agent with no status line. A server's are `statusLine` and
        /// `wrapping`, for the agent it relays (`relays`); another agent's
        /// are this Mac's only.
        public static func statusLine(for source: some Agent) -> (text: String, wrapping: String)? {
            guard let line = StatusLineRelay.installing(into: [:], source: source) else { return nil }
            return (text(line), StatusLineRelay.command(wrapping: placeholder, source: source))
        }

        static func text(_ settings: [String: Any]) -> String {
            // The empty object always encodes; `[:]` never reaches this.
            String(decoding: (try? SettingsFile.encode(settings)) ?? Data(), as: UTF8.self)
        }
    }

    /// For `agents`; the status line is the one a server relays (`relays`).
    public static func manual(agents all: [any Agent]) -> Manual {
        let agents = all.filter { serves($0) }
        let statusLine = agents.first(where: { relays($0) }).flatMap { Manual.statusLine(for: $0) }
        return Manual(
            hooks: Dictionary(uniqueKeysWithValues: agents.map { source in
                (source.id, source.integration.ownedFile?.file.contents
                    ?? Manual.text(LocalHooks.installing(into: [:], for: source, target: .server)))
            }),
            statusLine: statusLine?.text ?? "",
            wrapping: statusLine?.wrapping ?? "",
            marker: "127.0.0.1:\(LocalAPI.defaultPort)")
    }
}
