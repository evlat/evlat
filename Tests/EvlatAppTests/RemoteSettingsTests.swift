import XCTest
@testable import EvlatCore
@testable import EvlatAgents
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

    private func claude(_ home: URL) -> URL { Claude().hooksFile(home: home)! }
    private func codex(_ home: URL) -> URL { Codex().hooksFile(home: home)! }

    /// The same file in both homes.
    private func seed(_ source: some Agent, _ text: String?, mode: Int = 0o644) throws {
        for home in [remote!, local!] {
            try FileManager.default.createDirectory(at: source.hooksFile(home: home)!.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard let text else { continue }
            let file = source.hooksFile(home: home)!
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
                XCTAssertEqual(try LocalHooks.install(at: claude(local), for: .claude), .written)
                XCTAssertEqual(bytes(claude(remote)), bytes(claude(local)), "\(shell): \(text ?? "no file")")
                XCTAssertEqual(bytes(backup(claude(remote))), bytes(backup(claude(local))), "\(shell): backup")

                XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .success(.written), shell)
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
            XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .success(.written))
            XCTAssertEqual(apply(.statusLine(.claude), .remove, ssh: ssh), .success(.written))
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
            XCTAssertFalse(FileManager.default.fileExists(atPath: Claude().hooksFile(home: remote)!.deletingLastPathComponent().path))
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
                atPath: Claude().hooksFile(home: remote)!.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
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
            XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .success(.written))
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
            XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(bytes(claude(remote)), before)
            XCTAssertNil(bytes(backup(claude(remote))), "\(shell): not even a backup")
        }
    }

    func testTheStatusLineBackupIsWrittenInTheSameCall() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, existing)
            let runs = sshRuns
            XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .success(.written), shell)
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
            XCTAssertEqual(apply(.statusLine(.claude), .remove, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(apply(.statusLine(.claude), .install, ssh: ssh), .failure(.file(.malformed)), shell)
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
            XCTAssertFalse(installer.run([.statusLine(.claude)], .install, machine: "m", target: "fake") { _ in
                XCTFail("a second job on the same machine is refused")
            })
            wait(for: [done], timeout: 20)
            XCTAssertEqual(results.map(\.0), [.hooks(.claude), .hooks(.codex)])
            XCTAssertEqual(results.map(\.1), [.success(.written), .failure(.file(.noDirectory))], shell)
            XCTAssertFalse(installer.isBusy("m"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: Codex().hooksFile(home: remote)!.deletingLastPathComponent().path))
        }
    }

    /// The local writer's bytes, with what a server gets that this Mac
    /// does not: Codex's approval group (`ApprovalChannel.installs`).
    func testCodexHooksAreWrittenLikeTheLocalOnes() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.codex, nil)
            XCTAssertEqual(apply(.hooks(.codex), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try SettingsFile.apply(at: codex(local)) {
                LocalHooks.installing(into: $0, for: .codex, target: .server)
            }, .written)
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
            let file = Antigravity().hooksFile(home: remote)!
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .state(.missing), "\(shell): the agent is there, its hooks are not")
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try LocalHooks.install(at: Antigravity().hooksFile(home: local)!,
                                                  for: .antigravity), .written)
            XCTAssertEqual(bytes(file), bytes(Antigravity().hooksFile(home: local)!), shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .state(.current), shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(apply(.hooks(.antigravity), .remove, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try LocalHooks.state(at: file, for: .antigravity), .missing, shell)
        }
    }

    /// Claude's card on a server is one write of its one file: the hooks
    /// (the approval group among them) and the usage line, the user's status line
    /// wrapped and kept aside — the read then says the unit is current —
    /// and one removal takes both out, the status line back as it was.
    func testClaudesUnitIsOneWriteOfHooksAndUsageLine() throws {
        let original = #"{"statusLine":{"type":"command","command":"bash ~/.claude/line.sh","padding":0}}"#
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seed(.claude, original)
            let before = sshRuns
            XCTAssertEqual(apply(.agent(.claude), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(sshRuns - before, 2, "\(shell): one read, one write")
            let reading = try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get()
            XCTAssertEqual(reading.unit(.claude), .state(.init(hooks: .current, relay: .current)), shell)
            let settings = try SettingsFile.read(claude(remote))
            XCTAssertEqual(ApprovalHook.state(of: settings, for: Claude().approvals!), .current,
                           "\(shell): the server's Claude asks the bar too")
            XCTAssertNotNil(bytes(statusBackup(claude(remote))), "\(shell): the status line it wrapped is kept")
            XCTAssertEqual(apply(.agent(.claude), .install, ssh: ssh), .success(.unchanged), shell)

            XCTAssertEqual(apply(.agent(.claude), .remove, ssh: ssh), .success(.written), shell)
            let removed = try SettingsFile.read(claude(remote))
            XCTAssertEqual(LocalHooks.state(of: removed, for: .claude, target: .server), .missing, shell)
            XCTAssertEqual((removed["statusLine"] as? [String: Any])?["command"] as? String,
                           "bash ~/.claude/line.sh", "\(shell): the user's command is back")
        }
    }

    /// Antigravity's card on a server is its hooks alone: no usage line is
    /// installed there (unmeasured). The folder is made where the agent is.
    func testAntigravitysUnitIsItsHooksAlone() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try FileManager.default.createDirectory(at: remote.appendingPathComponent(".gemini/antigravity-cli"),
                                                    withIntermediateDirectories: true)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.antigravity),
                           .state(.init(hooks: .missing, relay: nil)), shell)
            XCTAssertEqual(apply(.agent(.antigravity), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.antigravity),
                           .state(.init(hooks: .current, relay: nil)), shell)
            let cli = remote.appendingPathComponent(".gemini/antigravity-cli/settings.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cli.path), "\(shell): no relay on a server")
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
            try FileManager.default.createDirectory(at: Antigravity().hooksFile(home: remote)!.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            XCTAssertEqual(apply(.hooks(.antigravity), .install, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: Antigravity().hooksFile(home: remote)!.path))
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().hooks(.antigravity),
                           .noDirectory, shell)
        }
    }

    // MARK: - A file of Evlat's own (OpenCode's plugin)

    private var plugin: OwnedFile { OpenCodePlugin.file }
    private func opencode(_ home: URL) -> URL { OpenCode().unitFile(home: home) }

    /// An OpenCode on the server (and on the local writer's home, for the
    /// comparison): its config folder, the plugin folder not made yet.
    private func opencodeIsThere(_ homes: [URL]) throws {
        for home in homes {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(OpenCode().presence[0]),
                                                    withIntermediateDirectories: true)
        }
    }

    private func entries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// The unit is one file written whole, the same bytes this Mac's writer
    /// writes, in one read and one write, with no backup and no temporary
    /// file left; the folder is made because the agent is there.
    func testOpenCodesPluginIsWrittenLikeTheLocalOnes() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote, local])
            let file = opencode(remote)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .missing, relay: nil)), "\(shell): the agent is there, its file is not")

            let before = sshRuns
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(sshRuns - before, 2, "\(shell): one read, one write")
            try AgentIntegration.install(home: local, for: OpenCode())
            XCTAssertEqual(bytes(file), bytes(opencode(local)), shell)
            XCTAssertEqual(bytes(file), Data(plugin.contents.utf8), shell)
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["evlat.js"],
                           "\(shell): no backup, no temporary file")
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .current, relay: nil)), shell)

            let again = sshRuns
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(sshRuns - again, 1, "\(shell): the read only, no write call")
        }
    }

    /// An older copy of Evlat's file is moved whole, with no backup of it,
    /// and what sits beside it is left as it is.
    func testAnOlderPluginIsReplacedWholeWithNoBackup() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote])
            let file = opencode(remote)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let older = plugin.contents.replacingOccurrences(of: "\(plugin.versionPrefix)\(plugin.version)\n",
                                                             with: "\(plugin.versionPrefix)\(plugin.version - 1)\n")
            XCTAssertNotEqual(older, plugin.contents)
            try Data(older.utf8).write(to: file)
            let neighbour = file.deletingLastPathComponent().appendingPathComponent("mine.js")
            try Data("export default {}\n".utf8).write(to: neighbour)

            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .outdated, relay: nil)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(bytes(file), Data(plugin.contents.utf8), shell)
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["evlat.js", "mine.js"], shell)
            XCTAssertEqual(bytes(neighbour), Data("export default {}\n".utf8), shell)
        }
    }

    /// A file at the path that does not carry Evlat's marker is the user's:
    /// read as foreign, refused on an install, and a removal leaves it.
    func testAFileOfTheUsersAtThePluginsPathIsNeverWrittenOverOrRemoved() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote])
            let file = opencode(remote)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let theirs = Data("// mine\nexport default {}\n".utf8)
            try theirs.write(to: file)

            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .missing, relay: nil, foreign: true)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .remove, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(bytes(file), theirs, shell)
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["evlat.js"], "\(shell): nothing else made")
        }
    }

    /// The removal takes the one marked file: the folder and what sits
    /// beside it stay, and a second removal has nothing to do.
    func testRemovingThePluginTakesOnlyTheFile() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote])
            let file = opencode(remote)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .success(.written), shell)
            let neighbour = file.deletingLastPathComponent().appendingPathComponent("mine.js")
            try Data("export default {}\n".utf8).write(to: neighbour)

            let before = sshRuns
            XCTAssertEqual(apply(.agent(.opencode), .remove, ssh: ssh), .success(.written), shell)
            XCTAssertEqual(sshRuns - before, 2, "\(shell): one read, one write")
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["mine.js"], shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .missing, relay: nil)), shell)
            let again = sshRuns
            XCTAssertEqual(apply(.agent(.opencode), .remove, ssh: ssh), .success(.unchanged), shell)
            XCTAssertEqual(sshRuns - again, 1, shell)
            XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent(OpenCode().presence[0]).path),
                          "\(shell): the agent's own folder stays")
        }
    }

    /// Without the agent on the server nothing is made, and a folder of the
    /// plugins' kind that another tool left does not say the agent is there.
    func testThePluginsFolderIsNotMadeWhereOpenCodeIsNot() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .remove, ssh: ssh), .failure(.file(.noDirectory)), shell)
            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .noDirectory, shell)
            XCTAssertEqual(entries(remote), [], "\(shell): nothing is made")
        }
    }

    /// The write is refused when the file is not the one that was read: a
    /// file that appeared, one that changed — and a removal's too.
    func testAPluginPathThatChangedAfterTheReadIsKept() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote])
            let file = opencode(remote)
            let theirs = Data("// mine\n".utf8)
            let appeared = apply(.agent(.opencode), .install, ssh: ssh) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? theirs.write(to: file)
            }
            XCTAssertEqual(appeared, .failure(.file(.changedUnderneath)), shell)
            XCTAssertEqual(bytes(file), theirs, "\(shell): theirs is kept")

            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .success(.written), shell)
            let edited = Data("// mine now\n".utf8)
            let removed = apply(.agent(.opencode), .remove, ssh: ssh) { try? edited.write(to: file) }
            XCTAssertEqual(removed, .failure(.file(.changedUnderneath)), shell)
            XCTAssertEqual(bytes(file), edited, "\(shell): the file that changed is kept")
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["evlat.js"], "\(shell): no temporary file stays")
        }
    }

    /// A link at the path is the user's, as it is on this Mac: read as
    /// foreign, never written through and never removed, whatever the file
    /// at its end holds — even Evlat's own bytes.
    func testALinkAtThePluginsPathIsTheUsersAndIsNeverFollowed() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try opencodeIsThere([remote])
            let file = opencode(remote)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = remote.appendingPathComponent("dotfiles-evlat.js")
            let older = plugin.contents.replacingOccurrences(of: "\(plugin.versionPrefix)\(plugin.version)\n",
                                                             with: "\(plugin.versionPrefix)\(plugin.version - 1)\n")
            try Data(older.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "../../../dotfiles-evlat.js")

            XCTAssertEqual(try RemoteInstaller.applyRead(target: "fake", ssh: ssh).get().unit(.opencode),
                           .state(.init(hooks: .missing, relay: nil, foreign: true)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .install, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(apply(.agent(.opencode), .remove, ssh: ssh), .failure(.file(.malformed)), shell)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path),
                           "../../../dotfiles-evlat.js", "\(shell): the link stays")
            XCTAssertEqual(bytes(target), Data(older.utf8), "\(shell): its target is not written")
            XCTAssertEqual(entries(file.deletingLastPathComponent()), ["evlat.js"], "\(shell): nothing else made")

            // A link that appears after the read ends the write: it is not the file that was read.
            try FileManager.default.removeItem(at: file)
            let appeared = apply(.agent(.opencode), .install, ssh: ssh) {
                try? FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "../../../dotfiles-evlat.js")
            }
            XCTAssertEqual(appeared, .failure(.file(.malformed)), shell)
            XCTAssertEqual(bytes(target), Data(older.utf8), "\(shell): its target is not written")
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
        installer.runCommand(.install, machine: "m", target: "fake",
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
            XCTAssertEqual(try LocalHooks.install(at: claude(local), for: .claude), .written)
            XCTAssertEqual(bytes(claude(remote)), bytes(claude(local)), shell)
        }
    }

    // MARK: - By hand

    func testTheManualBlocksAreTheLocalWritersBytes() throws {
        _ = try setUp(shell: "/bin/sh")
        try seed(.claude, nil)
        try seed(.codex, nil)
        try LocalHooks.install(at: claude(local), for: .claude)
        XCTAssertEqual(Data(RemoteSettings.manual(agents: Agents.all).hooks(for: .claude).utf8), bytes(claude(local)))
        try SettingsFile.apply(at: codex(local)) { LocalHooks.installing(into: $0, for: .codex, target: .server) }
        XCTAssertEqual(Data(RemoteSettings.manual(agents: Agents.all).hooks(for: .codex).utf8), bytes(codex(local)))
        try FileManager.default.removeItem(at: claude(local))
        try StatusLineRelay.install(at: claude(local), source: .claude)
        XCTAssertEqual(Data(RemoteSettings.manual(agents: Agents.all).statusLine.utf8), bytes(claude(local)))
        XCTAssertEqual(RemoteSettings.manual(agents: Agents.all).wrapping,
                       StatusLineRelay.command(wrapping: RemoteSettings.Manual.placeholder, source: .claude))
        XCTAssertTrue(RemoteSettings.manual(agents: Agents.all).hooks(for: .claude).contains(RemoteSettings.manual(agents: Agents.all).marker))
        XCTAssertTrue(RemoteSettings.manual(agents: Agents.all).statusLine.contains(RemoteSettings.manual(agents: Agents.all).marker))
    }

    /// The wrapper a user pastes runs under dash, both as the runner's shell
    /// and as the `sh` it calls: the original's output and status come
    /// through. `HOME` is the test's own folder, where no socket is, so no
    /// live Evlat hears it.
    func testTheWrapperRunsUnderDash() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path,
                                                   withDestinationPath: "/bin/dash")
        for (original, output, status) in [("printf ok", "ok", Int32(0)), ("cat; exit 3", "in", Int32(3))] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/dash")
            process.arguments = ["-c", StatusLineRelay.command(wrapping: original, source: .claude)]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": directory.path]
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
