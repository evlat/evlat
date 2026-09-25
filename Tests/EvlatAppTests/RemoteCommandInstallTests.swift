import XCTest
@testable import EvlatCore
@testable import EvlatApp

/// Installing the server's `evlat` (`013/phase-4`) end to end against a
/// **fake `ssh`** that runs the script it is handed with `HOME` set to a
/// temporary "server" home, under `/bin/sh` and `/bin/dash`, and records its
/// argv. The real `ssh` is never run and no real home is read or written.
///
/// The blocks to paste by hand are held to the same files: run under `sh`
/// in a second temporary home, they leave the automatic install's bytes and
/// modes.
final class RemoteCommandInstallTests: XCTestCase {
    private let key = String(repeating: "c3", count: 32)
    private let otherKey = String(repeating: "7e", count: 32)
    private var root: URL!
    /// The server's `$HOME`.
    private var remote: URL!

    private let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    override func setUpWithError() throws {
        let temporary = realpath(FileManager.default.temporaryDirectory.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent("evlat-remote-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(shells.contains("/bin/dash"), "dash is the shell a Debian server's sh is")
    }

    override func tearDownWithError() throws {
        // A test that took a folder's write bit gives it back first.
        if let remote {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: bin(remote).path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private enum Mode {
        case run
        /// A login script that prints before the command runs.
        case banner
        /// How `ssh` fails to connect.
        case unreachable
        /// A server without `curl`: `PATH` holds only the tools the scripts use.
        case noCurl
    }

    /// A fresh server home and a fake `ssh` for `shell`, under `umask 022`.
    private func setUp(shell: String, mode: Mode = .run) throws -> String {
        let run = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        remote = run.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let fake = run.appendingPathComponent("fake-ssh")
        let exec = "umask 022\nHOME='\(remote.path)' exec \(shell) -s"
        let body: String
        switch mode {
        case .run: body = exec
        case .banner: body = "echo 'Welcome to devbox'\nprintf 'x 1 1\\n'\n\(exec)"
        case .unreachable: body = "echo 'ssh: connect to host fake port 22: Connection refused' >&2\nexit 255"
        case .noCurl:
            let tools = run.appendingPathComponent("tools", isDirectory: true)
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            for tool in ["mkdir", "chmod", "mv", "rm", "rmdir", "cat", "sed", "ls"] {
                let path = ["/bin/\(tool)", "/usr/bin/\(tool)"].first { FileManager.default.isExecutableFile(atPath: $0) }
                try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent(tool).path,
                                                           withDestinationPath: try XCTUnwrap(path, tool))
            }
            body = "PATH='\(tools.path)'\nexport PATH\n\(exec)"
        }
        try """
            #!/bin/sh
            printf '%s\\n' "$@" >> '\(run.appendingPathComponent("argv").path)'
            \(body)

            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return fake.path
    }

    private var argv: String {
        let log = remote.deletingLastPathComponent().appendingPathComponent("argv")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    private func bin(_ home: URL) -> URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    private func command(_ home: URL) -> URL { bin(home).appendingPathComponent("evlat") }
    private func keyFile(_ home: URL) -> URL { home.appendingPathComponent(RemoteCommand.keyPath) }
    private func keyFolder(_ home: URL) -> URL { keyFile(home).deletingLastPathComponent() }

    private func install(_ ssh: String, key: String? = nil) -> RemoteInstaller.CommandResult {
        RemoteInstaller.applyCommand(.install, key: key ?? self.key, target: "fake", ssh: ssh)
    }

    private func remove(_ ssh: String) -> RemoteInstaller.CommandResult {
        RemoteInstaller.applyCommand(.remove, key: key, target: "fake", ssh: ssh)
    }

    private func bytes(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let number = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber])
        return try XCTUnwrap((number as? NSNumber)?.uint64Value)
    }

    private let foreign = "#!/bin/sh\n# somebody else's evlat\necho mine\n"

    private func seedForeign(_ home: URL) throws {
        try FileManager.default.createDirectory(at: bin(home), withIntermediateDirectories: true)
        try Data(foreign.utf8).write(to: command(home))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command(home).path)
    }

    /// `text` on `shell`'s stdin with `HOME` at `home`, under `umask 022`.
    @discardableResult
    private func sh(_ shell: String, _ text: String, home: URL,
                    environment extra: [String: String] = [:]) throws -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 022; exec \"$0\" -s", shell]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        extra.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    // MARK: - Installing

    func testAnInstallWritesTheMarkedCommandAndTheKey() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            XCTAssertEqual(bytes(command(remote)), Data(RemoteCommand.script.utf8), shell)
            XCTAssertEqual(try mode(command(remote)), 0o755, shell)
            XCTAssertEqual(bytes(keyFile(remote)), Data("\(key)\n".utf8), shell)
            XCTAssertEqual(try mode(keyFile(remote)), 0o600, "\(shell): the key, under umask 022")
            XCTAssertEqual(try mode(keyFolder(remote)), 0o700, "\(shell): its folder")
            let left = try FileManager.default.contentsOfDirectory(atPath: bin(remote).path)
                + FileManager.default.contentsOfDirectory(atPath: keyFolder(remote).path)
            XCTAssertEqual(left.sorted(), ["evlat", "signal.token"], "\(shell): no temporary file stays")
        }
    }

    func testALooseKeyFileAndFolderAreTightened() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try FileManager.default.createDirectory(at: keyFolder(remote), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try Data("\(otherKey)\n".utf8).write(to: keyFile(remote))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile(remote).path)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            XCTAssertEqual(bytes(keyFile(remote)), Data("\(key)\n".utf8), shell)
            XCTAssertEqual(try mode(keyFile(remote)), 0o600, shell)
            XCTAssertEqual(try mode(keyFolder(remote)), 0o700, shell)
        }
    }

    func testASecondInstallLeavesTheCommandAndWritesTheKey() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            let first = try inode(command(remote))
            XCTAssertEqual(install(ssh, key: otherKey), .success(.init(wrote: false, curl: true)),
                           "\(shell): the command is current")
            XCTAssertEqual(try inode(command(remote)), first, "\(shell): not written again")
            XCTAssertEqual(bytes(keyFile(remote)), Data("\(otherKey)\n".utf8), "\(shell): the key always is")
            XCTAssertEqual(try mode(keyFile(remote)), 0o600, shell)
        }
    }

    func testAnOlderCommandIsReplaced() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try FileManager.default.createDirectory(at: bin(remote), withIntermediateDirectories: true)
            let older = "#!/bin/sh\n\(RemoteCommand.marker)\n# version 0\n"
            try Data(older.utf8).write(to: command(remote))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command(remote).path)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            XCTAssertEqual(bytes(command(remote)), Data(RemoteCommand.script.utf8), shell)
            XCTAssertEqual(try mode(command(remote)), 0o755, shell)
        }
    }

    func testSomebodyElsesEvlatIsLeftAlone() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seedForeign(remote)
            XCTAssertEqual(install(ssh), .failure(.foreign), shell)
            XCTAssertEqual(bytes(command(remote)), Data(foreign.utf8), shell)
            XCTAssertEqual(try mode(command(remote)), 0o700, shell)
            XCTAssertFalse(exists(keyFile(remote)), "\(shell): nothing is written beside it")

            // A link is not Evlat's either, even to Evlat's own script.
            let linked = try setUp(shell: shell)
            try FileManager.default.createDirectory(at: bin(remote), withIntermediateDirectories: true)
            let target = remote.appendingPathComponent("elsewhere")
            try Data(RemoteCommand.script.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: command(remote), withDestinationURL: target)
            XCTAssertEqual(install(linked), .failure(.foreign), "\(shell): a link")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command(remote).path),
                           target.path)
        }
    }

    func testAFolderThatCannotBeWrittenIsUnwritable() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try FileManager.default.createDirectory(at: bin(remote), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin(remote).path)
            XCTAssertEqual(install(ssh), .failure(.unwritable), shell)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin(remote).path)
        }
    }

    func testWithoutCurlTheInstallSaysSo() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell, mode: .noCurl)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: false)), shell)
            XCTAssertEqual(bytes(command(remote)), Data(RemoteCommand.script.utf8), shell)
        }
    }

    func testSSHsOwnFailureIsUnreachable() throws {
        let ssh = try setUp(shell: "/bin/sh", mode: .unreachable)
        XCTAssertEqual(install(ssh), .failure(.unreachable))
        XCTAssertEqual(remove(ssh), .failure(.unreachable))
        // Anything the scripts never print is not an answer either.
        XCTAssertEqual(RemoteCommand.result(exitCode: 0, output: Data("hello\n".utf8), nonce: "n"),
                       .failure(.unreachable))
        XCTAssertEqual(RemoteCommand.result(exitCode: 1, output: Data(), nonce: "n"), .failure(.unreachable))
    }

    func testALoginBannerDoesNotReachTheResult() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell, mode: .banner)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
        }
    }

    func testTheKeyIsInNoArgv() throws {
        let ssh = try setUp(shell: "/bin/sh")
        XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)))
        XCTAssertFalse(argv.isEmpty, "the fake recorded its argv")
        XCTAssertFalse(argv.contains(key), "the key travels on stdin")
        XCTAssertTrue(argv.hasSuffix("fake\nsh -s\n"), argv)
        XCTAssertFalse(RemoteCommand.removeScript(nonce: "n").contains(key))
    }

    // MARK: - Removing

    func testRemovingTakesBothFilesAndTheEmptyFolder() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            XCTAssertEqual(remove(ssh), .success(.init(wrote: true, curl: true)), shell)
            XCTAssertFalse(exists(command(remote)), shell)
            XCTAssertFalse(exists(keyFile(remote)), shell)
            XCTAssertFalse(exists(keyFolder(remote)), "\(shell): the empty folder goes")
            XCTAssertTrue(exists(bin(remote)), "\(shell): ~/.local/bin is not Evlat's")
            XCTAssertEqual(remove(ssh), .success(.init(wrote: false, curl: true)), "\(shell): nothing left")
        }
    }

    func testRemovingLeavesSomebodyElsesFiles() throws {
        for shell in shells {
            let ssh = try setUp(shell: shell)
            try seedForeign(remote)
            try FileManager.default.createDirectory(at: keyFolder(remote), withIntermediateDirectories: true)
            try Data("\(key)\n".utf8).write(to: keyFile(remote))
            let neighbour = keyFolder(remote).appendingPathComponent("notes")
            try Data("keep".utf8).write(to: neighbour)
            XCTAssertEqual(remove(ssh), .failure(.foreign), shell)
            XCTAssertEqual(bytes(command(remote)), Data(foreign.utf8), "\(shell): untouched")
            XCTAssertFalse(exists(keyFile(remote)), "\(shell): the key is Evlat's and goes")
            XCTAssertEqual(bytes(neighbour), Data("keep".utf8), shell)
        }
    }

    // MARK: - End to end

    /// The installed command, run as a user on the server would, says "ok"
    /// to a listener holding the machine's key — `EVLAT_PORT` standing in
    /// for the tunnel.
    func testTheInstalledCommandIsHeardWithTheInstalledKey() throws {
        let key = self.key
        let listener = HookListener(port: 0, origin: .tunneled, signalKey: { _ in key }) { _ in }
        listener.start()
        defer { listener.stop() }
        guard case .listening(let port) = listener.awaitSettled(timeout: 5) else {
            throw XCTSkip("listener did not come up: \(listener.status.text)")
        }
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [command(remote).path, "--list"]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = remote.path
            environment["EVLAT_PORT"] = String(port)
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardInput = FileHandle.nullDevice
            // Pumped: the listener delivers on the main queue.
            let ended = expectation(description: "exit")
            process.terminationHandler = { _ in ended.fulfill() }
            try process.run()
            wait(for: [ended], timeout: 10)
            let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(line.hasPrefix("ok ("), "\(shell): \(line)")
            XCTAssertEqual(process.terminationStatus, 0, shell)
        }
    }

    // MARK: - By hand

    func testTheManualBlocksWriteWhatTheAutomaticInstallWrites() throws {
        let manual = RemoteCommand.manual(key: key)
        for shell in shells {
            let ssh = try setUp(shell: shell)
            XCTAssertEqual(install(ssh), .success(.init(wrote: true, curl: true)), shell)
            let hand = remote.deletingLastPathComponent().appendingPathComponent("hand", isDirectory: true)
            try FileManager.default.createDirectory(at: hand, withIntermediateDirectories: true)

            XCTAssertEqual(try sh(shell, manual.script, home: hand).status, 0, shell)
            XCTAssertEqual(bytes(command(hand)), bytes(command(remote)), "\(shell): the same bytes")
            XCTAssertEqual(try mode(command(hand)), 0o755, shell)

            // Over a loose file, as a redirection alone would keep it.
            try FileManager.default.createDirectory(at: keyFolder(hand), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try Data("old\n".utf8).write(to: keyFile(hand))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile(hand).path)
            XCTAssertEqual(try sh(shell, manual.key, home: hand).status, 0, shell)
            XCTAssertEqual(bytes(keyFile(hand)), bytes(keyFile(remote)), "\(shell): the same key line")
            XCTAssertEqual(try mode(keyFile(hand)), 0o600, shell)
            XCTAssertEqual(try mode(keyFolder(hand)), 0o700, shell)

            XCTAssertEqual(try sh(shell, manual.remove, home: hand).status, 0, shell)
            XCTAssertFalse(exists(command(hand)), shell)
            XCTAssertFalse(exists(keyFile(hand)), shell)
            XCTAssertFalse(exists(keyFolder(hand)), shell)
            XCTAssertEqual(try sh(shell, manual.remove, home: hand).status, 0, "\(shell): twice is fine")
        }
    }

    func testTheHeredocDelimiterIsNoLineOfTheScript() {
        let lines = RemoteCommand.script.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertFalse(lines.contains { $0 == RemoteCommand.delimiter[...] })
        let manual = RemoteCommand.manual(key: key)
        XCTAssertTrue(manual.script.contains("<<'\(RemoteCommand.delimiter)'"), "a quoted delimiter: no expansion")
        XCTAssertFalse(manual.script.contains(key), "the key has its own block")
        XCTAssertFalse(manual.remove.contains(key))
        XCTAssertTrue(manual.key.contains(key))
    }
}
