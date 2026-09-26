import XCTest
import EvlatCore
@testable import EvlatApp

/// `Evlat watch` and `Evlat signal` as a user runs them: the
/// **built binary**, against a listener this test opens under a temporary
/// home (`EVLAT_HOME` + `EVLAT_PORT`, so the user's key and port are never
/// touched). What is pinned is the promise of transparency — the exit code,
/// the signal and the bytes of the wrapped command come through unchanged —
/// and that Evlat's row follows the command.
final class WatchTests: XCTestCase {
    private var home: URL!
    private var listener: HookListener?
    private var reports: [SignalReport] = []
    private var arrivals: XCTestExpectation?
    private var processes: [Process] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
        listener?.stop()
        listener = nil
        try? FileManager.default.removeItem(at: home)
    }

    /// The `Evlat` executable beside the test bundle (`.build/<config>/`).
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat")
    }

    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/watch-child.sh").path
    }

    /// A listener as the app wires it: the key written under `home` once bound.
    private func startEvlat() throws -> UInt16 {
        let listener = HookListener(port: 0,
                                    signalKey: AppController.signalKeyWriter(home: home, environment: [:])) { [weak self] delivery in
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

    /// A port nobody listens on: bound once by the system's choice, then let go.
    private func closedPort() throws -> UInt16 {
        let probe = HookListener(port: 0) { _ in }
        probe.start()
        defer { probe.stop() }
        guard case .listening(let port) = probe.awaitSettled(timeout: 5) else {
            throw XCTSkip("no free port")
        }
        return port
    }

    private struct Run {
        let process: Process
        let stdout: Data
        let stderr: Data
    }

    private func launch(_ arguments: [String], port: UInt16) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["EVLAT_HOME"] = home.path
        environment["EVLAT_PORT"] = String(port)
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
    private func run(_ arguments: [String], port: UInt16, expecting rows: Int = 0,
                     then act: ((Process) -> Void)? = nil) throws -> Run {
        let arrived = expectation(description: "\(rows) rows")
        arrived.expectedFulfillmentCount = max(rows, 1)
        if rows == 0 { arrived.fulfill() }
        arrived.assertForOverFulfill = false
        let (process, out, err) = try launch(arguments, port: port)
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
        let port = try startEvlat()
        let ok = try run(["watch", "sh", fixture, "exit", "0"], port: port, expecting: 2)
        XCTAssertEqual(ok.process.terminationReason, .exit)
        XCTAssertEqual(ok.process.terminationStatus, 0)
        XCTAssertEqual(reports.map(\.word), [.working, .done])
        XCTAssertEqual(reports.first?.id, "watch-\(ok.process.processIdentifier)")
        XCTAssertEqual(reports.first?.sender, "sh")
        XCTAssertTrue(reports.first?.label.hasPrefix("sh /") ?? false, "the command line is the label")

        reports = []
        let three = try run(["watch", "sh", fixture, "exit", "3"], port: port, expecting: 2)
        XCTAssertEqual(three.process.terminationStatus, 3)
        XCTAssertEqual(reports.map(\.word), [.working, .failed])
        XCTAssertTrue(reports.last?.detail?.hasPrefix("exit 3 · ") ?? false, reports.last?.detail ?? "")
        XCTAssertTrue(three.stdout.isEmpty && three.stderr.isEmpty, "Evlat printed nothing")
    }

    /// Ctrl-C's end: the child dies of SIGINT, and so does the wrapper — the
    /// shell loop around it stops. The child did die: the fixture's
    /// `exit 99` is where an inherited `SIG_IGN` would have left it.
    func testAChildKilledBySIGINTTakesTheWrapperWithIt() throws {
        let port = try startEvlat()
        let run = try run(["watch", "sh", fixture, "die", "INT"], port: port, expecting: 2)
        XCTAssertEqual(run.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(run.process.terminationStatus, SIGINT)
        XCTAssertEqual(reports.map(\.word), [.working, .failed])
        XCTAssertTrue(reports.last?.detail?.hasPrefix("signal 2 · ") ?? false, reports.last?.detail ?? "")
    }

    func testSIGTERMIsPassedOnToTheChild() throws {
        let port = try startEvlat()
        let started = Date()
        let run = try run(["watch", "sh", fixture, "sleep"], port: port, expecting: 2) { process in
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
        let port = try startEvlat()
        let run = try run(["watch", "sh", fixture, "sleep"], port: port, expecting: 2) { process in
            kill(process.processIdentifier, SIGINT)
        }
        XCTAssertEqual(run.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(run.process.terminationStatus, SIGINT)
    }

    // MARK: - The streams

    private let expectedOut = Data("out \u{1B}[31mred\u{1B}[0m ä\n\u{01}tail".utf8)
    private let expectedErr = Data("err line\nno newline".utf8)

    func testTheStreamsPassThroughByteForByte() throws {
        let port = try startEvlat()
        let run = try run(["watch", "sh", fixture, "bytes"], port: port, expecting: 2)
        XCTAssertEqual(run.stdout, expectedOut)
        XCTAssertEqual(run.stderr, expectedErr)
        XCTAssertEqual(run.process.terminationStatus, 0)
    }

    // MARK: - Evlat closed, or refusing

    func testWithoutEvlatTheCommandRunsAndNothingIsWritten() throws {
        let port = try closedPort()
        let bytes = try run(["watch", "sh", fixture, "bytes"], port: port)
        XCTAssertEqual(bytes.stdout, expectedOut)
        XCTAssertEqual(bytes.stderr, expectedErr)
        XCTAssertEqual(bytes.process.terminationStatus, 0)
        let five = try run(["watch", "sh", fixture, "exit", "5"], port: port)
        XCTAssertEqual(five.process.terminationStatus, 5)
        XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"], port: port)
        XCTAssertEqual(signal.process.terminationStatus, 0)
        XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
    }

    /// The usual "closed": Evlat quit and left its key file behind, so the
    /// post is made and the connection is refused. Still nothing written.
    func testAQuitEvlatsLeftoverKeyIsSilentToo() throws {
        let port = try startEvlat()
        listener?.stop()
        listener = nil
        let file = try XCTUnwrap(SignalKey.location(port: port, home: home, environment: [:]))
        XCTAssertNotNil(SignalKey.read(from: file), "the key outlives the listener")
        let five = try run(["watch", "sh", fixture, "exit", "5"], port: port)
        XCTAssertEqual(five.process.terminationStatus, 5)
        XCTAssertTrue(five.stdout.isEmpty && five.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"], port: port)
        XCTAssertEqual(signal.process.terminationStatus, 0)
        XCTAssertTrue(signal.stdout.isEmpty && signal.stderr.isEmpty)
    }

    /// A stale key: the endpoint says 403. `watch` still says nothing —
    /// its output is the command's — while `signal` says it in one line.
    func testARefusalIsSilentInWatchAndOneLineInSignal() throws {
        let port = try startEvlat()
        let file = try XCTUnwrap(SignalKey.location(port: port, home: home, environment: [:]))
        try Data("stale\n".utf8).write(to: file)
        let watch = try run(["watch", "sh", fixture, "exit", "4"], port: port)
        XCTAssertEqual(watch.process.terminationStatus, 4)
        XCTAssertTrue(watch.stdout.isEmpty && watch.stderr.isEmpty)
        let signal = try run(["signal", "x", "--done"], port: port)
        XCTAssertEqual(signal.process.terminationStatus, 1)
        let line = String(decoding: signal.stderr, as: UTF8.self)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, line)
        XCTAssertTrue(line.contains("403"), line)
        XCTAssertTrue(reports.isEmpty)
    }

    // MARK: - signal

    func testSignalSetsAndClearsARow() throws {
        let port = try startEvlat()
        let set = try run(["signal", "build", "--label", "Build", "--progress", "0.5"], port: port, expecting: 1)
        XCTAssertEqual(set.process.terminationStatus, 0)
        XCTAssertEqual(reports.last?.id, "build")
        XCTAssertEqual(reports.last?.progress, 0.5)
        XCTAssertEqual(reports.last?.ttl, 900)
        let clear = try run(["signal", "build", "--clear"], port: port, expecting: 1)
        XCTAssertEqual(clear.process.terminationStatus, 0)
        XCTAssertEqual(reports.last?.ttl, 0)
    }

    /// An argument error is 2 with the usage — and the subcommand is read from
    /// `argv[1]` only, so a wrapped command's `--list` is the command's.
    func testArgumentErrorsAndWhoseFlagsAreWhose() throws {
        let port = try closedPort()
        let wrong = try run(["signal", "--progress", "2", "x"], port: port)
        XCTAssertEqual(wrong.process.terminationStatus, 2)
        XCTAssertTrue(String(decoding: wrong.stderr, as: UTF8.self).contains("usage:"))
        let listed = try run(["watch", "sh", "-c", "echo \"$1\"", "sh", "--list"], port: port)
        XCTAssertEqual(listed.process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: listed.stdout, as: UTF8.self), "--list\n")
    }
}
