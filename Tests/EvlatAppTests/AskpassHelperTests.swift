import XCTest
import EvlatCore
@testable import EvlatApp

/// The **built binary** as `ssh` runs it for a password: the prompt alone in
/// `argv[1]`, the mark in the environment, against a listener this test opens
/// on a free port. What is pinned is what `ssh` reads back: an answer is
/// exactly `answer\n` on stdout with exit 0; anything else is an empty stdout
/// and a non-zero exit, after which `ssh` sends no password at all.
final class AskpassHelperTests: XCTestCase {
    private let token = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    private let prompt = "nobodyx@127.0.0.1's password: "
    private var listener: HookListener?
    private var asked: [Askpass.Request] = []
    private var processes: [Process] = []

    /// A freshly linked binary's first run pays for macOS's assessment
    /// (once ~50 s): paid here, untimed, not inside a test's 15 s wait.
    override class func setUp() {
        super.setUp()
        FreshExecutable.warm(Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Evlat").path)
    }

    override func tearDown() {
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
        listener?.stop()
        listener = nil
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat")
    }

    /// A listener that holds askpass requests, as the app's does, and answers
    /// each with `answer`.
    private func startEvlat(answering answer: LocalAPI.Response) throws -> UInt16 {
        var made: HookListener?
        let listener = HookListener(port: 0, onAbandoned: { _ in }) { [weak self] delivery in
            guard case .askpass(let request) = delivery else { return }
            self?.asked.append(request)
            made?.answer(request.id, with: answer)
        }
        made = listener
        listener.start()
        self.listener = listener
        guard case .listening(let port) = listener.awaitSettled(timeout: 5) else {
            throw XCTSkip("listener did not come up: \(listener.status.text)")
        }
        return port
    }

    private func closedPort() throws -> UInt16 {
        let probe = HookListener(port: 0) { _ in }
        probe.start()
        defer { probe.stop() }
        guard case .listening(let port) = probe.awaitSettled(timeout: 5) else { throw XCTSkip("no free port") }
        return port
    }

    private struct Run {
        let process: Process
        let stdout: Data
        let stderr: Data
    }

    /// Runs the helper to its end, pumping the main queue so the delivery
    /// (and the answer written from it) happens.
    private func ask(port: UInt16, mark: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = binary
        process.arguments = [prompt]
        var environment = ProcessInfo.processInfo.environment
        environment[Askpass.environmentKey] = mark ?? Askpass.value(Askpass.Mark(port: port, token: token))
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let ended = expectation(description: "exit")
        process.terminationHandler = { _ in ended.fulfill() }
        try process.run()
        processes.append(process)
        wait(for: [ended], timeout: 15)
        return Run(process: process, stdout: out.fileHandleForReading.readDataToEndOfFile(),
                   stderr: err.fileHandleForReading.readDataToEndOfFile())
    }

    func testAnAnswerIsPrintedWithANewline() throws {
        let port = try startEvlat(answering: LocalAPI.Response(status: .ok, body: "s3cr€t pass"))
        let run = try ask(port: port)
        XCTAssertEqual(run.process.terminationStatus, 0)
        XCTAssertEqual(run.stdout, Data("s3cr€t pass\n".utf8))
        XCTAssertTrue(run.stderr.isEmpty)
        // The prompt came whole, the token through the header and not argv.
        XCTAssertEqual(asked.map(\.prompt), [prompt])
        XCTAssertEqual(asked.map(\.token), [token])
        XCTAssertFalse((run.process.arguments ?? []).contains { $0.contains(token) })
    }

    /// No answer: `ssh` must get nothing to send.
    func testARefusalPrintsNothingAndFails() throws {
        let port = try startEvlat(answering: LocalAPI.noAnswer)
        let run = try ask(port: port)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(run.process.terminationStatus, 1)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertTrue(run.stderr.isEmpty)
    }

    func testNoEvlatPrintsNothingAndFails() throws {
        let run = try ask(port: try closedPort())
        XCTAssertEqual(run.process.terminationStatus, 1)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertTrue(run.stderr.isEmpty)
    }

    /// A broken mark is no helper: the prompt is a stray word, the usage is
    /// printed and nothing is asked — and the bar never opens.
    func testABrokenMarkIsAUsageError() throws {
        let port = try startEvlat(answering: LocalAPI.Response(status: .ok, body: "x"))
        let run = try ask(port: port, mark: "\(port):short")
        XCTAssertEqual(run.process.terminationStatus, SignalCommand.usageExitCode)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertTrue(asked.isEmpty)
    }
}
