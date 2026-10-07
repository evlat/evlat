import XCTest
import AppKit
@testable import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// A machine's state read over `ssh`: one script, one call,
/// the two settings files and the `evlat` command, reading only — and the
/// one block that sets all three up by hand from that reading.
///
/// Every `ssh` here is a **fake** that runs the script it is handed with
/// `HOME` at a temporary "server" home, under `/bin/sh`, `/bin/dash` and
/// `/bin/bash`. The real `ssh` is never run and no real home is read or
/// written; the pasteboard is a named one of the test's own.
@MainActor
final class RemoteReadingTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!

    private let shells = ["/bin/sh", "/bin/dash", "/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    override func setUpWithError() throws {
        let temporary = realpath(FileManager.default.temporaryDirectory.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent("evlat-remote-reading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("evlat.tests.\(UUID().uuidString)"))
        XCTAssertEqual(shells.count, 3, "sh, dash and bash are all here")
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private enum Mode {
        case run
        /// A login script that prints before the command runs.
        case banner
        /// How `ssh` fails to connect.
        case unreachable
    }

    /// A server: its `$HOME` and a fake `ssh` that runs scripts there.
    private struct Server {
        let home: URL
        let ssh: String
        let runs: URL
        /// The server user's login shell (`$SHELL`), a fake.
        let shell: String

        var sshRuns: Int {
            ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        var claude: URL { Claude().hooksFile(home: home) }
        var codex: URL { Codex().hooksFile(home: home) }
        var command: URL { home.appendingPathComponent(RemoteCommand.commandPath) }
        var key: URL { home.appendingPathComponent(RemoteCommand.keyPath) }
        func file(_ name: String) -> URL { home.appendingPathComponent(name) }
    }

    /// The PATH a root login on Ubuntu starts with: no `~/.local/bin`.
    static let rootPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// A fake login shell named `name` (`bash`, `zsh`, `sh`, `fish`): it
    /// starts from `rootPath`, reads `$HOME`'s startup file as that shell
    /// would (`.bashrc`, `.zshrc`, else `.profile`) and runs its `-lic`
    /// command. `body` replaces all of that. The runner's own `$SHELL` is
    /// never run interactively.
    private func loginShell(_ name: String, in run: URL, body: String? = nil) throws -> String {
        let folder = run.appendingPathComponent("shells-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = folder.appendingPathComponent(name)
        try """
            #!/bin/sh
            \(FreshExecutable.warmLine)
            \(body ?? """
            PATH='\(Self.rootPath)'
            export PATH
            case ${0##*/} in bash) r=.bashrc ;; zsh) r=.zshrc ;; *) r=.profile ;; esac
            [ -f "$HOME/$r" ] && . "$HOME/$r"
            [ "$1" = -lic ] || exit 64
            eval "$2"
            """)

            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        FreshExecutable.warm(fake.path)
        return fake.path
    }

    private func server(_ shell: String, _ mode: Mode = .run, login: String = "bash",
                        loginBody: String? = nil) throws -> Server {
        let run = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = run.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fake = run.appendingPathComponent("fake-ssh")
        let runs = run.appendingPathComponent("runs")
        let loginShell = try login.isEmpty ? "" : self.loginShell(login, in: run, body: loginBody)
        let exec = "umask 022\nSHELL='\(loginShell)'\nexport SHELL\nHOME='\(home.path)' exec \(shell) -s"
        let body: String
        switch mode {
        case .run: body = exec
        case .banner: body = "echo 'Welcome to devbox'\nprintf 'x command 1 ours 1\\nx end claude 0\\n'\n\(exec)"
        case .unreachable: body = "echo 'ssh: connect to host fake port 22: Connection refused' >&2\nexit 255"
        }
        try """
            #!/bin/sh
            \(FreshExecutable.warmLine)
            echo run >> '\(runs.path)'
            \(body)

            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        FreshExecutable.warm(fake.path)
        return Server(home: home, ssh: fake.path, runs: runs, shell: loginShell)
    }

    private func folder(_ source: some Agent, in server: Server) throws {
        try FileManager.default.createDirectory(at: source.hooksFile(home: server.home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    private func seed(_ source: some Agent, _ text: String?, in server: Server) throws {
        try folder(source, in: server)
        guard let text else { return }
        try Data(text.utf8).write(to: source.hooksFile(home: server.home))
    }

    private func read(_ server: Server) -> Result<RemoteSettings.Reading, RemoteSettings.Failure> {
        RemoteInstaller.applyRead(target: "fake", ssh: server.ssh)
    }

    private func reading(_ server: Server, file: StaticString = #filePath, line: UInt = #line) throws -> RemoteSettings.Reading {
        switch read(server) {
        case .success(let reading): return reading
        case .failure(let failure):
            XCTFail("read failed: \(failure)", file: file, line: line)
            throw failure
        }
    }

    /// Everything the automatic buttons would write, one call each.
    private func installAutomatically(_ server: Server) {
        for change in [RemoteSettings.Change.hooks(.claude), .hooks(.codex), .statusLine(.claude)] {
            _ = RemoteInstaller.apply(change, .install, target: "fake", ssh: server.ssh)
        }
        _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
        // Then "Add to PATH", when the read says a new shell does not find it.
        if case .success(let reading) = read(server), let path = reading.path, path.onPath == false, !path.added {
            _ = RemoteInstaller.apply(.pathLine(path.file), .install, target: "fake", ssh: server.ssh)
        }
    }

    /// `text` on `shell`'s stdin with `HOME` at `home`: what a user pasting
    /// the block into their shell on the server runs.
    /// The user's shell is `loginShell` (`$SHELL`) and its `PATH` is `path`,
    /// `rootPath` unless given: the PATH part of the block reads both.
    @discardableResult
    private func paste(_ shell: String, _ text: String, home: URL, loginShell: String,
                       path: String = RemoteReadingTests.rootPath) throws -> (status: Int32, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 022; exec \"$0\" -s", shell]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["SHELL"] = loginShell
        environment["PATH"] = path
        process.environment = environment
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: err, as: UTF8.self))
    }

    private func bytes(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// Every entry under `home`: path, type, mode, size, date, bytes or link.
    private func tree(_ home: URL) throws -> [String] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted()
        return try paths.map { path in
            let full = home.appendingPathComponent(path).path
            let attributes = try FileManager.default.attributesOfItem(atPath: full)
            let type = attributes[.type] as? FileAttributeType
            var line = "\(path) \(type?.rawValue ?? "?") \(attributes[.posixPermissions] ?? "?") "
                + "\(attributes[.size] ?? "?") \(attributes[.modificationDate] ?? "?")"
            if type == .typeSymbolicLink {
                line += " -> " + (try FileManager.default.destinationOfSymbolicLink(atPath: full))
            } else if type == .typeRegular {
                line += " " + (FileManager.default.contents(atPath: full)?.base64EncodedString() ?? "unreadable")
            }
            return line
        }
    }

    private let existing = #"""
        {
          "model" : "opus",
          "hooks" : { "PreToolUse" : [ { "matcher" : "*", "hooks" : [ { "type" : "command", "command" : "/usr/local/bin/other notify" } ] } ] },
          "statusLine" : { "type" : "command", "command" : "bash ~/.claude/it's.sh", "padding" : 0 }
        }
        """#

    private let oldHook = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"curl -s 127.0.0.1:48151/hook/old"}]}]}}"#

    // MARK: - One read

    func testOneCallReadsTheThreeItems() throws {
        for shell in shells {
            let server = try self.server(shell)
            try seed(.claude, existing, in: server)
            try folder(.codex, in: server)
            installAutomatically(server)
            let before = server.sshRuns
            let reading = try self.reading(server)
            XCTAssertEqual(server.sshRuns - before, 1, "\(shell): one ssh call per machine")
            XCTAssertEqual(reading.hooks(.claude), .state(.current), shell)
            XCTAssertEqual(reading.hooks(.codex), .state(.current), shell)
            XCTAssertEqual(reading.statusLine(.claude), .state(.current), shell)
            XCTAssertEqual(reading.command, .installed(version: RemoteCommand.version), shell)
            XCTAssertTrue(reading.command.isCurrent, shell)
        }
    }

    func testAnEmptyServerReadsAsNothingThere() throws {
        for shell in shells {
            let server = try self.server(shell)
            let reading = try self.reading(server)
            XCTAssertEqual(reading.hooks(.claude), .noDirectory, shell)
            XCTAssertEqual(reading.hooks(.codex), .noDirectory, shell)
            XCTAssertEqual(reading.statusLine(.claude), .noDirectory, shell)
            XCTAssertEqual(reading.command, .missing, shell)
            try folder(.claude, in: server)
            XCTAssertEqual(try self.reading(server).hooks(.claude), .state(.missing), "\(shell): a folder, no file")
        }
    }

    func testEachStateIsReadAsTheLocalReadersReadIt() throws {
        for shell in shells {
            let server = try self.server(shell)
            try seed(.claude, oldHook, in: server)
            let modified = StatusLineRelay.command(wrapping: "bash s.sh", source: .claude) + " # mine"
            try seed(.codex, String(decoding: try SettingsFile.encode(["statusLine": ["command": modified]]), as: UTF8.self),
                     in: server)
            var reading = try self.reading(server)
            XCTAssertEqual(reading.hooks(.claude), .state(.outdated), shell)
            XCTAssertEqual(reading.hooks(.codex), .state(.missing), shell)
            XCTAssertEqual(reading.statusLine(.claude), .state(.missing), shell)

            try seed(.claude, String(decoding: try SettingsFile.encode(["statusLine": ["type": "command", "command": modified]]),
                                     as: UTF8.self), in: server)
            XCTAssertEqual(try self.reading(server).statusLine(.claude), .state(.modified), "\(shell): a wrapper changed by hand")

            try seed(.claude, "{ not json", in: server)
            reading = try self.reading(server)
            XCTAssertEqual(reading.hooks(.claude), .unreadable, "\(shell): broken JSON")
            XCTAssertEqual(reading.statusLine(.claude), .unreadable, shell)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: server.claude.path)
            XCTAssertEqual(try self.reading(server).hooks(.claude), .unreadable, "\(shell): no read permission")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: server.claude.path)

            try FileManager.default.removeItem(at: server.claude)
            try FileManager.default.createSymbolicLink(at: server.claude, withDestinationURL: server.home.appendingPathComponent("gone"))
            XCTAssertEqual(try self.reading(server).hooks(.claude), .unreadable, "\(shell): a link to nothing")
        }
    }

    func testALinkedSettingsFileIsReadAtItsEnd() throws {
        for shell in shells {
            let server = try self.server(shell)
            try folder(.claude, in: server)
            let real = server.home.appendingPathComponent("dotfiles-settings.json")
            try Data(oldHook.utf8).write(to: real)
            try FileManager.default.createSymbolicLink(atPath: server.claude.path, withDestinationPath: "../dotfiles-settings.json")
            let reading = try self.reading(server)
            XCTAssertEqual(reading.hooks(.claude), .state(.outdated), shell)
            guard case .success(let snapshot)? = reading.files[.claude] else { return XCTFail(shell) }
            XCTAssertEqual(snapshot.bytes, Data(oldHook.utf8), shell)
        }
    }

    func testTheCommandsStates() throws {
        for shell in shells {
            let server = try self.server(shell)
            // A server set up by version 1: its command and its key.
            try FileManager.default.createDirectory(at: server.key.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("\(String(repeating: "5a", count: 32))\n".utf8).write(to: server.key)
            _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
            XCTAssertFalse(FileManager.default.fileExists(atPath: server.key.path),
                           "\(shell): the install takes version 1's key away")
            var reading = try self.reading(server)
            XCTAssertEqual(reading.command, .installed(version: RemoteCommand.version), shell)
            XCTAssertTrue(reading.command.isCurrent, shell)

            let older = RemoteCommand.script.replacingOccurrences(of: "# version \(RemoteCommand.version)\n",
                                                                  with: "# version 1\n")
            XCTAssertNotEqual(older, RemoteCommand.script)
            try Data(older.utf8).write(to: server.command)
            reading = try self.reading(server)
            XCTAssertEqual(reading.command, .installed(version: 1), shell)
            XCTAssertFalse(reading.command.isCurrent, "\(shell): version 1 speaks to a port nothing holds")

            // Another Mac's newer Evlat installed it: not old to this one.
            let newer = RemoteCommand.script.replacingOccurrences(of: "# version \(RemoteCommand.version)\n",
                                                                  with: "# version 99\n")
            try Data(newer.utf8).write(to: server.command)
            reading = try self.reading(server)
            XCTAssertEqual(reading.command, .installed(version: 99), shell)
            XCTAssertTrue(reading.command.isCurrent, "\(shell): a later version is not called old")

            try Data("#!/bin/sh\n# somebody else's evlat\n".utf8).write(to: server.command)
            XCTAssertEqual(try self.reading(server).command, .foreign, shell)

            try FileManager.default.removeItem(at: server.command)
            try FileManager.default.createSymbolicLink(atPath: server.command.path, withDestinationPath: "/bin/echo")
            XCTAssertEqual(try self.reading(server).command, .foreign, "\(shell): a link is somebody else's")
        }
    }

    func testTheScriptPrintsTheSameUnderEveryShell() throws {
        var outputs: [String: Data] = [:]
        let first = try server("/bin/sh")
        try seed(.claude, existing, in: first)
        try seed(.codex, "{}", in: first)
        installAutomatically(first)
        let script = RemoteSettings.readingScript(nonce: "N0NCE", agents: Agents.all)
        for shell in shells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-s"]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = first.home.path
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            outputs[shell] = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, shell)
        }
        XCTAssertEqual(Set(outputs.values).count, 1, "the same bytes under \(shells)")
        let reading = try RemoteSettings.reading(exitCode: 0, output: try XCTUnwrap(outputs["/bin/dash"]), nonce: "N0NCE", agents: Agents.all.ids)
        XCTAssertEqual(reading.hooks(.claude), .state(.current))
    }

    func testAReadWritesNothing() throws {
        for shell in shells {
            let server = try self.server(shell)
            try seed(.claude, existing, in: server)
            try folder(.codex, in: server)
            installAutomatically(server)
            try FileManager.default.createSymbolicLink(at: server.home.appendingPathComponent("link"),
                                                       withDestinationURL: server.claude)
            let before = try tree(server.home)
            _ = try reading(server)
            XCTAssertEqual(try tree(server.home), before, "\(shell): nothing written, nothing left behind")
        }
    }

    func testALoginBannerIsNotTheAnswer() throws {
        for shell in shells {
            let server = try self.server(shell, .banner)
            let reading = try self.reading(server)
            XCTAssertEqual(reading.command, .missing, shell)
            XCTAssertEqual(reading.hooks(.claude), .noDirectory, shell)
        }
    }

    func testSSHsOwnFailureIsUnreachable() throws {
        let server = try self.server("/bin/sh", .unreachable)
        XCTAssertEqual(read(server).failure, .unreachable)
        XCTAssertThrowsError(try RemoteSettings.reading(exitCode: 0, output: Data("hello\n".utf8), nonce: "N", agents: Agents.all.ids),
                             "no answer line is no answer")
    }

    /// A call past its deadline is ended and reads as unreachable, so a
    /// stuck server does not hold `RemoteHostLookup`'s serial queue.
    /// `sleep` itself, not under a shell: a shell's child would keep the
    /// pipe open after the shell ended.
    func testACallPastItsDeadlineIsEnded() throws {
        let started = Date()
        let answer = try RemoteInstaller.run("/bin/sleep", ["30"], script: "", deadline: 0.3)
        XCTAssertEqual(answer.status, 255)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - The one block

    func testTheBlockWritesWhatTheAutomaticInstallWrites() throws {
        for shell in shells {
            for text in [nil, existing] {
                let automatic = try server(shell), hand = try server(shell)
                for server in [automatic, hand] {
                    try seed(.claude, text, in: server)
                    try folder(.codex, in: server)
                    // A startup file whose last line has no newline.
                    if text != nil { try Data("alias ll='ls -l'".utf8).write(to: server.file(".bashrc")) }
                }
                installAutomatically(automatic)
                let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(hand), agents: Agents.all), shell)
                XCTAssertEqual(try paste(shell, block, home: hand.home, loginShell: hand.shell).status, 0, shell)

                let label = "\(shell): \(text == nil ? "no file" : "a file")"
                for (a, b) in [(automatic.claude, hand.claude), (automatic.codex, hand.codex),
                               (automatic.command, hand.command),
                               (automatic.file(".bashrc"), hand.file(".bashrc"))] {
                    XCTAssertEqual(bytes(b), bytes(a), "\(label): \(b.lastPathComponent)")
                    XCTAssertEqual(try mode(b), try mode(a), "\(label): \(b.lastPathComponent)'s mode")
                }
                let statusBackup = StatusLineRelay.backupExtension
                XCTAssertEqual(bytes(hand.claude.appendingPathExtension(statusBackup)),
                               bytes(automatic.claude.appendingPathExtension(statusBackup)), "\(label): \(statusBackup)")
                // The first backup is the user's file as it was. With no file
                // there is none: the automatic path's two calls back up Evlat's
                // own hooks-only file before the usage line; one write does not.
                XCTAssertEqual(bytes(hand.claude.appendingPathExtension("evlat.bak")),
                               text.map { Data($0.utf8) }, "\(label): evlat.bak")
                if text != nil {
                    XCTAssertEqual(bytes(hand.claude.appendingPathExtension("evlat.bak")),
                                   bytes(automatic.claude.appendingPathExtension("evlat.bak")), label)
                }
                XCTAssertEqual(bytes(hand.codex.appendingPathExtension("evlat.bak")),
                               bytes(automatic.codex.appendingPathExtension("evlat.bak")), label)
                XCTAssertFalse(FileManager.default.fileExists(atPath: hand.key.path), "\(label): no key")
                XCTAssertEqual(bytes(hand.file(".bashrc.evlat.bak")), bytes(automatic.file(".bashrc.evlat.bak")),
                               "\(label): .bashrc.evlat.bak")
                XCTAssertEqual(bytes(hand.file(".bashrc.evlat.bak")), text.map { _ in Data("alias ll='ls -l'".utf8) },
                               "\(label): the startup file as it was, and none when there was none")
                XCTAssertEqual(bytes(hand.file(".bashrc")),
                               Data(((text == nil ? "" : "alias ll='ls -l'\n") + RemotePath.line + "\n").utf8),
                               "\(label): the PATH line, on a line of its own")

                XCTAssertNil(RemoteSettings.combinedScript(try reading(hand), agents: Agents.all),
                             "\(label): nothing left to write, no block")
            }
        }
    }

    func testAFileChangedAfterTheReadIsRefusedAndTheRestIsWritten() throws {
        for shell in shells {
            let server = try self.server(shell)
            try seed(.claude, existing, in: server)
            try folder(.codex, in: server)
            let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all))
            let theirs = Data(#"{"model":"sonnet"}"#.utf8)
            try theirs.write(to: server.claude)

            let pasted = try paste(shell, block, home: server.home, loginShell: server.shell)
            XCTAssertEqual(bytes(server.claude), theirs, "\(shell): theirs is kept")
            XCTAssertTrue(pasted.errors.contains(Claude().integration.hooksFile), "\(shell): \(pasted.errors)")
            XCTAssertEqual(try HookSettings.state(at: server.codex, for: .codex), .current, "\(shell): Codex is written")
            XCTAssertEqual(bytes(server.command), Data(RemoteCommand.script.utf8), "\(shell): the command is written")
            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: Claude().hooksFile(home: server.home).deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
            XCTAssertEqual(leftovers, [], shell)
        }
    }

    func testTheBlockLeavesWhatIsNotEvlatsAlone() throws {
        for shell in shells {
            let server = try self.server(shell)
            let modified = StatusLineRelay.command(wrapping: "bash s.sh", source: .claude) + " # mine"
            try seed(.claude, String(decoding: try SettingsFile.encode(["statusLine": ["type": "command", "command": modified]]),
                                     as: UTF8.self), in: server)
            try FileManager.default.createDirectory(at: server.command.deletingLastPathComponent(), withIntermediateDirectories: true)
            let foreign = Data("#!/bin/sh\n# somebody else's evlat\necho mine\n".utf8)
            try foreign.write(to: server.command)

            let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all))
            XCTAssertFalse(block.contains(Codex().integration.hooksFile), "\(shell): no Codex on the server, no Codex part")
            XCTAssertFalse(block.contains(RemoteCommand.marker), "\(shell): somebody else's evlat, no command part")
            XCTAssertEqual(try paste(shell, block, home: server.home, loginShell: server.shell).status, 0, shell)

            let settings = try JSONSerialization.jsonObject(with: try XCTUnwrap(bytes(server.claude))) as? [String: Any]
            XCTAssertEqual(HookSettings.state(of: try XCTUnwrap(settings), for: .claude), .current, "\(shell): hooks in")
            XCTAssertEqual((settings?["statusLine"] as? [String: Any])?["command"] as? String, modified,
                           "\(shell): the wrapper changed by hand is not touched")
            XCTAssertEqual(bytes(server.command), foreign, shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: Codex().hooksFile(home: server.home).deletingLastPathComponent().path),
                           "\(shell): no folder is made")
        }
    }

    func testTheBlocksDelimiterIsNoLineOfIt() throws {
        let server = try self.server("/bin/sh")
        try seed(.claude, existing, in: server)
        try folder(.codex, in: server)
        let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all))
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.filter { $0 == RemoteSettings.combinedDelimiter[...] }.count, 4,
                       "four parts (two files, the command, the PATH), each closed once")
        XCTAssertTrue(block.contains("<<'\(RemoteSettings.combinedDelimiter)'"), "a quoted delimiter: no expansion")
    }

    // MARK: - The model

    private func model(_ server: Server, machine: RemoteMachine) -> RemoteMachinesModel {
        let host = RemoteMachinesModel.Host(
            machines: { [machine] }, state: { _ in nil }, sessionCounts: { [:] },
            add: { _ in .failure(.empty) }, remove: { _ in }, isStored: { true })
        return RemoteMachinesModel(host: host, installer: RemoteInstaller(sshPath: server.ssh),
                                   pasteboard: pasteboard, lang: "en")
    }

    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: 20)
    }

    func testOpeningAMachineReadsItOnceUnderItsLock() throws {
        let server = try self.server("/bin/sh")
        try seed(.claude, existing, in: server)
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        XCTAssertEqual(server.sshRuns, 0, "building the model reads nothing")
        XCTAssertEqual(model.items(for: "m"), .unknown)
        XCTAssertNil(model.combinedBlock(for: "m"), "no reading, no block")

        model.open("m")
        XCTAssertEqual(model.readings["m"], .reading)
        XCTAssertFalse(model.canRun("m"), "a read holds the machine's lock")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(server.sshRuns, 1)
        XCTAssertEqual(model.items(for: "m"), .init(agents: [.claude: .missing, .codex: .notFound,
                                                             .antigravity: .notFound], command: .missing))
        XCTAssertTrue(model.canRun("m"))

        let block = try XCTUnwrap(model.combinedBlock(for: "m"))
        XCTAssertFalse(block.isSecret, "nothing in it is a secret")
        XCTAssertTrue(RemoteMachinesModel.keys.contains(block.captionKey))
    }

    func testACheckWhileAJobRunsIsSkippedAndTheJobReadsTheMachineOnce() throws {
        let server = try self.server("/bin/sh")
        try seed(.claude, nil, in: server)
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").agents[.claude], .missing)

        model.run(.install(.claude))
        let runs = server.sshRuns
        model.check("m")
        model.open("m")
        XCTAssertNotEqual(model.readings["m"], .reading, "a machine running a job is not read, nor waited for")
        waitUntil("job") { model.outcomes["m"] != nil }
        XCTAssertNotNil(model.readings["m"], "a finished write reads the machine again")
        waitUntil("read again") { model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").agents[.claude], .installed,
                       "the card says what the write left, not unknown")
        // Claude's one read and one write — hooks and usage line together
        // — and the machine's read.
        XCTAssertEqual(server.sshRuns - runs, 3, "the job's own calls and one read")

        model.runCommand(.install)
        waitUntil("command") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").command, .installed, "the command's write reads it again too")
    }

    /// The machine's own Antigravity card: one press makes the shared
    /// hooks folder where the agent is, and the read then says installed.
    func testAntigravitysCardInstallsOnAServerThatHasIt() throws {
        let server = try self.server("/bin/sh")
        try FileManager.default.createDirectory(at: server.file(".gemini/antigravity"), withIntermediateDirectories: true)
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").agents[.antigravity], .missing)
        model.perform(.agent(.antigravity), .install, on: "m")
        XCTAssertEqual(model.working["m"], .agent(.antigravity))
        waitUntil("job") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertEqual(model.outcomes["m"]?.line, "Antigravity: installed")
        XCTAssertEqual(model.items(for: "m").agents[.antigravity], .installed)
        XCTAssertEqual(model.agentRows(for: "m").first { $0.item == .agent(.antigravity) }?.parts.count, 1,
                       "its hooks alone")
    }

    /// The machine's switches: never changed, every agent the server has is
    /// on; turning off an installed one asks first, takes its parts out,
    /// and only then writes the machine's set — never this Mac's.
    func testTurningOffAnInstalledAgentRemovesItThenStoresTheMachinesSet() throws {
        let server = try self.server("/bin/sh")
        try seed(.claude, nil, in: server)
        try folder(.codex, in: server)
        var machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        var written: [[String]?] = []
        let host = RemoteMachinesModel.Host(
            machines: { [machine] }, state: { _ in nil }, sessionCounts: { [:] },
            add: { _ in .failure(.empty) }, remove: { _ in }, isStored: { true },
            setAgents: { _, agents in
                written.append(agents)
                machine.agents = agents
            })
        let model = RemoteMachinesModel(host: host, installer: RemoteInstaller(sshPath: server.ssh),
                                        pasteboard: pasteboard, lang: "en")
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.enabledAgents(of: "m"), [.claude, .codex], "the server's agents; Antigravity is not there")
        XCTAssertEqual(model.agentRows(for: "m").map(\.enabled), [true, true, false])

        model.perform(.agent(.claude), .install, on: "m")
        waitUntil("installed") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").agents[.claude], .installed)

        model.setEnabled(.claude, false, on: "m")
        XCTAssertEqual(model.turningOff["m"], .claude, "installed: the card asks first")
        XCTAssertEqual(written.count, 0)
        model.confirmTurnOff(remove: true, on: "m")
        waitUntil("removed") { !written.isEmpty && model.readings["m"] != .reading }
        XCTAssertEqual(written, [["codex"]], "the server's agents but Claude")
        XCTAssertEqual(model.items(for: "m").agents[.claude], .missing, "its parts went first")
        XCTAssertEqual(model.agentRows(for: "m").first?.enabled, false)

        model.setEnabled(.codex, false, on: "m")
        XCTAssertNil(model.turningOff["m"], "nothing of Evlat's there: off at once")
        XCTAssertEqual(written.last, [])
    }

    func testAMachineThatCannotBeReachedReadsAsUnknown() throws {
        let server = try self.server("/bin/sh", .unreachable)
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.open("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.readings["m"], .unreachable)
        XCTAssertEqual(model.items(for: "m"), .unknown)
        XCTAssertNil(model.combinedBlock(for: "m"))
    }

    func testTheItemsFollowTheReading() throws {
        let server = try self.server("/bin/sh")
        try seed(.claude, oldHook, in: server)
        try folder(.codex, in: server)
        _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
        try Data(RemoteCommand.script.replacingOccurrences(of: "# version \(RemoteCommand.version)\n",
                                                          with: "# version 1\n").utf8).write(to: server.command)
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m"), .init(agents: [.claude: .outdated, .codex: .missing,
                                                             .antigravity: .notFound], command: .outdated,
                                                    offPath: .init(onPath: false, file: ".bashrc", added: false)))
    }
}

extension RemoteReadingTests {
    /// Each agent is one card, by this Mac's unit rule: its hooks and —
    /// for the agent whose status line a server gets — the usage line,
    /// read from its one file, the approval group among its hooks.
    func testEachAgentIsOneCard() throws {
        let hooks = LocalHooks.installing(into: [:], for: .claude, target: .server)
        let unit = try XCTUnwrap(StatusLineRelay.installing(into: hooks, source: .claude))
        func file(_ settings: [String: Any]?) throws -> Result<RemoteSettings.Snapshot, SettingsFile.Failure> {
            let bytes = try settings.map(SettingsFile.encode)
            return .success(RemoteSettings.Snapshot(bytes: bytes, checksum: bytes == nil ? RemoteSettings.absent : "1 1"))
        }
        func agents(_ claude: Result<RemoteSettings.Snapshot, SettingsFile.Failure>,
                    _ codex: Result<RemoteSettings.Snapshot, SettingsFile.Failure> = .failure(.noDirectory),
                    _ antigravity: Result<RemoteSettings.Snapshot, SettingsFile.Failure> = .failure(.noDirectory))
            -> [AgentID: SetupStatus] {
            RemoteMachinesModel.items(.init(files: [.claude: claude, .codex: codex, .antigravity: antigravity],
                                            command: .missing)).agents
        }
        let codex = HookSettings.installing(into: [:], for: .codex)
        let antigravity = AntigravityHooks.installing(into: [:], hooks: Antigravity().hooks)
        XCTAssertEqual(agents(try file(unit), try file(codex), try file(antigravity)),
                       [.claude: .installed, .codex: .installed, .antigravity: .installed],
                       "Antigravity's card on a server is its hooks alone")
        XCTAssertEqual(agents(try file(hooks))[.claude], .outdated, "hooks without the usage line: one press brings it")
        XCTAssertEqual(agents(try file(nil), try file(nil))[.codex], .missing)
        XCTAssertEqual(agents(try file(nil)), [.claude: .missing, .codex: .notFound, .antigravity: .notFound])
        XCTAssertEqual(agents(.success(.init(bytes: Data("{".utf8), checksum: "1 1")))[.claude], .unknown)
        let before = try XCTUnwrap(StatusLineRelay.installing(into: HookSettings.installing(into: [:], for: .claude),
                                                              source: .claude))
        XCTAssertEqual(agents(try file(before))[.claude], .outdated,
                       "a server copy from before the approval group: one press completes it")

        // A usage line changed by hand is not a part: the card reads
        // installed and says why it leaves the line alone.
        let row = RemoteMachinesModel.agentRow(.claude, unit: .state(.init(hooks: .current, relay: .modified)),
                                               target: "devbox", in: "en")
        XCTAssertEqual(row.status, .installed)
        XCTAssertEqual(row.note, L10n.t("setup.agent.usageModified", in: "en"))
        XCTAssertEqual(row.detail, "devbox:~/.claude/settings.json")
        XCTAssertEqual(row.parts.map(\.status), [.installed, .foreign])
        XCTAssertFalse(row.removesRelay)
    }
}

// MARK: - PATH

extension RemoteReadingTests {
    private func pathStatus(_ server: Server, file: StaticString = #filePath, line: UInt = #line) throws -> RemotePath.Status {
        try XCTUnwrap(try reading(server, file: file, line: line).path, "the probe answered", file: file, line: line)
    }

    /// `kararla_hetzner`, root: the command installed in `~/.local/bin`, a
    /// login shell whose PATH has no such folder.
    func testARootLoginWithoutTheFolderOnItsPathIsOffPath() throws {
        for shell in shells {
            let server = try self.server(shell)
            _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
            let reading = try self.reading(server)
            XCTAssertTrue(reading.command.isCurrent, shell)
            XCTAssertEqual(reading.path, .init(onPath: false, file: ".bashrc", added: false), shell)
            let items = RemoteMachinesModel.items(reading)
            XCTAssertEqual(items.command, .installed, shell)
            XCTAssertEqual(items.offPath, reading.path, "\(shell): installed, but not found")
        }
    }

    func testTheStartupFileFollowsTheLoginShell() throws {
        for (login, file) in [("bash", ".bashrc"), ("zsh", ".zshrc"), ("sh", ".profile"), ("fish", ".profile")] {
            for shell in shells {
                let server = try self.server(shell, login: login)
                XCTAssertEqual(try pathStatus(server), .init(onPath: false, file: file, added: false), "\(shell) · \(login)")
            }
        }
    }

    func testEvlatsLineInTheStartupFilePutsItOnPath() throws {
        for shell in shells {
            let server = try self.server(shell, login: "zsh")
            try Data((RemotePath.line + "\n").utf8).write(to: server.file(".zshrc"))
            XCTAssertEqual(try pathStatus(server), .init(onPath: true, file: ".zshrc", added: true), shell)

            // The user's own line, not Evlat's: on PATH, nothing of Evlat's to take back.
            try Data("PATH=\"$HOME/.local/bin/:$PATH\"\n".utf8).write(to: server.file(".zshrc"))
            XCTAssertEqual(try pathStatus(server), .init(onPath: true, file: ".zshrc", added: false), shell)
        }
    }

    func testWhatAStartupFilePrintsDoesNotFoolTheRead() throws {
        for shell in shells {
            let server = try self.server(shell)
            let noise = """
                echo 'Welcome to kararla'
                printf 'x ipath %s\\n' "$HOME/.local/bin"
                printf 'x path 1 1 .bashrc\\n'
                echo 'to stderr' >&2
                printf 'no newline at the end'

                """
            try Data(noise.utf8).write(to: server.file(".bashrc"))
            XCTAssertEqual(try pathStatus(server), .init(onPath: false, file: ".bashrc", added: false), shell)
            try Data((noise + RemotePath.line + "\n" + "printf 'more'\n").utf8).write(to: server.file(".bashrc"))
            XCTAssertEqual(try pathStatus(server), .init(onPath: true, file: ".bashrc", added: true), shell)
        }
    }

    /// A shell that never answers is given up on in `patience` seconds —
    /// its child with it, which would hold the read's pipe open — and says
    /// nothing about the PATH; the rest of the read stands.
    func testAShellThatHangsIsGivenUpOn() throws {
        for body in ["sleep 30", "exec sleep 30", "read line; echo never"] {
            let server = try self.server("/bin/dash", login: "bash", loginBody: body)
            try seed(.claude, oldHook, in: server)
            let started = Date()
            let result = RemoteInstaller.applyRead(target: "fake", ssh: server.ssh, patience: 1)
            XCTAssertLessThan(Date().timeIntervalSince(started), 10, body)
            guard case .success(let reading) = result else { return XCTFail("\(body): \(result)") }
            XCTAssertNotNil(reading.path, body)
            XCTAssertNil(reading.path?.onPath, "\(body): unknown, not off PATH")
            XCTAssertEqual(reading.hooks(.claude), .state(.outdated), body)
            XCTAssertEqual(RemoteMachinesModel.items(reading).offPath, nil, body)
        }
    }

    func testNoLoginShellSaysNothingAboutThePath() throws {
        let server = try self.server("/bin/sh", login: "")
        XCTAssertEqual(try pathStatus(server), .init(onPath: nil, file: ".profile", added: false))
    }

    // MARK: Adding and removing the line

    func testAddingTheLineIsIdempotentBacksUpOnceAndCreatesAMissingFile() throws {
        for shell in shells {
            let server = try self.server(shell)
            let rc = server.file(".bashrc")
            XCTAssertEqual(RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh),
                           .success(.written), shell)
            XCTAssertEqual(bytes(rc), Data((RemotePath.line + "\n").utf8), "\(shell): a missing file is made")
            XCTAssertNil(bytes(server.file(".bashrc.evlat.bak")), "\(shell): nothing to back up")
            XCTAssertEqual(try pathStatus(server), .init(onPath: true, file: ".bashrc", added: true), shell)

            let mine = "alias ll='ls -l'\n"
            try Data(mine.utf8).write(to: rc)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rc.path)
            XCTAssertEqual(RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh),
                           .success(.written), shell)
            XCTAssertEqual(bytes(rc), Data((mine + RemotePath.line + "\n").utf8), shell)
            XCTAssertEqual(try mode(rc), 0o600, "\(shell): the file keeps its mode")
            XCTAssertEqual(bytes(server.file(".bashrc.evlat.bak")), Data(mine.utf8), "\(shell): the first backup")

            let before = try tree(server.home)
            XCTAssertEqual(RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh),
                           .success(.unchanged), "\(shell): already there")
            XCTAssertEqual(try tree(server.home), before, "\(shell): nothing written the second time")

            try Data(("# changed\n" + mine).utf8).write(to: rc)
            _ = RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh)
            XCTAssertEqual(bytes(server.file(".bashrc.evlat.bak")), Data(mine.utf8), "\(shell): the backup is kept")
        }
    }

    func testAStartupFileThatChangedSinceItWasReadIsLeftAlone() throws {
        for shell in shells {
            let server = try self.server(shell)
            try Data("a\n".utf8).write(to: server.file(".bashrc"))
            let theirs = Data("a\nb\n".utf8)
            let result = RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh,
                                               beforeWrite: { try? theirs.write(to: server.file(".bashrc")) })
            XCTAssertEqual(result, .failure(.file(.changedUnderneath)), shell)
            XCTAssertEqual(bytes(server.file(".bashrc")), theirs, shell)
        }
    }

    func testRemovingTheCommandTakesOnlyEvlatsLine() throws {
        let server = try self.server("/bin/sh")
        let theirs = "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        try Data(theirs.utf8).write(to: server.file(".bashrc"))
        _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
        _ = RemoteInstaller.apply(.pathLine(".bashrc"), .install, target: "fake", ssh: server.ssh)
        XCTAssertEqual(bytes(server.file(".bashrc")), Data((theirs + RemotePath.line + "\n").utf8))

        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        XCTAssertEqual(model.items(for: "m").command, .installed)
        XCTAssertEqual(model.pathLineToRemove(for: "m"), ".bashrc", "the removal's consent names the file")
        model.perform(.command, .remove, on: "m")
        waitUntil("removed") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.command.path))
        XCTAssertEqual(bytes(server.file(".bashrc")), Data(theirs.utf8), "the user's own PATH line stays")
        XCTAssertEqual(model.outcomes["m"]?.trouble, false, model.outcomes["m"]?.line ?? "")
    }

    func testAddToPathFromTheModelThenTheRowSaysInstalled() throws {
        let server = try self.server("/bin/sh")
        let machine = try XCTUnwrap(RemoteMachine(id: "m", target: "fake"))
        let model = model(server, machine: machine)
        model.check("m")
        waitUntil("read") { model.readings["m"] != .reading }
        model.runCommand(.install)
        waitUntil("installed") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.file(".bashrc").path),
                       "installing the command writes no startup file")
        XCTAssertEqual(model.items(for: "m").offPath?.file, ".bashrc", "the row says: not on PATH")

        model.addToPath("m")
        waitUntil("added") { model.outcomes["m"] != nil && model.readings["m"] != .reading }
        XCTAssertEqual(model.outcomes["m"]?.trouble, false, model.outcomes["m"]?.line ?? "")
        XCTAssertNil(model.items(for: "m").offPath, "a new login shell finds it")
        XCTAssertEqual(model.items(for: "m").command, .installed)
        XCTAssertEqual(bytes(server.file(".bashrc")), Data((RemotePath.line + "\n").utf8))
    }

    // MARK: The one block's PATH part

    func testTheBlocksPathPartWritesNothingWhenThePathAlreadyHasTheFolder() throws {
        for shell in shells {
            let server = try self.server(shell)
            let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all))
            XCTAssertTrue(block.contains(RemotePath.line), shell)
            let path = server.home.appendingPathComponent(RemotePath.directory).path + ":" + Self.rootPath
            XCTAssertEqual(try paste(shell, block, home: server.home, loginShell: server.shell, path: path).status, 0, shell)
            XCTAssertNil(bytes(server.file(".bashrc")), "\(shell): the user's PATH has it: no file is written")
            XCTAssertEqual(bytes(server.command), Data(RemoteCommand.script.utf8), "\(shell): the command is written")
        }
    }

    func testTheBlocksPathPartAddsNoSecondLine() throws {
        for shell in shells {
            let server = try self.server(shell, login: "zsh")
            try Data((RemotePath.line + "\n").utf8).write(to: server.file(".zshrc"))
            let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all))
            // The shell the user pastes into has not read the file yet.
            XCTAssertEqual(try paste(shell, block, home: server.home, loginShell: server.shell).status, 0, shell)
            XCTAssertEqual(bytes(server.file(".zshrc")), Data((RemotePath.line + "\n").utf8), shell)
            XCTAssertNil(bytes(server.file(".zshrc.evlat.bak")), shell)
        }
    }

    func testTheBlockAddsThePathForACommandAlreadyInstalled() throws {
        for shell in shells {
            let server = try self.server(shell, login: "sh")
            _ = RemoteInstaller.applyCommand(.install, target: "fake", ssh: server.ssh)
            let block = try XCTUnwrap(RemoteSettings.combinedScript(try reading(server), agents: Agents.all),
                                      "\(shell): the command is current, the PATH is not")
            XCTAssertFalse(block.contains(RemoteCommand.marker), "\(shell): no command part")
            XCTAssertEqual(try paste(shell, block, home: server.home, loginShell: server.shell).status, 0, shell)
            XCTAssertEqual(bytes(server.file(".profile")), Data((RemotePath.line + "\n").utf8), shell)
            XCTAssertNil(RemoteSettings.combinedScript(try reading(server), agents: Agents.all), "\(shell): nothing left")
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
