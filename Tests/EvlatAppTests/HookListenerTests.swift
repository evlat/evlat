import XCTest
import EvlatCore
@testable import EvlatApp

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
        let listener = HookListener(port: Self.anyPort) { event in
            XCTAssertTrue(Thread.isMainThread, "events are delivered on the main queue")
            received = event
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
        // The subagent question is counted, not eyeballed (`discussion.md` → Karar 8).
        XCTAssertEqual(bucket.fromSubagents, 1)
        XCTAssertEqual(bucket.recent.count, 2)
        XCTAssertEqual(bucket.recent.last?.agentID, "a-1")
    }

    /// The bucket is a dead end on purpose: turning events into signals is
    /// `phase-4`'s job, and registering anything here would put a second row
    /// next to the file record's for every live session.
    ///
    /// The real guard is the **compiler** — `HookDiagnostics` has no
    /// `currentSignals()`, so `registry.register(hookDiagnostics)` does not
    /// build. This adds the tripwire the compiler cannot give: the day someone
    /// makes an `EvlatApp` type conform to `Provider`, it stops being a
    /// question of discipline. `phase-4`'s provider is pure and lives in
    /// `EvlatCore`, so this stays true after it lands.
    func testNoTypeInTheAppLayerIsAProvider() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EvlatApp")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
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
