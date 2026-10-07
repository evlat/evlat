import XCTest
import EvlatCore
@testable import EvlatApp

/// The server's `evlat`: `RemoteCommand.script` written to a
/// temporary file and run as a user on a server runs it — under `/bin/sh`,
/// `/bin/dash` and `/bin/bash` — against a tunnel's keyed listener this test
/// opens, with a temporary `HOME` holding the key and `EVLAT_PORT` pointing
/// at the listener. `WatchTests`' promises, kept by a POSIX shell script:
/// the exit code and the bytes come through, Evlat writes nothing of its
/// own, and every body it sends is one `SignalReport.parse` accepts (the
/// listener delivers nothing else).
final class RemoteCommandScriptTests: XCTestCase {
    private let key = String(repeating: "5a", count: 32)
    private var root: URL!
    private var listener: HookListener?
    private var reports: [SignalReport] = []
    private var arrivals: XCTestExpectation?
    private var processes: [Process] = []

    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var work: URL { home.appendingPathComponent("work", isDirectory: true) }
    private var keyFile: URL { home.appendingPathComponent(RemoteCommand.keyPath) }
    private var script: URL { root.appendingPathComponent("evlat") }

    /// Every POSIX shell this machine has; `sh` and `dash` are what servers run.
    private static let shells = ["/bin/sh", "/bin/dash", "/bin/bash"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    override func setUpWithError() throws {
        // The physical path: a shell's `$PWD` is, and `~` is read against `HOME`.
        let temporary = realpath(FileManager.default.temporaryDirectory.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = temporary
            .appendingPathComponent("evlat-remote-command-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        try manager.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try writeKey(key)
        try Data(RemoteCommand.script.utf8).write(to: script)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
        listener?.stop()
        listener = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func writeKey(_ text: String, mode: Int = 0o600) throws {
        try Data("\(text)\n".utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: keyFile.path)
    }

    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/watch-child.sh").path
    }

    // MARK: - Listeners

    /// A machine's tunnel listener as `RemoteTunnels` opens it: keyed, or
    /// (`keyed: false`) the keyless one an older link has.
    private func startTunnel(keyed: Bool = true) throws -> UInt16 {
        let key = self.key
        let listener = HookListener(port: 0, origin: .machine,
                                    signalKey: { _ in keyed ? key : nil }) { [weak self] delivery in
            guard case .signal(let report) = delivery else { return }
            self?.reports.append(report)
            self?.arrivals?.fulfill()
        }
        listener.start()
        self.listener = listener
        guard case .listening(let port) = listener.awaitSettled(timeout: 5) else {
            throw XCTSkip("listener did not come up: \(listener.status.text)")
        }
        return port
    }

    /// A port nobody listens on: the tunnel is down.
    private func closedPort() throws -> UInt16 {
        let probe = HookListener(port: 0) { _ in }
        probe.start()
        defer { probe.stop() }
        guard case .listening(let port) = probe.awaitSettled(timeout: 5) else { throw XCTSkip("no free port") }
        return port
    }

    // MARK: - Running

    private struct Run {
        let pid: Int32
        let reason: Process.TerminationReason
        let status: Int32
        let stdout: Data
        let stderr: Data
        let elapsed: TimeInterval
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// `shell script arguments…`, to the end, pumping the main queue so the
    /// listener's deliveries land; `rows` must have arrived by then.
    /// `ownGroup` starts it in a process group of its own, as a terminal's
    /// shell starts a foreground job — so a signal to the group is Ctrl-C.
    /// `act` runs once the first row (`working`) is in: the command exists.
    private func run(_ shell: String, _ arguments: [String], port: UInt16, rows: Int = 0,
                     stdin: Data? = nil, ownGroup: Bool = false, path: String? = nil,
                     command: [String]? = nil, act: ((Int32) -> Void)? = nil) throws -> Run {
        let process = Process()
        if let command {
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
        } else if ownGroup {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", "setpgrp(0,0); exec @ARGV or die", "--", shell, script.path] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [script.path] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["EVLAT_PORT"] = String(port)
        if let path { environment["PATH"] = path }
        process.environment = environment
        process.currentDirectoryURL = work
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let arrived = expectation(description: "\(rows) rows")
        arrived.expectedFulfillmentCount = max(rows, 1)
        arrived.assertForOverFulfill = false
        if rows == 0 { arrived.fulfill() }
        let ended = expectation(description: "exit")
        var endedAt = Date()
        process.terminationHandler = { _ in endedAt = Date(); ended.fulfill() }
        let started = Date()
        try process.run()
        processes.append(process)
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        if let act {
            let first = expectation(description: "working row")
            arrivals = first
            wait(for: [first], timeout: 10)
            arrivals = nil
            act(process.processIdentifier)
            if rows > 1 { arrived.expectedFulfillmentCount = rows - 1 }
        }
        arrivals = arrived
        wait(for: [ended, arrived], timeout: 20)
        arrivals = nil
        return Run(pid: process.processIdentifier, reason: process.terminationReason,
                   status: process.terminationStatus,
                   stdout: out.fileHandleForReading.readDataToEndOfFile(),
                   stderr: err.fileHandleForReading.readDataToEndOfFile(),
                   elapsed: endedAt.timeIntervalSince(started))
    }

    /// Waits until `pid` has a child called `name` — the watched command
    /// itself, which the wrapper starts only after its traps are set. The
    /// first `working` row goes out *before* the traps (`dash`'s pitfall), so
    /// a signal sent on its arrival alone could beat them.
    private func awaitCommand(_ name: String, of pid: Int32) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", String(pid), "-x", name]
            pgrep.standardOutput = FileHandle.nullDevice
            pgrep.standardError = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { break }
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 0 { return }
            usleep(20_000)
        }
        XCTFail("\(name) never ran under \(pid)")
    }

    private func eachShell(_ body: (String) throws -> Void) rethrows {
        XCTAssertFalse(Self.shells.isEmpty)
        for shell in Self.shells {
            reports = []
            try XCTContext.runActivity(named: shell) { _ in try body(shell) }
        }
    }

    // MARK: - The script itself

    func testTheScriptIsMarkedVersionedAndMadeFromTheConstants() {
        let lines = RemoteCommand.script.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "#!/bin/sh")
        XCTAssertEqual(String(lines[1]), RemoteCommand.marker)
        XCTAssertEqual(String(lines[2]), "# version \(RemoteCommand.version)")
        let text = RemoteCommand.script
        XCTAssertTrue(text.contains("\(LocalAPI.defaultPort)"))
        XCTAssertTrue(text.contains(SignalReport.path))
        XCTAssertTrue(text.contains(SignalReport.keyHeader))
        XCTAssertTrue(text.contains(RemoteCommand.keyPath))
        XCTAssertTrue(text.contains("sleep \(Int(SignalCommand.heartbeat))"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    /// `sh -n` in every shell, and none of the words a POSIX `sh` lacks.
    func testTheScriptIsPlainPOSIXShell() throws {
        for shell in Self.shells {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: shell)
            check.arguments = ["-n", script.path]
            let err = Pipe()
            check.standardError = err
            try check.run()
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0,
                           "\(shell): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        let code = RemoteCommand.script.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        for word in ["local ", "[[", "]]", "declare ", "typeset ", "function ", "source ", "$'", "=(",
                     "echo -e", "echo -n", "pipefail", "<<<", "&>", "${!", "$RANDOM", "select "] {
            XCTAssertFalse(code.contains(word), "not POSIX: \(word)")
        }
    }

    // MARK: - watch

    func testWatchPassesTheExitCodeAndTheRowFollows() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let ok = try run(shell, ["watch", "true"], port: port, rows: 2)
            XCTAssertEqual(ok.reason, .exit)
            XCTAssertEqual(ok.status, 0)
            XCTAssertEqual(reports.map(\.word), [.working, .done])
            XCTAssertEqual(reports.first?.id, "watch-\(ok.pid)")
            XCTAssertEqual(reports.first?.label, "true")
            XCTAssertEqual(reports.first?.sender, "true")
            XCTAssertEqual(reports.first?.detail, "~/work")
            XCTAssertEqual(reports.first?.ttl, SignalCommand.watchTTL)
            XCTAssertEqual(reports.last?.ttl, SignalCommand.finishedTTL)
            XCTAssertTrue(ok.stdout.isEmpty && ok.stderr.isEmpty)

            reports = []
            let three = try run(shell, ["watch", "sh", "-c", "exit 3"], port: port, rows: 2)
            XCTAssertEqual(three.status, 3)
            XCTAssertEqual(reports.map(\.word), [.working, .failed])
            XCTAssertEqual(reports.last?.detail, "exit 3 · ~/work")
            XCTAssertEqual(reports.last?.label, "sh -c exit 3")
            XCTAssertEqual(reports.last?.sender, "sh")
            XCTAssertTrue(three.stdout.isEmpty && three.stderr.isEmpty)

            reports = []
            let named = try run(shell, ["watch", "--label", "Build", "--sender", "make", "--", "true"],
                                port: port, rows: 2)
            XCTAssertEqual(named.status, 0)
            XCTAssertEqual(reports.last?.label, "Build")
            XCTAssertEqual(reports.last?.sender, "make")
        }
    }

    private let expectedOut = Data("out \u{1B}[31mred\u{1B}[0m ä\n\u{01}tail".utf8)
    private let expectedErr = Data("err line\nno newline".utf8)

    func testTheStreamsAndStdinPassThroughByteForByte() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let bytes = try run(shell, ["watch", "sh", fixture, "bytes"], port: port, rows: 2)
            XCTAssertEqual(bytes.stdout, expectedOut)
            XCTAssertEqual(bytes.stderr, expectedErr)
            XCTAssertEqual(bytes.status, 0)

            let input = Data("line one\nä \u{01}\nno newline".utf8)
            let cat = try run(shell, ["watch", "cat"], port: port, rows: 2, stdin: input)
            XCTAssertEqual(cat.stdout, input, "stdin reached the command")
            XCTAssertEqual(cat.status, 0)
        }
    }

