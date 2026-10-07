import XCTest
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// The sandbox watcher end to end against a **fake `sbx`**
/// (`Tests/Fixtures/fake-sbx`) and a fake daemon on a short unix socket: it
/// sets running Claude sandboxes up on connect and on `started`, drops a
/// stopped one's rows, survives the stream's loss, and takes Evlat's parts
/// out of the running ones when switched off — never `exec`ing a stopped
/// one, which would start it.
@MainActor
final class SandboxWatcherTests: XCTestCase {
    private var root: URL!
    private var daemon: FakeSandboxd!
    private var watcher: SandboxWatcher?
    private var forgotten: [String] = []
    private let plan = Agents.sandboxInstall(port: 48997)
    private var claude: String { Agents.sandboxAgent.rawValue }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A unix socket's path is at most 104 bytes: `$TMPDIR` and a short name.
        let socket = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sd-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertLessThan(socket.utf8.count, 104)
        daemon = try FakeSandboxd(path: socket)
        setenv("FAKE_SBX_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        watcher?.stop(removing: false)
        watcher = nil
        daemon.close()
        unsetenv("FAKE_SBX_FAIL")
        unsetenv("FAKE_SBX_VERSION")
        unsetenv("FAKE_SBX_SOCKET")
        unsetenv("FAKE_SBX_BANNER")
        unsetenv("FAKE_SBX_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func fakeSbx() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-sbx")
        let copy = root.appendingPathComponent("fake-sbx")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: source, to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            FreshExecutable.warm(copy.path)
        }
        return copy.path
    }

    /// `name agent status` lines.
    private func sandboxes(_ lines: String...) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("sandboxes"),
                                                       atomically: true, encoding: .utf8)
    }

    private func text(_ file: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    }

    private func runs() -> [[String]] {
        guard let text = text("log") else { return [] }
        return text.components(separatedBy: "--- run\n").dropFirst().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    private func rules() -> [String] {
        (text("rules") ?? "").split(separator: "\n").map(String.init)
    }

    private func installed(_ name: String) -> String? { text("files/\(name)") }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    @discardableResult
    private func start(runner: SandboxRunner? = nil, socketPath: String? = nil,
                       asksDaemon: Bool = false) throws -> SandboxWatcher {
        let made = SandboxWatcher(runner: try runner ?? SandboxRunner(sbxPath: fakeSbx()),
                                  socketPath: socketPath ?? daemon.path, asksDaemon: asksDaemon,
                                  plan: plan, delay: { _ in 0.05 },
                                  forget: { [weak self] in self?.forgotten.append($0) }, onChange: {})
        watcher = made
        made.start()
        return made
    }

    private func setup(_ name: String) -> SandboxWatcher.Setup? { watcher?.status.sandboxes[name]?.setup }

    // MARK: - Connecting

    func testOnConnectEveryRunningClaudeSandboxIsSetUpAndNoOtherIs() throws {
        try sandboxes("web \(claude) running", "box shell running", "old \(claude) stopped")
        try start()
        waitUntil("web ready") { self.setup("web") == .ready }

        XCTAssertEqual(installed("web"), plan.content, "the file's bytes, from stdin")
        XCTAssertEqual(rules(), ["web localhost:48997"])
        XCTAssertNil(installed("box"), "another agent's sandbox is not touched")
        XCTAssertNil(installed("old"))
        XCTAssertNil(text("started"), "a stopped sandbox is never exec'd: that would start it")
        XCTAssertEqual(setup("box"), .otherAgent)
        XCTAssertEqual(setup("old"), .stopped)
        XCTAssertEqual(watcher?.status.daemon, .connected)
        XCTAssertTrue(forgotten.contains("old"), "a stopped sandbox's rows go")
        let allows = runs().filter { $0.starts(with: ["policy", "allow"]) }
        XCTAssertTrue(allows.allSatisfy { $0.contains("--sandbox") }, "never the global policy")
        XCTAssertEqual(watcher?.status.sandboxes["web"]?.folder, "/work/web", "the list's folder")
        XCTAssertEqual(watcher?.status.version, "0.46.0")
        XCTAssertEqual(runs().filter { $0 == ["version"] }.count, 1, "the version is asked once")
        XCTAssertFalse(runs().contains(SandboxInstall.daemonStatus.arguments),
                       "a socket given by hand is never asked about")
    }

    /// Settings says a version other than the one measured: it is read.
    func testTheVersionIsReadOnConnect() throws {
        setenv("FAKE_SBX_VERSION", "0.47.2", 1)
        try start()
        waitUntil("version") { self.watcher?.status.version == "0.47.2" }
    }

    /// A socket path a unix address cannot hold opens no stream — it would
    /// fail on every try and read as "sbx isn't running" — and says so;
    /// what runs now is still set up.
    func testASocketPathTooLongIsSaidAndWhatRunsIsSetUp() throws {
        try sandboxes("web \(claude) running")
        let long = "/" + String(repeating: "s", count: SandboxWatcher.socketPathLimit)
        try start(socketPath: long)
        XCTAssertEqual(watcher?.status.socketTooLong, true)
        XCTAssertEqual(watcher?.status.socket, long)
        XCTAssertEqual(watcher?.status.daemonUnsaid, false, "given by hand: nothing was asked")
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(watcher?.status.daemon, .off)
        XCTAssertEqual(daemon.connections, 0)
    }

    /// `sbx` moves its socket off the default path under a long home
    /// (0.46.0: `~/.sbx/run/d`, then `/tmp`), so the default is only asked
    /// about: the stream opens where `sbx` says, before anything else runs.
    func testTheStreamOpensWhereSbxSaysItsDaemonIs() throws {
        try sandboxes("web \(claude) running")
        setenv("FAKE_SBX_SOCKET", daemon.path, 1)
        try start(socketPath: "/nowhere/sandboxd.sock", asksDaemon: true)
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(watcher?.status.daemon, .connected)
        XCTAssertEqual(watcher?.status.socket, daemon.path)
        XCTAssertFalse(watcher?.status.socketTooLong ?? true)
        XCTAssertEqual(watcher?.status.daemonUnsaid, false)
        XCTAssertEqual(runs().first, SandboxInstall.daemonStatus.arguments, "asked first")
        XCTAssertEqual(runs().filter { $0 == SandboxInstall.daemonStatus.arguments }.count, 1)
    }

    /// With its daily update check due `sbx` prints a notice after the
    /// JSON, on stdout: the answer and the list are still read.
    func testTheUpdateNoticeAfterTheAnswerIsLeftOut() throws {
        try sandboxes("web \(claude) running")
        setenv("FAKE_SBX_SOCKET", daemon.path, 1)
        setenv("FAKE_SBX_BANNER", "1", 1)
        try start(socketPath: "/nowhere/sandboxd.sock", asksDaemon: true)
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(watcher?.status.socket, daemon.path)
        XCTAssertEqual(watcher?.status.daemon, .connected)
    }

    /// An `sbx` that cannot say where its daemon is: the default is tried.
    func testTheDefaultIsTriedWhenSbxCannotSay() throws {
        try sandboxes("web \(claude) running")
        try start(socketPath: daemon.path, asksDaemon: true)
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(watcher?.status.socket, daemon.path)
        XCTAssertEqual(watcher?.status.daemon, .connected)
        XCTAssertEqual(watcher?.status.daemonUnsaid, true)
        XCTAssertTrue(runs().contains(SandboxInstall.daemonStatus.arguments))
    }

    /// Unanswered, and the default too long — a long home's: said as such,
    /// and what runs now is still set up.
    func testAnUnansweredLongDefaultIsSaidAsUnanswered() throws {
        try sandboxes("web \(claude) running")
        let long = "/" + String(repeating: "s", count: SandboxWatcher.socketPathLimit)
        try start(socketPath: long, asksDaemon: true)
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(watcher?.status.socketTooLong, true)
        XCTAssertEqual(watcher?.status.daemonUnsaid, true)
        XCTAssertEqual(daemon.connections, 0)
    }

    func testAStartedSandboxIsSetUp() throws {
        try sandboxes("web \(claude) stopped")
        try start()
        waitUntil("listed") { self.setup("web") == .stopped }
        try sandboxes("web \(claude) running")
        daemon.send(event: "started", name: "web")
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(installed("web"), plan.content)
        XCTAssertNil(text("started"))
    }

    func testAStoppedSandboxsRowsGoAndItIsSetUpAgainWhenItStarts() throws {
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("web ready") { self.setup("web") == .ready }
        forgotten = []
        daemon.send(event: "stopped", name: "web")
        waitUntil("forgotten") { self.forgotten == ["web"] }
        XCTAssertEqual(setup("web"), .stopped)

        try FileManager.default.removeItem(at: root.appendingPathComponent("files/web"))
        daemon.send(event: "started", name: "web")
        waitUntil("web ready again") { self.installed("web") != nil && self.setup("web") == .ready }
    }

    func testADeletedSandboxGoes() throws {
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("web ready") { self.setup("web") == .ready }
        daemon.send(event: "deleted", name: "web")
        waitUntil("gone") { self.watcher?.status.sandboxes["web"] == nil }
        XCTAssertTrue(forgotten.contains("web"))
    }

    /// The stream's loss drops no row; the watcher connects again and reads
    /// the list again.
    func testALostStreamKeepsTheRowsAndConnectsAgain() throws {
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("web ready") { self.setup("web") == .ready }
        forgotten = []
        let installs = runs().filter { $0.first == "exec" }.count
        daemon.dropClient()
        waitUntil("connected again") { self.daemon.connections >= 2 && self.watcher?.status.daemon == .connected }
        waitUntil("set up again") { self.runs().filter { $0.first == "exec" }.count > installs }
        waitUntil("ready") { self.setup("web") == .ready }
        XCTAssertEqual(forgotten, [], "a lost stream drops no row")
    }

    func testNoDaemonIsTriedAgainWithoutATightLoop() throws {
        daemon.close()
        try start()
        waitUntil("disconnected") { self.watcher?.status.daemon == .disconnected }
        XCTAssertNil(text("log"), "nothing is listed with no daemon")
    }

    /// A daemon that answers with something else is not a connection: no
    /// sandbox is listed or set up on it, and the line says so.
    func testARefusedStreamSetsNothingUp() throws {
        daemon.head = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n"
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("refused") { self.watcher?.status.daemon == .refused && self.daemon.connections >= 2 }
        XCTAssertNil(text("log"), "nothing is run for a refused stream")
    }

    // MARK: - Names, other lines, failures

    func testAnInvalidNameMakesNoCommandAndOtherLinesAreIgnored() throws {
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("web ready") { self.setup("web") == .ready }
        let before = runs().count
        daemon.send(line: #"{"type":"policy.network","action":"allowed","data":{"sandbox.lifecycle":1}}"#)
        daemon.send(event: "paused", name: "web")
        try sandboxes("web \(claude) running", "-rf \(claude) running")
        daemon.send(event: "started", name: "-rf")
        waitUntil("listed again") { self.runs().count > before }
        waitUntil("idle") { !(self.watcher.map { $0.status.sandboxes.values.contains { $0.setup == .installing } } ?? true) }
        XCTAssertFalse(runs().contains { $0.contains("-rf") && $0.first != "ls" }, "no command for a name that is not one")
        XCTAssertNil(watcher?.status.sandboxes["-rf"])
    }

    func testAFailedSetupSaysWhyAndIsTriedAgain() throws {
        setenv("FAKE_SBX_FAIL", "web", 1)
        try sandboxes("web \(claude) running")
        try start()
        waitUntil("failed") { if case .failed = self.setup("web") { return true } else { return false } }
        XCTAssertEqual(setup("web"), .failed("exec failed: the VM is not answering"), "its first stderr line")

        unsetenv("FAKE_SBX_FAIL")
        watcher?.retry("web")
        waitUntil("ready") { self.setup("web") == .ready }
    }

    // MARK: - The switch off

    func testTurnedOffItComesOutOfRunningSandboxesAndNeverStartsAStoppedOne() throws {
        try sandboxes("web \(claude) running", "old \(claude) stopped", "box shell running")
        let runner = SandboxRunner(sbxPath: try fakeSbx())
        let watcher = try start(runner: runner)
        waitUntil("web ready") { self.setup("web") == .ready }
        XCTAssertEqual(rules(), ["web localhost:48997"])

        watcher.stop(removing: true)
        self.watcher = nil
        waitUntil("removed") { self.installed("web") == nil && self.rules().isEmpty }
        let removal = runs().first { $0.starts(with: ["policy", "rm"]) }
        XCTAssertEqual(removal, ["policy", "rm", "network", "--sandbox", "web", "--resource", "localhost:48997", "--force"])
        XCTAssertFalse(runs().contains { $0.contains("old") }, "a stopped sandbox is not touched")
        XCTAssertFalse(runs().contains { $0.contains("box") }, "another agent's is not touched")
        XCTAssertNil(text("started"))
        waitUntil("removal done") { !runner.isBusy("web") }
    }

    // MARK: - The runner

    func testTheRunnerRefusesASecondJobForTheSameSandbox() throws {
        let runner = SandboxRunner(sbxPath: try fakeSbx())
        try sandboxes("web \(claude) running")
        let commands = try XCTUnwrap(plan.install(sandbox: "web"))
        var done = 0
        XCTAssertTrue(runner.run(commands, sandbox: "web") { _ in done += 1 })
        XCTAssertFalse(runner.run(commands, sandbox: "web") { _ in XCTFail("refused, never called") })
        XCTAssertTrue(runner.isBusy("web"))
        waitUntil("done") { done == 1 }
        XCTAssertFalse(runner.isBusy("web"))
    }

    /// A job's sandbox that stopped while the job waited is not `exec`ed:
    /// that would start it.
    func testAJobForASandboxThatStoppedRunsNothing() throws {
        let runner = SandboxRunner(sbxPath: try fakeSbx())
        try sandboxes("web \(claude) stopped")
        var answer: Result<Void, SandboxRunner.Failure>?
        XCTAssertTrue(runner.run(try XCTUnwrap(plan.install(sandbox: "web")), sandbox: "web") { answer = $0 })
        waitUntil("done") { answer != nil }
        guard case .failure(let failure)? = answer else { return XCTFail("a stopped sandbox is not set up") }
        XCTAssertTrue(failure.notRunning)
        XCTAssertEqual(runs().map { $0.first }, ["ls"], "only the list ran")
        XCTAssertNil(text("started"))
    }

    /// Switched on again before the removal read its list: the old
    /// watcher's removal is let go and the new install stays.
    func testAnAbandonedRemovalTakesNothingOut() throws {
        try sandboxes("web \(claude) running")
        let watcher = try start()
        waitUntil("web ready") { self.setup("web") == .ready }
        let lists = runs().filter { $0.first == "ls" }.count
        watcher.stop(removing: true)
        watcher.abandon()
        self.watcher = nil
        waitUntil("listed") { self.runs().filter { $0.first == "ls" }.count > lists }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotNil(installed("web"))
        XCTAssertEqual(rules(), ["web localhost:48997"])
        XCTAssertFalse(runs().contains { $0.starts(with: ["policy", "rm"]) })
    }

    func testAMissingSbxFailsWithAReason() {
        let answer = SandboxRunner.run("/nonexistent/sbx", SandboxInstall.list, deadline: 5)
        XCTAssertNotNil(answer.failure)
    }

    // MARK: - Where, and isolation

    func testTheSourceFollowsIsolation() {
        let home = URL(fileURLWithPath: "/Users/u")
        XCTAssertEqual(SandboxWatcher.source(environment: [:], home: home),
                       SandboxWatcher.Source(sbx: nil, socket:
                        "/Users/u/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/sandboxd.sock",
                                             asksDaemon: true),
                       "the default, asked about")
        XCTAssertEqual(SandboxWatcher.source(environment: ["EVLAT_SBX_SOCKET": "/x.sock"], home: home),
                       SandboxWatcher.Source(sbx: nil, socket: "/x.sock"), "given by hand: never asked")
        XCTAssertNil(SandboxWatcher.source(environment: [:], home: nil), "no home: never the real socket")
        XCTAssertNil(SandboxWatcher.source(environment: ["EVLAT_SOCKET": "/tmp/e.sock"], home: home),
                     "isolated: no sbx, no daemon")
        XCTAssertNil(SandboxWatcher.source(environment: ["EVLAT_SOCKET": "/tmp/e.sock", "EVLAT_SBX": "/x/sbx"], home: home))
        XCTAssertNil(SandboxWatcher.source(environment: ["EVLAT_SOCKET": "/tmp/e.sock", "EVLAT_SBX_SOCKET": "/x.sock"],
                                           home: home))
        XCTAssertEqual(SandboxWatcher.source(environment: ["EVLAT_SOCKET": "/tmp/e.sock", "EVLAT_SBX": "/x/sbx",
                                                           "EVLAT_SBX_SOCKET": "/x.sock"], home: home),
                       SandboxWatcher.Source(sbx: "/x/sbx", socket: "/x.sock"))
    }

    func testTheSwitchIsOffWhenNothingIsStoredAndForcedByTheEnvironment() {
        XCTAssertFalse(AppController().sandboxesEnabled)
        XCTAssertEqual(AppController.forcedSandboxes(["EVLAT_SANDBOXES": "on"]), true)
        XCTAssertEqual(AppController.forcedSandboxes(["EVLAT_SANDBOXES": "off"]), false)
        XCTAssertNil(AppController.forcedSandboxes([:]))
    }

    /// The switch in a controller with no storage: on, the listener binds
    /// and, once it listens, the watcher sets the sandboxes up with the
    /// bound port; off, Evlat's parts come out and the listener goes.
    func testTheSwitchStartsAndStopsEverything() throws {
        try sandboxes("web \(claude) running")
        let controller = AppController()
        controller.sandboxSource = SandboxWatcher.Source(sbx: try fakeSbx(), socket: daemon.path)
        controller.sandboxDelay = { _ in 0.05 }
        controller.sandboxPort = { 0 }
        controller.applySandboxes()
        XCTAssertNil(controller.sandbox, "off: nothing listens")

        controller.setSandboxesEnabled(true)
        let sandbox = try XCTUnwrap(controller.sandbox)
        waitUntil("set up") { self.installed("web") != nil }
        let port = try XCTUnwrap(sandbox.boundPort)
        XCTAssertEqual(installed("web"), Agents.sandboxInstall(port: port).content, "the bound port's hooks")
        XCTAssertEqual(rules(), ["web localhost:\(port)"])

        XCTAssertEqual(controller.sbxFound, true)
        XCTAssertEqual(controller.sandboxesView.availability, .found)
        XCTAssertEqual(controller.sandboxesView.listener, .listening)

        controller.setSandboxesEnabled(false)
        XCTAssertNil(controller.sandbox)
        XCTAssertNil(controller.sandboxWatcher)
        waitUntil("removed") { self.installed("web") == nil && self.rules().isEmpty }
        // Settings still says what came out: the retired watcher's.
        waitUntil("said removed") { controller.sandboxesView.watcher?.sandboxes["web"]?.setup == .removed }
        XCTAssertFalse(controller.sandboxesView.on)

        // Off and on at once: the old removal is let go or followed by the
        // new install, never left to undo it.
        controller.setSandboxesEnabled(true)
        waitUntil("set up again") { self.controller(controller, has: "web", .ready) }
        controller.setSandboxesEnabled(false)
        controller.setSandboxesEnabled(true)
        waitUntil("set up after the removal", timeout: 15) {
            guard let port = controller.sandbox?.boundPort else { return false }
            return self.controller(controller, has: "web", .ready) && self.installed("web") != nil
                && self.rules().contains("web localhost:\(port)")
        }
        // A test's port is a new one each time (`0`): a let-go removal
        // leaves the earlier port's rule, which the fixed port never does.
        let last = try XCTUnwrap(controller.sandbox?.boundPort)
        controller.setSandboxesEnabled(false)
        waitUntil("removed at the end") {
            self.installed("web") == nil && !self.rules().contains("web localhost:\(last)")
        }
    }

    private func controller(_ controller: AppController, has name: String, _ setup: SandboxWatcher.Setup) -> Bool {
        controller.sandboxWatcher?.status.sandboxes[name]?.setup == setup
    }

    /// A controller with no source — an isolated process not handed one,
    /// every other test — listens but runs no `sbx` and opens no daemon.
    func testWithoutASourceNothingRuns() throws {
        let controller = AppController()
        controller.sandboxSource = nil
        controller.sandboxPort = { 0 }
        controller.setSandboxesEnabled(true)
        let sandbox = try XCTUnwrap(controller.sandbox)
        defer { controller.setSandboxesEnabled(false) }
        waitUntil("listening") { sandbox.boundPort != nil }
        XCTAssertNil(controller.sandboxWatcher)
        XCTAssertEqual(daemon.connections, 0)
    }
}

/// The `sbx` daemon's `/events`, as measured on 0.46.0: one `200` head,
/// then chunked NDJSON lines for as long as the connection lives. One
/// client at a time, the newest.
final class FakeSandboxd {
    let path: String
    /// What it answers the request with; a test sets another to be refused.
    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"
    private let queue = DispatchQueue(label: "fake-sandboxd")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var client: Int32 = -1
    private let lock = NSLock()
    private var accepted = 0

    var connections: Int { lock.withLock { accepted } }

    init(path: String) throws {
        self.path = path
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // The request, up to its blank line.
        var request = [UInt8]()
        var byte: UInt8 = 0
        while !request.suffix(4).elementsEqual([13, 10, 13, 10]), read(fd, &byte, 1) == 1 { request.append(byte) }
        write(fd, head)
        lock.withLock {
            if client >= 0 { Darwin.close(client) }
            client = fd
            accepted += 1
        }
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// One line, as its own chunk.
    func send(line: String) {
        queue.async { [self] in
            let body = line + "\n"
            let fd = lock.withLock { client }
            guard fd >= 0 else { return }
            write(fd, String(Array(body.utf8).count, radix: 16) + "\r\n" + body + "\r\n")
        }
    }

    func send(event action: String, name: String) {
        send(line: #"{"type":"sandbox.lifecycle","action":"\#(action)","sandbox_name":"\#(name)","sandbox_id":"id-\#(name)"}"#)
    }

    /// The daemon goes away for this client.
    func dropClient() {
        queue.async { [self] in
            lock.withLock {
                if client >= 0 { Darwin.close(client) }
                client = -1
            }
        }
    }

    func close() {
        queue.sync {
            source?.cancel()
            source = nil
            if listener >= 0 { Darwin.close(listener) }
            listener = -1
            lock.withLock {
                if client >= 0 { Darwin.close(client) }
                client = -1
            }
        }
        unlink(path)
    }
}
