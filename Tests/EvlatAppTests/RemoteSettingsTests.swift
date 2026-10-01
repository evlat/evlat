import XCTest
@testable import EvlatCore
@testable import EvlatApp

/// The remote writer end to end against a **fake `ssh`** that runs the script
/// it is handed with `HOME` set to a temporary "server" home, under `/bin/sh`
/// and under `/bin/dash` (Debian's `sh`). The real `ssh` is never run, and no
/// real `~/.claude` or `~/.codex` is read or written: both homes here — the
/// server's and the local writer's it is compared with — are temporary.
final class RemoteSettingsTests: XCTestCase {
    private var directory: URL!
    /// The server's `$HOME`.
    private var remote: URL!
    /// The local writer's home, for byte-for-byte comparisons.
    private var local: URL!

    private let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-remote-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(shells.contains("/bin/dash"), "dash is the shell a Debian server's sh is")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private enum Mode {
        case run
        /// A login script that prints before the command runs.
        case banner
        /// How `ssh` fails to connect.
        case unreachable
    }

    /// Fresh homes and a fake for `shell`.
    private func setUp(shell: String, mode: Mode = .run) throws -> String {
        let run = directory.appendingPathComponent(UUID().uuidString)
        remote = run.appendingPathComponent("remote")
        local = run.appendingPathComponent("local")
        for home in [remote!, local!] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        let script = run.appendingPathComponent("fake-ssh")
        let body: String
        switch mode {
        case .run: body = "HOME='\(remote.path)' exec \(shell) -s"
        case .banner: body = "echo 'Welcome to devbox'\nprintf 'x absent\\n'\nHOME='\(remote.path)' exec \(shell) -s"
        case .unreachable: body = "echo 'ssh: connect to host fake port 22: Connection refused' >&2\nexit 255"
        }
        try """
            #!/bin/sh
            echo run >> '\(run.appendingPathComponent("runs").path)'
            { echo '--- run'; printf '%s\\n' "$@"; } >> '\(run.appendingPathComponent("args").path)'
            \(body)

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private var sshRuns: Int {
        let log = remote.deletingLastPathComponent().appendingPathComponent("runs")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func claude(_ home: URL) -> URL { AgentSource.claude.settingsFile(home: home) }
    private func codex(_ home: URL) -> URL { AgentSource.codex.settingsFile(home: home) }

    /// The same file in both homes.
    private func seed(_ source: AgentSource, _ text: String?, mode: Int = 0o644) throws {
        for home in [remote!, local!] {
            try FileManager.default.createDirectory(at: source.configDirectory(home: home),
                                                    withIntermediateDirectories: true)
            guard let text else { continue }
            let file = source.settingsFile(home: home)
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    private func apply(_ change: RemoteSettings.Change, _ action: RemoteSettings.Action, ssh: String,
                       beforeWrite: () -> Void = {}) -> RemoteInstaller.Result {
        RemoteInstaller.apply(change, action, target: "fake", ssh: ssh, beforeWrite: beforeWrite)
    }

    private func bytes(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func backup(_ url: URL) -> URL { url.appendingPathExtension("evlat.bak") }
    private func statusBackup(_ url: URL) -> URL { url.appendingPathExtension("statusline.evlat.bak") }

    private let existing = #"""
        {
          "model" : "opus",
          "hooks" : { "PreToolUse" : [ { "matcher" : "*", "hooks" : [ { "type" : "command", "command" : "/usr/local/bin/other notify" } ] } ] },
          "statusLine" : { "type" : "command", "command" : "bash ~/.claude/it's.sh", "padding" : 0 }
        }
        """#

    // MARK: - Same bytes as the local writer

    func testAnInstallWritesTheLocalWritersBytes() throws {
        for shell in shells {
            for text in [nil, "", existing] {
                let ssh = try setUp(shell: shell)
                try seed(.claude, text)
                XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written), shell)
                XCTAssertEqual(try HookSettings.install(at: claude(local), for: .claude), .written)
                XCTAssertEqual(bytes(claude(remote)), bytes(claude(local)), "\(shell): \(text ?? "no file")")
                XCTAssertEqual(bytes(backup(claude(remote))), bytes(backup(claude(local))), "\(shell): backup")

                XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .success(.written), shell)
                XCTAssertEqual(try StatusLineRelay.install(at: claude(local), source: .claude), .written)
                XCTAssertEqual(bytes(claude(remote)), bytes(claude(local)), "\(shell): statusLine")
                XCTAssertEqual(bytes(statusBackup(claude(remote))), bytes(statusBackup(claude(local))),
                               "\(shell): the statusLine backup")
            }
        }
    }

    func testRemovingGivesTheOriginalBack() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing)
            let original = try XCTUnwrap(bytes(claude(remote)))
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written))
            XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .success(.written))
            XCTAssertEqual(apply(.statusLine, .remove, ssh: ssh), .success(.written))
            XCTAssertEqual(apply(.hooks(.claude), .remove, ssh: ssh), .success(.written))
            let back = try JSONSerialization.jsonObject(with: try XCTUnwrap(bytes(claude(remote))))
            let before = try JSONSerialization.jsonObject(with: original)
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(back as? [String: Any]))
                .isEqual(to: try XCTUnwrap(before as? [String: Any])), shell)
            XCTAssertEqual(bytes(backup(claude(remote))), original, "\(shell): the first backup is the original")
        }
    }

    // MARK: - Guarantees

    func testASecondInstallWritesNothing() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing)
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written))
            let file = bytes(claude(remote)), saved = bytes(backup(claude(remote)))
            let stamp = try FileManager.default.attributesOfItem(atPath: claude(remote).path)[.modificationDate] as? Date
            let runs = sshRuns
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(sshRuns, runs + 1, "\(shell): the read only, no write call")
            XCTAssertEqual(bytes(claude(remote)), file)
            XCTAssertEqual(bytes(backup(claude(remote))), saved)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: claude(remote).path)[.modificationDate]
                as? Date, stamp)
        }
    }

    func testAMissingDirectoryIsNotCreated() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.claude.configDirectory(home: remote).path))
        }
    }

    func testAFileThatChangedAfterTheReadIsKept() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing)
            let theirs = Data(#"{"model":"sonnet"}"#.utf8)
            let result = apply(.hooks(.claude), .install, ssh: ssh) {
                try? theirs.write(to: self.claude(self.remote))
            }
            XCTAssertEqual(result, .failure(.file(.changedUnderneath)), shell)
            XCTAssertEqual(bytes(claude(remote)), theirs, "\(shell): theirs is kept")
            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: AgentSource.claude.configDirectory(home: remote).path).filter { $0.hasSuffix(".tmp") }
            XCTAssertEqual(leftovers, [], "\(shell): no temporary file stays")
        }
    }

    /// A file that appears after a read that found none is someone's too.
    func testAFileThatAppearedAfterTheReadIsKept() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, nil)
            let theirs = Data("{}".utf8)
            let result = apply(.hooks(.claude), .install, ssh: ssh) { try? theirs.write(to: self.claude(self.remote)) }
            XCTAssertEqual(result, .failure(.file(.changedUnderneath)), shell)
            XCTAssertEqual(bytes(claude(remote)), theirs)
        }
    }

    func testTheFirstBackupKeepsTheModeAndIsTakenOnce() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing, mode: 0o600)
            let original = bytes(claude(remote))
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written))
            XCTAssertEqual(bytes(backup(claude(remote))), original, shell)
            XCTAssertEqual(try mode(backup(claude(remote))), 0o600, shell)
            XCTAssertEqual(try mode(claude(remote)), 0o600, "\(shell): a 0600 file stays 0600")
            XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .success(.written))
            XCTAssertEqual(bytes(backup(claude(remote))), original, "\(shell): taken once")
            XCTAssertEqual(try mode(claude(remote)), 0o600)
            XCTAssertEqual(try mode(statusBackup(claude(remote))), 0o600)
        }
    }

    func testALinkedFileIsWrittenAtItsTargetAndStaysALink() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, nil)
            let dotfiles = remote.appendingPathComponent("dotfiles")
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let target = dotfiles.appendingPathComponent("claude.json")
            try Data(existing.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: claude(remote).path,
                                                       withDestinationPath: "../dotfiles/claude.json")
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claude(remote).path),
                           "../dotfiles/claude.json", "\(shell): the link stays")
            XCTAssertEqual(try HookSettings.state(at: target, for: .claude), .current, shell)
            XCTAssertEqual(bytes(backup(claude(remote))), Data(existing.utf8), "\(shell): backed up from the target")
        }
    }

    func testADanglingLinkIsRefused() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, nil)
            try FileManager.default.createSymbolicLink(atPath: claude(remote).path,
                                                       withDestinationPath: remote.appendingPathComponent("gone.json").path)
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .failure(.file(.unreadable)), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("gone.json").path))
        }
    }

    func testBrokenJSONIsNotWrittenOver() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, #"{"model": "opus",,}"#)
            let before = bytes(claude(remote))
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(bytes(claude(remote)), before)
            XCTAssertNil(bytes(backup(claude(remote))), "\(shell): not even a backup")
        }
    }

    func testTheStatusLineBackupIsWrittenInTheSameCall() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing)
            let runs = sshRuns
            XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(sshRuns, runs + 2, "\(shell): one read, one write")
            let saved = try JSONSerialization.jsonObject(with: try XCTUnwrap(bytes(statusBackup(claude(remote)))))
            XCTAssertEqual((saved as? [String: Any])?["command"] as? String, "bash ~/.claude/it's.sh", shell)
        }
    }

    func testAModifiedWrapperIsNotTakenApart() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            let modified = StatusLineRelay.command(wrapping: "bash s.sh", source: .claude) + " # mine"
            let text = String(decoding: try SettingsFile.encode(["statusLine": ["type": "command", "command": modified]]),
                              as: UTF8.self)
            try seed(.claude, text)
            XCTAssertEqual(apply(.statusLine, .remove, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(apply(.statusLine, .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(bytes(claude(remote)), Data(text.utf8))
        }
    }

    func testCodexIsSkippedWhenItsDirectoryIsMissing() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, nil)
            let installer = RemoteInstaller(sshPath: ssh)
            let done = expectation(description: "done")
            var results: [(RemoteSettings.Change, RemoteInstaller.Result)] = []
            XCTAssertTrue(installer.run([.hooks(.claude), .hooks(.codex)], .install, machine: "m", target: "fake") {
                results = $0
                done.fulfill()
            })
            XCTAssertFalse(installer.run([.statusLine], .install, machine: "m", target: "fake") { _ in
                XCTFail("a second job on the same machine is refused")
            })
            wait(for: [done], timeout: 20)
            XCTAssertEqual(results.map(\.0), [.hooks(.claude), .hooks(.codex)])
            XCTAssertEqual(results.map(\.1), [.success(.written), .failure(.file(.noDirectory))], shell)
            XCTAssertFalse(installer.isBusy("m"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.codex.configDirectory(home: remote).path))
        }
    }

    func testCodexHooksAreWrittenLikeTheLocalOnes() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.codex, nil)
            XCTAssertEqual(apply(.hooks(.codex), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try HookSettings.install(at: codex(local), for: .codex), .written)
            XCTAssertEqual(bytes(codex(remote)), bytes(codex(local)), shell)
        }
    }

    /// Antigravity's hooks folder is shared and need not exist; on a server
    /// where the agent is (its CLI's folder), the install makes it, as this
    /// Mac's writer does, with the same bytes — and the machine's read then
    /// finds the hooks current.
    func testAntigravitysHooksFolderIsMadeWhereTheAgentIs() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            for home in [remote!, local!] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"),
                                                        withIntermediateDirectories: true)
            }
            let file = AgentSource.antigravity.settingsFile(home: remote)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .state(.missing), "\(shell): the agent is there, its hooks are not")
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try LocalHooks.install(at: AgentSource.antigravity.settingsFile(home: local),
                                                  for: .antigravity), .written)
            XCTAssertEqual(bytes(file), bytes(AgentSource.antigravity.settingsFile(home: local)), shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .state(.current), shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .remove, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try LocalHooks.state(at: file, for: .antigravity), .missing, shell)
        }
    }

    /// Without the agent on the server nothing is made: the folder's
    /// absence still says Antigravity is not there.
    func testAntigravitysHooksFolderIsNotMadeWhereTheAgentIsNot() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .remove, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent(".gemini").path), shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .noDirectory, shell)
            // A shared folder left behind does not say the agent is there.
            try FileManager.default.createDirectory(at: AgentSource.antigravity.configDirectory(home: remote),
                                                    withIntermediateDirectories: true)
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.antigravity.settingsFile(home: remote).path))
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .noDirectory, shell)
        }
    }

    func testSSHsOwnFailureIsUnreachable() throws {
        let ssh = try setUp(shell: "/bin/sh", mode: .unreachable)
        let installer = RemoteInstaller(sshPath: ssh)
        let done = expectation(description: "done")
        var results: [RemoteInstaller.Result] = []
        installer.run([.hooks(.claude), .hooks(.codex)], .install, machine: "m", target: "fake") {
            results = $0.map(\.1)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(results, [.failure(.unreachable), .failure(.unreachable)])
        XCTAssertEqual(sshRuns, 1, "the rest are not tried")
    }

    /// Every call of a job goes through the socket it is handed — the
    /// tunnel's master, so the server sees no new login — and without one is
    /// a connection of its own, as before.
    func testAJobRidesTheMasterItIsHanded() throws {
        let ssh = try setUp(shell: "/bin/sh")
        try seed(.claude, nil)
        let installer = RemoteInstaller(sshPath: ssh)
        let socket = "/tmp/e/21580954"
        var done = expectation(description: "write")
        installer.run([.hooks(.claude)], .install, machine: "m", target: "fake", controlPath: socket) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        done = expectation(description: "command")
        installer.runCommand(.install, key: String(repeating: "a", count: 64), machine: "m", target: "fake",
                             controlPath: socket) { _, _ in done.fulfill() }
        wait(for: [done], timeout: 20)
        done = expectation(description: "read")
        installer.read(machine: "m", target: "fake", controlPath: socket) { _ in done.fulfill() }
        wait(for: [done], timeout: 20)
        done = expectation(description: "read without a master")
        installer.read(machine: "m", target: "fake") { _ in done.fulfill() }
        wait(for: [done], timeout: 20)

        let log = remote.deletingLastPathComponent().appendingPathComponent("args")
        let runs = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "--- run\n").dropFirst()
            .map { $0.split(separator: "\n").map(String.init) }
        XCTAssertEqual(runs.count, 5, "read and write, the command, two reads")
        for run in runs.dropLast() {
            XCTAssertEqual(run, RemoteSettings.arguments(target: "fake", controlPath: socket))
        }
        XCTAssertEqual(runs.last, RemoteSettings.arguments(target: "fake"))
    }

    func testALoginBannerDoesNotReachTheFile() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell, mode: .banner)
            try seed(.claude, existing)
            XCTAssertEqual(apply(.hooks(.claude), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try HookSettings.install(at: claude(local), for: .claude), .written)
            XCTAssertEqual(bytes(claude(remote)), bytes(claude(local)), shell)
        }
    }

    // MARK: - By hand

    func testTheManualBlocksAreTheLocalWritersBytes() throws {
        _ = try setUp(shell: "/bin/sh")
        try seed(.claude, nil)
        try seed(.codex, nil)
        try HookSettings.install(at: claude(local), for: .claude)
        XCTAssertEqual(Data(RemoteSettings.manual.hooks(for: .claude).utf8), bytes(claude(local)))
        try HookSettings.install(at: codex(local), for: .codex)
        XCTAssertEqual(Data(RemoteSettings.manual.hooks(for: .codex).utf8), bytes(codex(local)))
        try FileManager.default.removeItem(at: claude(local))
        try StatusLineRelay.install(at: claude(local), source: .claude)
        XCTAssertEqual(Data(RemoteSettings.manual.statusLine.utf8), bytes(claude(local)))
        XCTAssertEqual(RemoteSettings.manual.wrapping,
                       StatusLineRelay.command(wrapping: RemoteSettings.Manual.placeholder, source: .claude))
        XCTAssertTrue(RemoteSettings.manual.hooks(for: .claude).contains(RemoteSettings.manual.marker))
        XCTAssertTrue(RemoteSettings.manual.statusLine.contains(RemoteSettings.manual.marker))
    }

    /// The wrapper a user pastes runs under dash, both as the runner's shell
    /// and as the `sh` it calls: the original's output and status come
    /// through. The port is one nothing listens on, so no live Evlat hears it.
    func testTheWrapperRunsUnderDash() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path,
                                                   withDestinationPath: "/bin/dash")
        for (original, output, status) in [("printf ok", "ok", Int32(0)), ("cat; exit 3", "in", Int32(3))] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/dash")
            process.arguments = ["-c", StatusLineRelay.command(wrapping: original, port: 9, source: .claude)]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data("in".utf8))
            try stdin.fileHandleForWriting.close()
            let printed = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: printed, as: UTF8.self), output, original)
            XCTAssertEqual(process.terminationStatus, status, original)
        }
    }
}
