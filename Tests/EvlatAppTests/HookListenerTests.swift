import XCTest
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// The listener against a **real socket**. Everything a request means is
/// already pinned without one (`LocalAPITests`, `HTTPRequestTests`); what is
/// left to check here is exactly what those cannot see — that the port is
/// actually taken, that the answer comes back, and that it does not wait for
/// the main queue.
final class HookListenerTests: XCTestCase {
    /// Port `0` asks the system for a free one. Binding 48151 in a test would
    /// fight the running app, and a fixed test port would fight a second copy
    /// of the test suite.
    private static let anyPort: UInt16 = 0

    private func boundPort(_ listener: HookListener,
                           file: StaticString = #filePath, line: UInt = #line) -> UInt16? {
        guard case .listening(let port) = listener.awaitSettled(timeout: 5) else {
            XCTFail("listener did not come up: \(listener.status.text)", file: file, line: line)
            return nil
        }
        return port
    }

    // MARK: - It listens, and it answers

    func testAHookPostIsAnsweredWithAnEmptyObjectAndProducesAnEvent() throws {
        let arrived = expectation(description: "event on the main queue")
        var received: HookEvent?
        let listener = HookListener(port: Self.anyPort) { delivery in
            XCTAssertTrue(Thread.isMainThread, "events are delivered on the main queue")
            if case .hook(let event) = delivery { received = event }
            arrived.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        let answer = post(port: port, path: "/hook",
                          body: #"{"hook_event_name":"PreToolUse","session_id":"s-1"}"#)
        // Exactly `{}`: the installed command throws the body away, but if it
        // ever reached Claude Code a stray JSON object would answer a
        // permission prompt on the user's behalf.
        XCTAssertEqual(answer.body, "{}")
        XCTAssertEqual(answer.status, 200)

        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(received?.name, "PreToolUse")
        XCTAssertEqual(received?.sessionID, "s-1")
        XCTAssertEqual(received?.source, .claude)
    }

    /// The status line's relay reaches the same socket and comes out as a usage
    /// report, never as a hook event.
    func testAUsagePostIsAnsweredWithAnEmptyObjectAndDeliversAReport() throws {
        let arrived = expectation(description: "report on the main queue")
        var received: UsageReport?
        let listener = HookListener(port: Self.anyPort) { delivery in
            XCTAssertTrue(Thread.isMainThread)
            if case .usage(let report) = delivery { received = report }
            arrived.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        let answer = post(port: port, path: "/usage/claude",
                          body: #"{"rate_limits":{"seven_day":{"used_percentage":41,"resets_at":1790772967}}}"#)
        XCTAssertEqual(answer.body, "{}")
        XCTAssertEqual(answer.status, 200)

        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(received?.windows.map(\.minutes), [10080])
    }

    /// The route table is `EvlatCore`'s, but the transport has to reach it: a
    /// listener that answered `{}` to everything would pass the test above.
    func testHealthAndUnknownPathsComeBackThroughTheSameSocket() throws {
        let listener = HookListener(port: Self.anyPort) { _ in }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        XCTAssertEqual(get(port: port, path: "/health").body, "{\"ok\":true}")
        XCTAssertEqual(get(port: port, path: "/nowhere").status, 404)
    }

    /// The claim the whole answering design rests on: the installed command
    /// runs `curl -s -m 2` under a hook with `timeout: 5`, so the agent is
    /// **waiting** on this write. Here the main queue is held for longer than
    /// the UI could plausibly hold it and the answer still has to come back.
    func testTheAnswerDoesNotWaitForTheMainQueue() throws {
        let listener = HookListener(port: Self.anyPort) { _ in }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        let done = DispatchSemaphore(value: 0)
        var body: String?
        DispatchQueue.global().async {
            body = self.post(port: port, path: "/hook", body: "{}").body
            done.signal()
        }
        // The test runs on the main thread, so sleeping here IS the blocked
        // main queue. An answer written from the main queue would arrive only
        // after this returns.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success,
                       "the answer was still waiting for the main queue")
        XCTAssertEqual(body, "{}")
    }

    // MARK: - A busy port is visible

    /// `allowLocalEndpointReuse` is SO_REUSEADDR — it lets a restart rebind a
    /// port still in TIME_WAIT. It must **not** be SO_REUSEPORT: two Evlats
    /// sharing one port would split the hook events between them at random,
    /// and every symptom would look like "some events go missing".
    ///
    /// This is also the phase's "a busy port is not silent" test: the second
    /// listener has to come back with a reason, not with silence.
    func testASecondListenerCannotTakeTheSamePort() throws {
        let first = HookListener(port: Self.anyPort) { _ in }
        first.start()
        defer { first.stop() }
        let port = try XCTUnwrap(boundPort(first))

        let second = HookListener(port: port) { _ in }
        second.start()
        defer { second.stop() }
        guard case .unavailable(let reported, let reason) = second.awaitSettled(timeout: 5) else {
            XCTFail("two listeners bound the same port: \(second.status.text)")
            return
        }
        XCTAssertEqual(reported, port)
        XCTAssertFalse(reason.isEmpty, "an unusable port has to say why")
    }

    // MARK: - Evlat's socket

    /// A file a killed listener left: bound, closed, never unlinked. A
    /// connection to it is refused.
    static func leaveStaleSocket(at path: String) throws {
        let fd = try XCTUnwrap(UnixSocket.open())
        defer { close(fd) }
        var address = try XCTUnwrap(UnixSocket.address(path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        XCTAssertEqual(UnixSocket.probe(path), .stale)
    }

    private func socketListener(_ path: String, origin: LocalAPI.Origin = .local,
                                onDelivery: @escaping (LocalAPI.Delivery) -> Void = { _ in }) -> HookListener {
        let listener = HookListener(transport: .unix(path), origin: origin, onDelivery: onDelivery)
        listener.start()
        listener.awaitSettled(timeout: 5)
        return listener
    }

    /// `curl --unix-socket`, as the installed bytes will run it.
    private func curl(_ path: String, route: String, body: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-s", "--unix-socket", path, "-m", "5", "-H", "Content-Type: application/json",
                             "--data-binary", body, "http://127.0.0.1:48151\(route)"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func testASocketTakesAHookFromCurlInADirectoryOnlyTheUserEnters() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        // A folder that is not there yet is made, and made the user's alone.
        let path = directory + "/run/evlat.sock"
        let arrived = expectation(description: "event on the main queue")
        var received: HookEvent?
        let listener = socketListener(path) { delivery in
            if case .hook(let event) = delivery { received = event }
            arrived.fulfill()
        }
        defer { listener.stop() }
        XCTAssertEqual(listener.status, .listeningAt(path))
        XCTAssertEqual(listener.boundPath, path)
        XCTAssertNil(listener.boundPort)
        XCTAssertEqual(mode(directory + "/run"), 0o700)

        let answer = try curl(path, route: "/hook", body: #"{"hook_event_name":"Stop","session_id":"s-2"}"#)
        XCTAssertEqual(answer, "{}")
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(received?.name, "Stop")
        XCTAssertEqual(received?.sessionID, "s-2")
    }

    /// An existing folder with a looser mode is brought to `0700`: the file
    /// takes the umask's mode, so the folder is the guard.
    func testAnOpenDirectoryIsClosed() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        XCTAssertEqual(chmod(directory, 0o755), 0)
        let listener = socketListener(directory + "/evlat.sock")
        defer { listener.stop() }
        XCTAssertNotNil(listener.boundPath, listener.status.text)
        XCTAssertEqual(mode(directory), 0o700)
    }

    /// A link where the folder should be could lead anywhere: refused, and
    /// nothing is made at its far end.
    func testALinkedDirectoryIsRefused() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        try FileManager.default.createDirectory(atPath: directory + "/real", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: directory + "/run", withDestinationPath: directory + "/real")
        let path = directory + "/run/evlat.sock"
        let listener = socketListener(path)
        defer { listener.stop() }
        XCTAssertEqual(listener.status, .unavailableAt(path, UnixSocket.DirectoryRefusal.link.text))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/real/evlat.sock"))
    }

    /// A live socket is another Evlat's: the second listener says so, and
    /// neither takes nor deletes it — the first still answers.
    func testALiveSocketIsNeitherTakenNorDeleted() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        let path = directory + "/evlat.sock"
        let first = socketListener(path)
        defer { first.stop() }
        XCTAssertNotNil(first.boundPath, first.status.text)

        let second = socketListener(path)
        XCTAssertEqual(second.status, .unavailableAt(path, HookListener.heldByAnother))
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(UnixHTTP.send("/health", method: "GET", socket: path, timeout: 5),
                       .status(200, Data(#"{"ok":true}"#.utf8)))
    }

    /// A file nobody answers on is a killed Evlat's: cleared and bound.
    func testAStaleSocketIsTaken() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        let path = directory + "/evlat.sock"
        try Self.leaveStaleSocket(at: path)
        let listener = socketListener(path)
        defer { listener.stop() }
        XCTAssertEqual(listener.status, .listeningAt(path))
        XCTAssertEqual(UnixSocket.probe(path), .live)
    }

    /// `stop()` removes its own file, and only its own: one another Evlat
    /// bound at the same path after this one's was cleared stays.
    func testStopRemovesItsOwnFileAndNoOneElses() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        let path = directory + "/evlat.sock"
        let alone = socketListener(path)
        XCTAssertNotNil(alone.boundPath, alone.status.text)
        alone.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "its own file goes with it")

        let first = socketListener(path)
        XCTAssertNotNil(first.boundPath, first.status.text)
        unlink(path)
        let second = socketListener(path)
        defer { second.stop() }
        XCTAssertNotNil(second.boundPath, second.status.text)
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the other one's file stays")
        XCTAssertEqual(UnixSocket.probe(path), .live)
    }

    /// A path no unix address holds can never be bound: said, not retried.
    func testAPathTooLongIsUnavailable() throws {
        let path = "/tmp/" + String(repeating: "s", count: EvlatSocket.pathLimit)
        let listener = socketListener(path)
        defer { listener.stop() }
        guard case .unavailableAt(let reported, _) = listener.status else {
            return XCTFail("a path past the address bound: \(listener.status.text)")
        }
        XCTAssertEqual(reported, path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The socket asks no key for `/signal`: its folder is the user's alone.
    /// The port's local listener still asks (above), and a sandbox's role has
    /// no `/signal` at all.
    func testTheSocketTakesASignalWithoutAKey() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        let arrived = expectation(description: "signal delivered")
        let listener = socketListener(directory + "/evlat.sock") { delivery in
            if case .signal(let report) = delivery, report.id == "build" { arrived.fulfill() }
        }
        defer { listener.stop() }
        let body = Data(#"{"id":"build","ttl":60,"phase":"working"}"#.utf8)
        XCTAssertEqual(SignalClient.send(body, socket: directory + "/evlat.sock", timeout: 5), .status(200, "{}"))
        wait(for: [arrived], timeout: 5)
        let sandbox = socketListener(directory + "/sandbox.sock", origin: .sandbox)
        defer { sandbox.stop() }
        guard case .status(404, _) = SignalClient.send(body, socket: directory + "/sandbox.sock", timeout: 5) else {
            return XCTFail("a sandbox has no /signal")
        }
    }

    /// Nobody there is said at once, never waited out: a command must not
    /// stall a build because the bar is closed.
    func testNoSocketIsNotRunningAtOnce() throws {
        let directory = try ShortDirectory.make()
        defer { ShortDirectory.remove(directory) }
        let started = Date()
        XCTAssertEqual(UnixHTTP.send("/health", method: "GET", socket: directory + "/evlat.sock", timeout: 5),
                       .notRunning)
        try Self.leaveStaleSocket(at: directory + "/evlat.sock")
        XCTAssertEqual(SignalClient.send(Data("{}".utf8), socket: directory + "/evlat.sock", timeout: 5),
                       .notRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a timeout was waited out")
    }

    /// The app's socket is the rule's under its own home: a controller
    /// without one — every test — binds none, and an isolated process
    /// without `EVLAT_SOCKET` none either.
    func testTheAppBindsTheRulesSocketOnlyWithAHome() {
        let home = URL(fileURLWithPath: "/Users/a", isDirectory: true)
        XCTAssertNil(AppController.socketPath(home: nil, environment: [:]))
        XCTAssertNil(AppController.socketPath(home: nil, environment: ["EVLAT_SOCKET": "/tmp/e/x.sock"]))
        XCTAssertEqual(AppController.socketPath(home: home, environment: [:]), "/Users/a/.config/evlat/run/evlat.sock")
        XCTAssertNil(AppController.socketPath(home: home, environment: ["EVLAT_PORT": "48999"]))
        XCTAssertEqual(AppController.socketPath(home: home, environment: ["EVLAT_PORT": "48999",
                                                                          "EVLAT_SOCKET": "/tmp/e/x.sock"]),
                       "/tmp/e/x.sock")
    }

    // MARK: - Which port

    func testThePortIsTheDefaultUnlessTheEnvironmentSaysOtherwise() {
        XCTAssertEqual(HookListener.resolvePort([:]),
                       HookListener.PortChoice(port: LocalAPI.defaultPort, rejectedOverride: nil))
        XCTAssertEqual(HookListener.resolvePort(["EVLAT_PORT": "48999"]),
                       HookListener.PortChoice(port: 48999, rejectedOverride: nil))
    }

    /// An override that cannot be used is **reported**, not silently ignored:
    /// the app would otherwise listen on 48151 while the developer believed it
    /// was somewhere else. `0` is a valid port to bind ("any free one") and is
    /// still refused here, because an endpoint on a port nobody can guess is
    /// the same silent failure the whole status enum exists for.
    func testAnUnusableOverrideIsReportedAndTheDefaultStands() {
        for raw in ["", "0", "-1", "70000", "48151x", "elli"] {
            let choice = HookListener.resolvePort(["EVLAT_PORT": raw])
            XCTAssertEqual(choice.port, LocalAPI.defaultPort, "EVLAT_PORT=\(raw)")
            // The empty value is "not set", not "set to something unusable".
            XCTAssertEqual(choice.rejectedOverride, raw.isEmpty ? nil : raw, "EVLAT_PORT=\(raw)")
        }
    }

    // MARK: - The capture flag

    func testCaptureWindowIsReadFromTheArguments() {
        XCTAssertNil(AppController.captureWindow(["Evlat", "--list"]))
        XCTAssertEqual(AppController.captureWindow(["Evlat", "--list", "--capture", "90"]), 90)
        // A missing or unusable number still measures, with the default window:
        // the flag is an instrument, and refusing to measure is worse.
        XCTAssertEqual(AppController.captureWindow(["Evlat", "--list", "--capture"]),
                       AppController.defaultCaptureWindow)
        XCTAssertEqual(AppController.captureWindow(["Evlat", "--list", "--capture", "soon"]),
                       AppController.defaultCaptureWindow)
        XCTAssertEqual(AppController.captureWindow(["Evlat", "--list", "--capture", "0"]),
                       AppController.defaultCaptureWindow)
    }

    /// Diagnostics are asked for by `argv[1]` alone: a later
    /// `--list` or `--capture` is another command's argument.
    func testDiagnosticsAreAskedForByTheFirstArgumentOnly() {
        XCTAssertTrue(AppController.isDiagnostics(["Evlat", "--list"]))
        XCTAssertTrue(AppController.isDiagnostics(["Evlat", "--capture", "5"]))
        XCTAssertTrue(AppController.isDiagnostics(["Evlat", "--list", "--capture", "90"]))
        XCTAssertFalse(AppController.isDiagnostics(["Evlat"]))
        XCTAssertFalse(AppController.isDiagnostics(["Evlat", "signal", "x", "--", "cmd", "--capture", "5"]))
        XCTAssertFalse(AppController.isDiagnostics(["Evlat", "watch", "ls", "--list"]))
    }

    /// `Int(window)` and `addingTimeInterval` both come apart on a value that
    /// parses as a `Double` but is not a usable number of seconds: `inf` used
    /// to **trap** the process, which is a poor answer to a typo.
    func testACaptureWindowThatIsNotARealNumberOfSecondsFallsBack() {
        for raw in ["inf", "-inf", "nan", "1e400", "1e19", "999999999"] {
            XCTAssertEqual(AppController.captureWindow(["Evlat", "--list", "--capture", raw]),
                           AppController.defaultCaptureWindow, "--capture \(raw)")
        }
    }

    // MARK: - The bucket

    func testDiagnosticsCountsWhatArrivedAndKeepsTheLastLines() {
        let bucket = HookDiagnostics(recentLimit: 2)
        bucket.record(HookEvent(json: ["hook_event_name": "PreToolUse", "session_id": "s"]))
        bucket.record(HookEvent(json: ["hook_event_name": "PreToolUse", "session_id": "s"]))
        bucket.record(HookEvent(json: ["hook_event_name": "Stop", "session_id": "s",
                                       "agent_id": "a-1"]))
        XCTAssertEqual(bucket.total, 3)
        XCTAssertEqual(bucket.byName, ["PreToolUse": 2, "Stop": 1])
        // The subagent question is counted, not eyeballed.
        XCTAssertEqual(bucket.fromSubagents, 1)
        XCTAssertEqual(bucket.recent.count, 2)
        XCTAssertEqual(bucket.recent.last?.agentID, "a-1")
    }

    /// The bucket is a dead end on purpose: turning events into signals is
    /// the hooks provider's job, and registering anything here would put a second row
    /// next to the file record's for every live session.
    ///
    /// The real guard is the **compiler** — `HookDiagnostics` has no
    /// `currentSignals()`, so `registry.register(hookDiagnostics)` does not
    /// build. This adds the tripwire the compiler cannot give: the day someone
    /// makes an `EvlatApp` type conform to `Provider`, it stops being a
    /// question of discipline. The hooks provider is pure and lives in
    /// `EvlatCore`, so this stays true after it lands.
    func testNoTypeInTheAppLayerIsAProvider() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EvlatApp")
        // Recursive on purpose. `contentsOfDirectory` is not, and it returned
        // `Mascot/` and `UI/` as extensionless entries that the filter then
        // dropped — six of the nine app-layer files, `MascotModel` among them,
        // were exempt from the guard this test advertises.
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "could not walk EvlatApp: \(root.path)")
        let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no EvlatApp sources found: \(root.path)")

        let declarations: Set<String> = ["class", "struct", "enum", "actor", "extension"]
        var violations: [String] = []
        for file in files {
            for raw in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                // Comments are dropped for the same reason `ImportPurityTests`
                // drops them: this repo's comments explain why something is
                // NOT done, and a raw scan reads those sentences as the thing
                // itself. `///` starts with `//`, so one cut covers both.
                let line = raw.components(separatedBy: "//")[0]
                    .trimmingCharacters(in: .whitespaces)
                let words = line.split(separator: " ").map(String.init)
                guard words.contains(where: declarations.contains),
                      line.contains(": Provider") || line.contains(", Provider")
                else { continue }
                violations.append("\(file.lastPathComponent): \(line)")
            }
        }
        XCTAssertTrue(violations.isEmpty, """
            The diagnostic bucket feeds nothing into Registry, and no app-layer \
            type is a Provider: providers are pure and live in EvlatCore.
            \(violations.joined(separator: "\n"))
            """)
    }

    func testTheBucketIsJustACounter() {
        let bucket = HookDiagnostics()
        bucket.record(HookEvent(json: ["hook_event_name": "Stop", "session_id": "s"]))
        XCTAssertEqual(bucket.total, 1)
        XCTAssertEqual(bucket.recent.first?.sessionID, "s")
    }

    // MARK: - Helpers

    // MARK: - A held permission request

    private let permissionBody = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func permissionRequest(port: UInt16, timeout: TimeInterval = 5) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(ChatRequest.path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(permissionBody.utf8)
        request.setValue("T-1", forHTTPHeaderField: ChatRequest.tokenHeader)
        request.timeoutInterval = timeout
        return request
    }

    /// The answer is the user's: the connection stays open until `answer`,
    /// and what is written then is what the client reads.
    func testAPermissionRequestIsHeldUntilAnswered() throws {
        var asked: ChatRequest?
        let arrived = expectation(description: "request on the main queue")
        let listener = HookListener(port: Self.anyPort, onAbandoned: { _ in }) { delivery in
            if case .permission(let request) = delivery { asked = request }
            arrived.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        var answer: Answer?
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            answer = self.send(self.permissionRequest(port: port))
            returned.signal()
        }
        wait(for: [arrived], timeout: 5)
        let request = try XCTUnwrap(asked)
        XCTAssertEqual(request.token, "T-1")
        XCTAssertEqual(returned.wait(timeout: .now() + 0.5), .timedOut, "nothing is written before the user answers")

        listener.answer(request.id, with: LocalAPI.Response(status: .ok, body: #"{"x":1}"#))
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(answer?.status, 200)
        XCTAssertEqual(answer?.body, #"{"x":1}"#)
        // Answered once: a second answer finds nothing to write to.
        listener.answer(request.id, with: LocalAPI.Response(status: .ok, body: "{}"))
    }

    /// Claude's time runs out, or its turn ends: the far side closes and the
    /// card must go.
    func testAHeldRequestThatClosesIsAbandoned() throws {
        var asked: ChatRequest?
        var abandoned: String?
        let gone = expectation(description: "abandoned on the main queue")
        let listener = HookListener(port: Self.anyPort, onAbandoned: { id in
            XCTAssertTrue(Thread.isMainThread)
            abandoned = id
            gone.fulfill()
        }) { delivery in
            if case .permission(let request) = delivery { asked = request }
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-m", "1", "-X", "POST", "-H", "\(ChatRequest.tokenHeader): T-1",
                          "--data-binary", permissionBody, "http://127.0.0.1:\(port)\(ChatRequest.path)"]
        curl.standardOutput = FileHandle.nullDevice
        try curl.run()
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(abandoned, asked?.id)
        curl.waitUntilExit()
    }

    /// A listener nobody answers permissions through (a tunnel's, the
    /// capture's) refuses at once rather than holding for ever.
    func testWithoutAnAnswererAPermissionRequestIsRefused() throws {
        let listener = HookListener(port: Self.anyPort) { _ in }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))
        XCTAssertEqual(send(permissionRequest(port: port)).status, 404)
    }

    // MARK: - `/signal` and its key

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-listener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func postSignal(port: UInt16, key: String?, body: String, origin: String? = nil) -> Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/signal")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let key { request.setValue(key, forHTTPHeaderField: SignalReport.keyHeader) }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return send(request)
    }

    /// End to end, as the app wires it: the key is written once the port is
    /// bound, a POST carrying it becomes a row in the registry, and one
    /// without it, with a wrong one or from a browser never reaches the app.
    @MainActor
    func testASignalWithTheKeyFileBecomesARow() throws {
        let home = try temporaryHome()
        let controller = AppController()
        controller.registry.register(controller.signals)
        var deliveries = 0
        let arrived = expectation(description: "signal on the main queue")
        let listener = HookListener(port: Self.anyPort,
                                    signalKey: AppController.signalKeyWriter(home: home, environment: [:])) { delivery in
            MainActor.assumeIsolated {
                deliveries += 1
                controller.handleDelivery(delivery)
                arrived.fulfill()
            }
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))
        let file = try XCTUnwrap(SignalKey.location(port: port, home: home, environment: [:]))
        let key = try XCTUnwrap(SignalKey.read(from: file), "written by the time the port is reported bound")

        let body = #"{"id":"build","ttl":60,"phase":"working","label":"npm run build"}"#
        let refused = DispatchQueue.global()
        var answers: [String: Int] = [:]
        refused.sync {
            answers["none"] = postSignal(port: port, key: nil, body: body).status
            answers["wrong"] = postSignal(port: port, key: String(key.reversed()), body: body).status
            answers["browser"] = postSignal(port: port, key: key, body: body, origin: "https://example.com").status
            answers["right"] = postSignal(port: port, key: key, body: body).status
        }
        XCTAssertEqual(answers, ["none": 403, "wrong": 403, "browser": 403, "right": 200])
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(deliveries, 1, "only the keyed request reached the app")
        let row = try XCTUnwrap(controller.registry.snapshot().ordered.first { $0.entity == "signal:build" })
        XCTAssertEqual(row.phase, .working)
        XCTAssertEqual(row.kind, .custom)
    }

    /// A tunnel's listener without its machine's key has no route: `404`,
    /// whatever is sent.
    func testAKeylessTunnelListenerAnswersSignalWithNotFound() throws {
        let listener = HookListener(port: Self.anyPort, origin: .machine) { _ in
            XCTFail("nothing is delivered")
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))
        let body = #"{"id":"build","ttl":60,"phase":"working"}"#
        XCTAssertEqual(postSignal(port: port, key: nil, body: body).status, 404)
        XCTAssertEqual(postSignal(port: port, key: "anything", body: body).status, 404)
    }

    /// With its machine's key a tunnel's listener answers `/signal`
    /// as the local one does, over the wire: the key decides, and only the
    /// keyed request is delivered.
    func testAKeyedTunnelListenerAnswersSignalLikeTheLocalOne() throws {
        let key = String(repeating: "ab", count: 32)
        var deliveries = 0
        let arrived = expectation(description: "signal delivered")
        let listener = HookListener(port: Self.anyPort, origin: .machine, signalKey: { _ in key }) { delivery in
            guard case .signal(let report) = delivery else { return XCTFail("not a signal") }
            XCTAssertEqual(report.id, "build")
            deliveries += 1
            arrived.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        let port = try XCTUnwrap(boundPort(listener))
        let body = #"{"id":"build","ttl":60,"phase":"working"}"#
        var answers: [String: Int] = [:]
        DispatchQueue.global().sync {
            answers["none"] = postSignal(port: port, key: nil, body: body).status
            answers["wrong"] = postSignal(port: port, key: String(key.reversed().dropFirst()), body: body).status
            answers["right"] = postSignal(port: port, key: key, body: body).status
        }
        XCTAssertEqual(answers, ["none": 403, "wrong": 403, "right": 200])
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(deliveries, 1)
    }

    /// The listener that cannot bind never writes: the running Evlat's key
    /// stays the one programs read.
    func testAListenerThatCannotBindLeavesTheKeyFileAlone() throws {
        let home = try temporaryHome()
        let first = HookListener(port: Self.anyPort,
                                 signalKey: AppController.signalKeyWriter(home: home, environment: [:])) { _ in }
        first.start()
        defer { first.stop() }
        let port = try XCTUnwrap(boundPort(first))
        let file = try XCTUnwrap(SignalKey.location(port: port, home: home, environment: [:]))
        let key = try XCTUnwrap(SignalKey.read(from: file))

        var asked = false
        let second = HookListener(port: port, signalKey: { _ in asked = true; return "other" }) { _ in }
        second.start()
        defer { second.stop() }
        guard case .unavailable = second.awaitSettled(timeout: 5) else {
            return XCTFail("two listeners bound the same port")
        }
        XCTAssertFalse(asked, "no key is made without the port")
        XCTAssertEqual(SignalKey.read(from: file), key)
    }

    /// `--list`'s probe against a real listener: each answer it can name.
    func testTheListProbeReadsTheListener() throws {
        let home = try temporaryHome()
        let listener = HookListener(port: Self.anyPort,
                                    signalKey: AppController.signalKeyWriter(home: home, environment: [:])) { _ in }
        listener.start()
        let port = try XCTUnwrap(boundPort(listener))
        let key = try XCTUnwrap(SignalKey.read(from: SignalKey.location(port: port, home: home, environment: [:])!))
        XCTAssertEqual(AppController.probeSignalEndpoint(port: port, key: key), .status(200))
        XCTAssertEqual(AppController.probeSignalEndpoint(port: port, key: "stale"), .status(403))
        listener.stop()
        let keyless = HookListener(port: Self.anyPort) { _ in }
        keyless.start()
        defer { keyless.stop() }
        let other = try XCTUnwrap(boundPort(keyless))
        XCTAssertEqual(AppController.probeSignalEndpoint(port: other, key: key), .status(403))
    }

    private struct Answer {
        let status: Int
        let body: String
    }

    private func post(port: UInt16, path: String, body: String) -> Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return send(request)
    }

    private func get(port: UInt16, path: String) -> Answer {
        send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!))
    }

    /// Synchronous on purpose: these run off the main thread in one test, so an
    /// `XCTestExpectation` (which needs the main run loop) is the wrong tool.
    private func send(_ request: URLRequest) -> Answer {
        var request = request
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var answer = Answer(status: -1, body: "")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            answer = Answer(status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                            body: String(data: data ?? Data(), encoding: .utf8) ?? "")
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return answer
    }
}