    /// The command's flags are the command's: Evlat reads its own only
    /// before the command.
    func testFlagsAfterTheCommandGoToTheCommand() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let run = try run(shell, ["watch", "sh", "-c", #"printf '%s|' "$@""#, "x", "--label", "y", "--", "-z"],
                              port: port, rows: 2)
            XCTAssertEqual(run.out, "--label|y|--|-z|")
            XCTAssertEqual(reports.last?.sender, "sh")
            XCTAssertTrue(reports.last?.label.hasPrefix("sh -c printf") ?? false, reports.last?.label ?? "")
        }
    }

    /// `$(evlat watch true)`: nothing of Evlat's in the capture, and nothing
    /// of Evlat's left holding the pipe — the heartbeat's `sleep` included.
    func testACommandSubstitutionGetsNothingAndIsNotHeld() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let run = try run(shell, [], port: port, rows: 2,
                              command: ["/bin/sh", "-c", #"x=$("$0" "$1" watch true); printf '%s' "$x""#,
                                        shell, script.path])
            XCTAssertEqual(run.status, 0)
            XCTAssertTrue(run.stdout.isEmpty && run.stderr.isEmpty, run.out + run.err)
            XCTAssertLessThan(run.elapsed, 3, "within curl's 2 s and one more")
            XCTAssertEqual(reports.map(\.word), [.working, .done])
        }
    }

    // MARK: - Nobody there

    /// No tunnel, no key file, no `curl`: the command runs as it is and
    /// Evlat writes nothing.
    func testWithoutATunnelAKeyOrCurlTheCommandRunsAndNothingIsWritten() throws {
        let closed = try closedPort()
        try eachShell { shell in
            let bytes = try run(shell, ["watch", "sh", fixture, "bytes"], port: closed)
            XCTAssertEqual(bytes.stdout, expectedOut)
            XCTAssertEqual(bytes.stderr, expectedErr)
            let five = try run(shell, ["watch", "sh", fixture, "exit", "5"], port: closed)
            XCTAssertEqual(five.status, 5)
            XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
            let quick = try run(shell, ["watch", "true"], port: closed)
            XCTAssertEqual(quick.status, 0)
            XCTAssertTrue(quick.stdout.isEmpty && quick.stderr.isEmpty)
            let signal = try run(shell, ["signal", "x", "--done"], port: closed)
            XCTAssertEqual(signal.status, 0)
            XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
        }

        let port = try startTunnel()
        try eachShell { shell in
            // `curl` is in /usr/bin, `sh` in /bin.
            let noCurl = try run(shell, ["watch", "sh", fixture, "exit", "5"], port: port, path: "/bin")
            XCTAssertEqual(noCurl.status, 5)
            XCTAssertTrue(noCurl.stdout.isEmpty && noCurl.stderr.isEmpty, noCurl.err)
        }
        try FileManager.default.removeItem(at: keyFile)
        try eachShell { shell in
            let five = try run(shell, ["watch", "sh", fixture, "exit", "5"], port: port)
            XCTAssertEqual(five.status, 5)
            XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
            let signal = try run(shell, ["signal", "x", "--done"], port: port)
            XCTAssertEqual(signal.status, 0)
            XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
        }
        XCTAssertTrue(reports.isEmpty)
    }

    /// A command that is not there: the shell's own words and `127`, no row.
    func testACommandThatIsNotThereSendsNoRow() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let run = try run(shell, ["watch", "evlat-no-such-command"], port: port)
            XCTAssertEqual(run.status, 127)
            XCTAssertTrue(run.err.contains("evlat-no-such-command"), run.err)
            XCTAssertTrue(reports.isEmpty)
        }
    }

    // MARK: - Signals

    /// Ctrl-C: the terminal sends SIGINT to the whole foreground group. The
    /// command dies of it, the row says so, and the wrapper dies of it too —
    /// a loop around it stops.
    func testSIGINTToTheGroupEndsTheCommandAndTheWrapper() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let run = try run(shell, ["watch", "sleep", "30"], port: port, rows: 2, ownGroup: true) { pid in
                self.awaitCommand("sleep", of: pid)
                kill(-pid, SIGINT)
            }
            XCTAssertLessThan(run.elapsed, 10, "the command's 30 s sleep did not run out")
            XCTAssertEqual(run.reason, .uncaughtSignal)
            XCTAssertEqual(run.status, SIGINT)
            XCTAssertEqual(reports.last?.word, .failed)
            XCTAssertEqual(reports.last?.detail, "signal 2 · ~/work")
        }
    }

    /// The limit a shell sets: a trapped signal waits for the foreground
    /// command. SIGTERM to the wrapper alone is not passed on — the command
    /// runs to its end, the row says how it ended, and only then does the
    /// wrapper go, with SIGTERM.
    func testSIGTERMToTheWrapperAloneWaitsForTheCommand() throws {
        let port = try startTunnel()
        try eachShell { shell in
            let run = try run(shell, ["watch", "sleep", "2"], port: port, rows: 2, ownGroup: true) { pid in
                self.awaitCommand("sleep", of: pid)
                kill(pid, SIGTERM)
            }
            XCTAssertGreaterThan(run.elapsed, 1.5, "the command ran to its end")
            XCTAssertEqual(run.reason, .uncaughtSignal)
            XCTAssertEqual(run.status, SIGTERM)
            XCTAssertEqual(reports.last?.word, .done)
        }
    }

    // MARK: - The key

    /// The key never reaches an argv — `ps` and `/proc/*/cmdline` show every
    /// argv to every user. A `curl` in front of the real one records its
    /// arguments; `ps` is read while the watch runs.
    func testTheKeyIsNeverInAnArgv() throws {
        let port = try startTunnel()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let log = root.appendingPathComponent("curl-argv", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("curl")
        try Data("""
            #!/bin/sh
            \(FreshExecutable.warmLine)
            printf '%s\\n' "$@" > '\(log.path)'/$$
            exec /usr/bin/curl "$@"

            """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        FreshExecutable.warm(fake.path)
        let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        try eachShell { shell in
            var listing = ""
            // Long enough that `ps` runs while it does, however late the
            // first row arrives; `ps` waits for it to be running.
            let run = try run(shell, ["watch", "sleep", "3"], port: port, rows: 2, path: path) { pid in
                self.awaitCommand("sleep", of: pid)
                let ps = Process()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-A", "-o", "args="]
                let out = Pipe()
                ps.standardOutput = out
                try? ps.run()
                listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                ps.waitUntilExit()
            }
            XCTAssertEqual(run.status, 0)
            XCTAssertTrue(listing.contains("sleep 3"), "ps saw the watch")
            XCTAssertFalse(listing.contains(key))
        }
        let calls = try FileManager.default.contentsOfDirectory(atPath: log.path)
        XCTAssertGreaterThanOrEqual(calls.count, 2 * Self.shells.count)
        for call in calls {
            let argv = try String(contentsOf: log.appendingPathComponent(call), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertFalse(argv.joined().contains(key))
            XCTAssertEqual(argv.first, "-q", "~/.curlrc is not read")
            XCTAssertTrue(argv.contains("-K"))
            XCTAssertTrue(argv.contains("--noproxy"))
            XCTAssertTrue(argv.contains("*"))
        }
    }

    // MARK: - signal

    /// The local command's words, every one: the Swift parser decides, the
    /// script must agree — a usage error is `2` in both, and a body the
    /// script sends is the one the Swift command would send.
    func testSignalSpeaksTheLocalCommandsWords() throws {
        let port = try startTunnel()
        let cases: [[String]] = [
            ["signal", "build"],
            ["signal", "build", "--label", "Build", "--progress", "0.5", "--detail", "step 2", "--sender", "make"],
            ["signal", "build", "--progress", ".25"],
            ["signal", "build", "--progress", "1"],
            ["signal", "build", "--progress", "1.0"],
            ["signal", "build", "--progress", "0"],
            ["signal", "build", "--progress", "+0.5"],
            ["signal", "build", "--progress", "007"],
            ["signal", "build", "--ttl", "05"],
            ["signal", "build", "--ttl", "+60", "--waiting"],
            ["signal", "build", "--ttl", "86400"],
            ["signal", "build", "--done"],
            ["signal", "build", "--failed", "--ttl", "90000"],
            ["signal", "build", "--clear"],
            ["signal", "--", "-dash.id_1"],
            ["signal", "--label", "L", "build"],
            ["signal", String(repeating: "a", count: 64)],
            // Usage errors.
            ["signal"],
            ["signal", "a", "b"],
            ["signal", "a b"],
            ["signal", "a:b"],
            ["signal", String(repeating: "a", count: 65)],
            ["signal", "ä"],
            ["signal", "x", "--progress", "2"],
            ["signal", "x", "--progress", "1.01"],
            ["signal", "x", "--progress", "abc"],
            ["signal", "x", "--progress", "."],
            ["signal", "x", "--progress", ""],
            ["signal", "x", "--progress", "-0.5"],
            ["signal", "x", "--ttl", "86401"],
            ["signal", "x", "--ttl", "-1"],
            ["signal", "x", "--ttl", "1.5"],
            ["signal", "x", "--ttl", ""],
            ["signal", "x", "--ttl", "99999999999999999999"],
            ["signal", "x", "--clear", "--label", "y"],
            ["signal", "x", "--done", "--failed"],
            ["signal", "x", "--bogus"],
            ["signal", "x", "--label"],
            ["signal", "--", "x", "--done"],
            ["watch"],
            ["watch", "--label"],
            ["watch", "--bogus", "true"],
            ["watch", "--label", "x"],
            ["watch", "--"],
            ["bogus"],
        ]
        try eachShell { shell in
            for arguments in cases {
                reports = []
                let parsed = SignalCommand.parse(arguments)
                let expected: Result<SignalReport, SignalReport.Rejection>?
                if case .success(.signal(let post)) = parsed {
                    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: post.body) as? [String: Any])
                    expected = SignalReport.parse(json: json)
                } else {
                    expected = nil
                }
                let run = try run(shell, arguments, port: port, rows: expected == nil ? 0 : 1)
                let name = arguments.joined(separator: " ")
                switch expected {
                case nil:
                    XCTAssertEqual(run.status, 2, "\(name): \(run.err)")
                    XCTAssertTrue(run.err.hasPrefix("evlat: "), "\(name): \(run.err)")
                    XCTAssertTrue(run.err.contains("usage: evlat watch"), name)
                    XCTAssertTrue(run.stdout.isEmpty, name)
                case .success(let report):
                    XCTAssertEqual(run.status, 0, "\(name): \(run.err)")
                    XCTAssertTrue(run.stdout.isEmpty && run.stderr.isEmpty, "\(name): \(run.out)\(run.err)")
                    XCTAssertEqual(reports, [report], name)
                case .failure(let rejection):
                    XCTFail("\(name): the Swift command's own body was refused: \(rejection)")
                }
            }
        }
    }

    /// Text is escaped for JSON and cleaned: quotes, backslashes, line
    /// breaks, tabs, control bytes and UTF-8 arrive as the route cleans them.
    func testTextArrivesAsTheRouteCleansIt() throws {
        let port = try startTunnel()
        let label = "a\"b\\c\td\ne\r\u{01}f ä \u{1B}[31m'$(x)`y`"
        let long = String(repeating: "ä", count: 300)
        try eachShell { shell in
            let sent = try run(shell, ["signal", "x", "--label", label, "--detail", long, "--sender", "a\\\"b"],
                              port: port, rows: 1)
            XCTAssertEqual(sent.status, 0, sent.err)
            XCTAssertEqual(reports.last?.label, SignalReport.clean(label, limit: SignalReport.labelLimit))
            XCTAssertEqual(reports.last?.detail, SignalReport.clean(long, limit: SignalReport.detailLimit))
            XCTAssertEqual(reports.last?.sender, "a\\\"b")

            reports = []
            let watch = try run(shell, ["watch", "sh", "-c", ": \"$1\"", "-", label], port: port, rows: 2)
            XCTAssertEqual(watch.status, 0)
            XCTAssertEqual(reports.last?.label,
                           SignalReport.clean("sh -c : \"$1\" - " + label, limit: SignalReport.labelLimit))
        }
    }

    /// A stale key is the sender's to fix: one stderr line and `1`. `watch`
    /// says nothing — its output is the command's.
    func testARefusalIsOneLineInSignalAndSilentInWatch() throws {
        let port = try startTunnel()
        try writeKey(String(repeating: "0", count: 64))
        try eachShell { shell in
            let signal = try run(shell, ["signal", "x", "--done"], port: port)
            XCTAssertEqual(signal.status, 1)
            XCTAssertEqual(signal.err.filter { $0 == "\n" }.count, 1, signal.err)
            XCTAssertTrue(signal.err.hasPrefix("evlat: signal x refused (403"), signal.err)
            let watch = try run(shell, ["watch", "sh", "-c", "exit 4"], port: port)
            XCTAssertEqual(watch.status, 4)
            XCTAssertTrue(watch.stdout.isEmpty && watch.stderr.isEmpty)
        }
        XCTAssertTrue(reports.isEmpty)
    }

    // MARK: - --list and --help

    func testListSaysInOneLineWhetherTheMacHearsIt() throws {
        let version = "evlat \(RemoteCommand.version)"
        try eachShell { shell in
            let port = try startTunnel()
            let ok = try run(shell, ["--list"], port: port, rows: 1)
            XCTAssertEqual(ok.status, 0)
            XCTAssertTrue(ok.out.hasPrefix("ok"), ok.out)
            XCTAssertTrue(ok.out.contains(version), ok.out)
            XCTAssertEqual(ok.out.filter { $0 == "\n" }.count, 1, ok.out)
            XCTAssertEqual(reports.last?.ttl, 0, "the probe removes what it names")

            try writeKey(key, mode: 0o644)
            let loose = try run(shell, ["--list"], port: port, rows: 1)
            XCTAssertEqual(loose.status, 0)
            XCTAssertTrue(loose.out.contains("-rw-r--r--"), loose.out)

            try writeKey(String(repeating: "0", count: 64))
            let wrong = try run(shell, ["--list"], port: port)
            XCTAssertEqual(wrong.status, 1)
            XCTAssertTrue(wrong.out.contains("403"), wrong.out)
            try writeKey(key)
            listener?.stop()

            let keyless = try startTunnel(keyed: false)
            let old = try run(shell, ["--list"], port: keyless)
            XCTAssertEqual(old.status, 1)
            XCTAssertTrue(old.out.contains("404"), old.out)
            listener?.stop()

            let down = try run(shell, ["--list"], port: try closedPort())
            XCTAssertEqual(down.status, 1)
            XCTAssertTrue(down.out.hasPrefix("no tunnel"), down.out)

            try FileManager.default.removeItem(at: keyFile)
            let none = try run(shell, ["--list"], port: keyless)
            XCTAssertEqual(none.status, 1)
            XCTAssertTrue(none.out.hasPrefix("no key"), none.out)
            XCTAssertTrue(none.out.contains(version), none.out)
            try writeKey(key)
        }
    }

    func testHelpPrintsTheUsage() throws {
        let port = try closedPort()
        try eachShell { shell in
            for arguments in [["--help"], ["-h"], ["watch", "--help"], ["signal", "x", "-h"]] {
                let run = try run(shell, arguments, port: port)
                XCTAssertEqual(run.status, 0)
                XCTAssertEqual(run.out, RemoteCommand.usage + "\n", arguments.joined(separator: " "))
                XCTAssertTrue(run.stderr.isEmpty)
            }
        }
        XCTAssertTrue(RemoteCommand.usage.contains("usage: evlat watch"))
        XCTAssertTrue(RemoteCommand.usage.contains("evlat --list"))
        XCTAssertFalse(RemoteCommand.usage.contains("Evlat watch"))
    }
}
