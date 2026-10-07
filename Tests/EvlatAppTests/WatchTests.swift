import XCTest
import EvlatCore
@testable import EvlatApp

/// `Evlat watch` and `Evlat signal` as a user runs them: the
/// **built binary**, against a listener this test opens on a socket of its
/// own (`EVLAT_SOCKET`, with a temporary `EVLAT_HOME`, so the user's socket
/// is never touched). What is pinned is the promise of transparency — the exit code,
/// the signal and the bytes of the wrapped command come through unchanged —
/// and that Evlat's row follows the command.
final class WatchTests: XCTestCase {
    private var home: URL!
    private var listener: HookListener?
    private var reports: [SignalReport] = []
    private var arrivals: XCTestExpectation?
    private var processes: [Process] = []
    private var directory: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        directory = try ShortDirectory.make()
    }

    override func tearDownWithError() throws {
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
        listener?.stop()
        listener = nil
        try? FileManager.default.removeItem(at: home)
        ShortDirectory.remove(directory)
    }

    /// The test's socket: where the listener binds, and where the binary is
    /// pointed — bound or not.
    private var socket: String { directory + "/evlat.sock" }

    /// The `Evlat` executable beside the test bundle (`.build/<config>/`).
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat")
    }

    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/watch-child.sh").path
    }

    /// A listener as the app wires its socket: `/signal` without a key.
    /// `origin` other than `.local` makes one that refuses `/signal`.
    @discardableResult
    private func startEvlat(origin: LocalAPI.Origin = .local) throws -> String {
        let listener = HookListener(transport: .unix(socket), origin: origin) { [weak self] delivery in
            guard case .signal(let report) = delivery else { return }
            self?.reports.append(report)
            self?.arrivals?.fulfill()
        }
        listener.start()
        self.listener = listener
        listener.awaitSettled(timeout: 5)
        return try XCTUnwrap(listener.boundPath, "listener did not come up: \(listener.status.text)")
    }

    private struct Run {
        let process: Process
        let stdout: Data
        let stderr: Data
    }

    private func launch(_ arguments: [String], adding extra: [String: String] = [:]) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["EVLAT_HOME"] = home.path
        environment[EvlatSocket.environmentKey] = socket
        environment.merge(extra) { _, added in added }
        process.environment = environment
        // No terminal anywhere: a signal sent to the wrapper is passed on.
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        processes.append(process)
        return (process, out, err)
    }

    /// Runs to the end, pumping the main queue so the listener's deliveries
    /// land; `expecting` rows must have arrived by then.
    private func run(_ arguments: [String], expecting rows: Int = 0, adding extra: [String: String] = [:],
                     then act: ((Process) -> Void)? = nil) throws -> Run {
        let arrived = expectation(description: "\(rows) rows")
        arrived.expectedFulfillmentCount = max(rows, 1)
        if rows == 0 { arrived.fulfill() }
        arrived.assertForOverFulfill = false
        let (process, out, err) = try launch(arguments, adding: extra)
        if let act {
            // Wait for the `working` row: then the child certainly exists.
            let first = expectation(description: "working row")
            arrivals = first
            wait(for: [first], timeout: 10)
            arrivals = nil
            act(process)
            if rows > 1 {
                arrived.expectedFulfillmentCount = rows - 1
            }
        }
        arrivals = arrived
        let ended = expectation(description: "exit")
        process.terminationHandler = { _ in ended.fulfill() }
        if !process.isRunning { ended.fulfill() }
        wait(for: [ended, arrived], timeout: 15)
        arrivals = nil
        return Run(process: process, stdout: out.fileHandleForReading.readDataToEndOfFile(),
                   stderr: err.fileHandleForReading.readDataToEndOfFile())
    }

    // MARK: - Exit codes and rows

    func testTheExitCodeComesThroughAndTheRowFollows() throws {
        try startEvlat()
        let ok = try run(["watch", "sh", fixture, "exit", "0"], expecting: 2)
        XCTAssertEqual(ok.process.terminationReason, .exit)
        XCTAssertEqual(ok.process.terminationStatus, 0)
        XCTAssertEqual(reports.map(\.word), [.working, .done])
        XCTAssertEqual(reports.first?.id, "watch-\(ok.process.processIdentifier)")
        XCTAssertEqual(reports.first?.sender, "sh")
        XCTAssertTrue(reports.first?.label.hasPrefix("sh /") ?? false, "the command line is the label")

        reports = []
        let three = try run(["watch", "sh", fixture, "exit", "3"], expecting: 2)
        XCTAssertEqual(three.process.terminationStatus, 3)
        XCTAssertEqual(reports.map(\.word), [.working, .failed])
        XCTAssertTrue(reports.last?.detail?.hasPrefix("exit 3 · ") ?? false, reports.last?.detail ?? "")
        XCTAssertTrue(three.stdout.isEmpty && three.stderr.isEmpty, "Evlat printed nothing")
    }

    /// Ctrl-C's end: the child dies of SIGINT, and so does the wrapper — the
    /// shell loop around it stops. The child did die: the fixture's
    /// `exit 99` is where an inherited `SIG_IGN` would have left it.
    func testAChildKilledBySIGINTTakesTheWrapperWithIt() throws {
        try startEvlat()
        let run = try run(["watch", "sh", fixture, "die", "INT"], expecting: 2)
        XCTAssertEqual(run.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(run.process.terminationStatus, SIGINT)
        XCTAssertEqual(reports.map(\.word), [.working, .failed])
        XCTAssertTrue(reports.last?.detail?.hasPrefix("signal 2 · ") ?? false, reports.last?.detail ?? "")
    }

    func testSIGTERMIsPassedOnToTheChild() throws {
        try startEvlat()
        let started = Date()
        let run = try run(["watch", "sh", fixture, "sleep"], expecting: 2) { process in
            process.terminate()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the child's 30 s sleep did not run out")
        XCTAssertEqual(run.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(run.process.terminationStatus, SIGTERM)
        XCTAssertEqual(reports.last?.word, .failed)
        XCTAssertTrue(reports.last?.detail?.hasPrefix("signal 15 · ") ?? false, reports.last?.detail ?? "")
    }

    /// Without a terminal nobody else sends the child its SIGINT: the wrapper does.
    func testSIGINTIsPassedOnWithoutATerminal() throws {
        try startEvlat()
        let run = try run(["watch", "sh", fixture, "sleep"], expecting: 2) { process in
            kill(process.processIdentifier, SIGINT)
        }
        XCTAssertEqual(run.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(run.process.terminationStatus, SIGINT)
    }

    // MARK: - The streams

    private let expectedOut = Data("out \u{1B}[31mred\u{1B}[0m ä\n\u{01}tail".utf8)
    private let expectedErr = Data("err line\nno newline".utf8)

    func testTheStreamsPassThroughByteForByte() throws {
        try startEvlat()
        let run = try run(["watch", "sh", fixture, "bytes"], expecting: 2)
        XCTAssertEqual(run.stdout, expectedOut)
        XCTAssertEqual(run.stderr, expectedErr)
        XCTAssertEqual(run.process.terminationStatus, 0)
    }

    // MARK: - Evlat closed, or refusing

    func testWithoutEvlatTheCommandRunsAndNothingIsWritten() throws {
        let bytes = try run(["watch", "sh", fixture, "bytes"])
        XCTAssertEqual(bytes.stdout, expectedOut)
        XCTAssertEqual(bytes.stderr, expectedErr)
        XCTAssertEqual(bytes.process.terminationStatus, 0)
        let five = try run(["watch", "sh", fixture, "exit", "5"])
        XCTAssertEqual(five.process.terminationStatus, 5)
        XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"])
        XCTAssertEqual(signal.process.terminationStatus, 0)
        XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
    }

    /// A killed Evlat's socket file is left behind, so the post is made and
    /// the connection is refused. Still nothing written.
    func testAKilledEvlatsLeftoverSocketIsSilentToo() throws {
        try HookListenerTests.leaveStaleSocket(at: socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "the file outlives its listener")
        let five = try run(["watch", "sh", fixture, "exit", "5"])
        XCTAssertEqual(five.process.terminationStatus, 5)
        XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"])
        XCTAssertEqual(signal.process.terminationStatus, 0)
        XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
    }

    /// An endpoint that says no (`404`: a listener without the route).
    /// `watch` still says nothing — its output is the command's — while
    /// `signal` says it in one line.
    func testARefusalIsSilentInWatchAndOneLineInSignal() throws {
        try startEvlat(origin: .sandbox)
        let watch = try run(["watch", "sh", fixture, "exit", "4"])
        XCTAssertEqual(watch.process.terminationStatus, 4)
        XCTAssertTrue(watch.stdout.isEmpty && watch.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"])
        XCTAssertEqual(signal.process.terminationStatus, 1)
        let line = String(decoding: signal.stderr, as: UTF8.self)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, line)
        XCTAssertTrue(line.contains("404"), line)
        XCTAssertTrue(reports.isEmpty)
    }

    /// An old isolation recipe (`EVLAT_PORT`, blank included) is not the
    /// wrapped command's business: it runs, its exit and bytes come through,
    /// and nothing is posted — not even to a listening Evlat. `signal` says
    /// the one line, as for any refusal.
    func testTheRetiredPortRunsTheCommandAndPostsNothing() throws {
        try startEvlat()
        let retired = [Isolation.retiredPortKey: ""]
        let bytes = try run(["watch", "sh", fixture, "bytes"], adding: retired)
        XCTAssertEqual(bytes.process.terminationStatus, 0)
        XCTAssertEqual(bytes.stdout, expectedOut)
        XCTAssertEqual(bytes.stderr, expectedErr)
        let five = try run(["watch", "sh", fixture, "exit", "5"], adding: retired)
        XCTAssertEqual(five.process.terminationReason, .exit)
        XCTAssertEqual(five.process.terminationStatus, 5)
        XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"], adding: retired)
        XCTAssertEqual(signal.process.terminationStatus, 1)
        XCTAssertTrue(signal.stdout.isEmpty)
        let line = String(decoding: signal.stderr, as: UTF8.self)
        XCTAssertEqual(line, "Evlat: signal x refused (\(Isolation.retiredPortLine))\n")
        XCTAssertTrue(reports.isEmpty, "nothing reached the listener")
    }

    // MARK: - signal

    func testSignalSetsAndClearsARow() throws {
        try startEvlat()
        let set = try run(["signal", "build", "--label", "Build", "--progress", "0.5"], expecting: 1)
        XCTAssertEqual(set.process.terminationStatus, 0)
        XCTAssertEqual(reports.last?.id, "build")
        XCTAssertEqual(reports.last?.progress, 0.5)
        XCTAssertEqual(reports.last?.ttl, 900)
        let clear = try run(["signal", "build", "--clear"], expecting: 1)
        XCTAssertEqual(clear.process.terminationStatus, 0)
        XCTAssertEqual(reports.last?.ttl, 0)
    }

    /// An argument error is 2 with the usage — and the subcommand is read from
    /// `argv[1]` only, so a wrapped command's `--list` is the command's.
    func testArgumentErrorsAndWhoseFlagsAreWhose() throws {
        let wrong = try run(["signal", "--progress", "2", "x"])
        XCTAssertEqual(wrong.process.terminationStatus, 2)
        XCTAssertTrue(String(decoding: wrong.stderr, as: UTF8.self).contains("usage:"))
        let listed = try run(["watch", "sh", "-c", "echo \"$1\"", "sh", "--list"])
        XCTAssertEqual(listed.process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: listed.stdout, as: UTF8.self), "--list\n")
    }
}
