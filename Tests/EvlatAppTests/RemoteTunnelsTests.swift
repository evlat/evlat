import XCTest
import EvlatCore
@testable import EvlatApp

/// The tunnel's shell against a **fake `ssh`**: a script each test writes,
/// which records its arguments and then either holds its stdin open like the
/// real remote `cat` or prints one OpenSSH line and exits. The real `ssh` is
/// never run from a test — every `RemoteTunnels` here is handed the fake's
/// path.
final class RemoteTunnelsTests: XCTestCase {
    private var directory: URL!
    private var tunnels: RemoteTunnels?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every fake started here ends here, even when an assertion failed.
        tunnels?.stopAll()
        tunnels = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private enum Mode {
        /// `exec cat >/dev/null`: up until its stdin closes.
        case connect
        /// One stderr line, then exit 255 — how `ssh` fails.
        case fail(String)
    }

    /// The fake and the file its arguments land in, one run per block.
    private func fakeSSH(_ mode: Mode) throws -> (path: String, log: URL) {
        let log = directory.appendingPathComponent("args.log")
        let script = directory.appendingPathComponent("fake-ssh")
        let tail: String
        switch mode {
        case .connect: tail = "exec cat >/dev/null"
        case .fail(let line): tail = "echo '\(line)' >&2\nexit 255"
        }
        try """
            #!/bin/sh
            \(FreshExecutable.warmLine)
            { echo '--- run'; for a in "$@"; do printf '%s\\n' "$a"; done; } >> '\(log.path)'
            \(tail)

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        FreshExecutable.warm(script.path)
        return (script.path, log)
    }

    private func runs(in log: URL) -> [[String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "--- run\n").dropFirst().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    private let machine = RemoteMachine(id: "fake", target: "fake")!

    private func make(ssh path: String, registry: Registry = Registry(),
                      workspace: NotificationCenter = NotificationCenter(),
                      confirmAfter: TimeInterval = 0.2,
                      schedule: RemoteTunnels.Schedule? = nil) -> RemoteTunnels {
        let made = RemoteTunnels(registry: registry, sshPath: path, platform: .unknown,
                                 now: Date.init, workspace: workspace,
                                 confirmAfter: confirmAfter,
                                 schedule: schedule ?? RemoteTunnels.mainQueueSchedule,
                                 onChange: {})
        tunnels = made
        return made
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    // MARK: - Connecting

    func testAMachineConnectsThroughTheFakeSSH() throws {
        let fake = try fakeSSH(.connect)
        let tunnels = make(ssh: fake.path)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }

        let run = try XCTUnwrap(runs(in: fake.log).first)
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        XCTAssertEqual(run, RemoteTunnel.arguments(target: "fake", localPort: port),
                       "remote 48151 onto the machine's own listener, the target after --")
        XCTAssertNotEqual(port, LocalAPI.defaultPort)
    }

    func testAFailureLineWaitsAndRetriesOnTheSchedule() throws {
        let fake = try fakeSSH(.fail("Error: remote port forwarding failed for listen port 48151"))
        var delays: [TimeInterval] = []
        var retries: [() -> Void] = []
        let tunnels = make(ssh: fake.path, schedule: { delay, run in
            // The confirmation is not the schedule under test.
            if delay != 0.2 {
                delays.append(delay)
                retries.append(run)
            }
            return {}
        })
        tunnels.add(machine)
        waitUntil("waiting") {
            if case .waiting(_, .portBusy)? = tunnels.state(of: "fake") { return true }
            return false
        }
        XCTAssertEqual(delays, [2])

        retries.removeFirst()()
        waitUntil("second run failed") { delays.count == 2 }
        XCTAssertEqual(delays, [2, 4])
        XCTAssertEqual(runs(in: fake.log).count, 2)
    }

    func testClosingThePipeEndsTheFakeSSH() throws {
        let fake = try fakeSSH(.connect)
        let exited = expectation(description: "fake ssh exited")
        let process = SSHProcess(path: fake.path, arguments: ["--", "fake", "cat >/dev/null"]) { _ in
            exited.fulfill()
        }
        XCTAssertNil(process.run())
        // Give it a moment to reach `cat`, then drop only our end of stdin —
        // what the kernel does when Evlat dies.
        waitUntil("recorded") { self.runs(in: fake.log).count == 1 }
        process.closeInput()
        wait(for: [exited], timeout: 5)
    }

    func testSleepClosesTheProcessAndWakeOpensItAtOnce() throws {
        let fake = try fakeSSH(.connect)
        let workspace = NotificationCenter()
        let tunnels = make(ssh: fake.path, workspace: workspace)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(tunnels.state(of: "fake"), .stopped)
        waitUntil("process gone") { tunnels.isProcessRunning(of: "fake") == false }

        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(tunnels.state(of: "fake"), .connecting)
        waitUntil("second run") { self.runs(in: fake.log).count == 2 }
        waitUntil("connected again") { tunnels.state(of: "fake")?.isConnected == true }
    }

    // MARK: - What arrives

    /// The hand-off from `phase-1`: the first request marks the link up
    /// **before** the event lands, so the row is live, not dimmed as
    /// "not heard since the link came up".
    func testATunneledHookBecomesALiveRemoteRowWithoutAPid() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        // Long enough that only the request can mark the link up.
        let tunnels = make(ssh: fake.path, registry: registry, confirmAfter: 60)
        tunnels.add(machine)
        waitUntil("launched") { self.runs(in: fake.log).count == 1 }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.setValue("4242", forHTTPHeaderField: "X-Evlat-Pid")
        request.httpBody = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s-1","evlat_pid":"99"}"#.utf8)
        XCTAssertEqual(send(request), 200)

        waitUntil("row") { registry.snapshot().ordered.contains { $0.entity == "remote:fake:s-1" } }
        let row = try XCTUnwrap(registry.snapshot().ordered.first { $0.entity == "remote:fake:s-1" })
        XCTAssertNil(row.activity?.pid, "a remote pid means nothing on this Mac")
        XCTAssertEqual(row.machine?.name, "fake")
        XCTAssertTrue(row.isLive)
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertTrue(tunnels.state(of: "fake")?.isConnected == true)
    }

    func testRemovingAMachineDropsItsRows() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s-2"}"#.utf8)
        XCTAssertEqual(send(request), 200)
        waitUntil("row") { !registry.snapshot().ordered.isEmpty }
        let pid = try XCTUnwrap(tunnels.processIdentifier(of: "fake"))

        tunnels.remove(id: "fake")
        XCTAssertEqual(registry.snapshot().ordered, [])
        XCTAssertNil(tunnels.state(of: "fake"))
        waitUntil("process gone") { kill(pid, 0) != 0 }
    }

    // MARK: - Which machines

    func testAControllerWithoutDefaultsHasNoMachine() {
        XCTAssertEqual(AppController.remoteConfiguration(defaults: nil,
                                                         environment: ["EVLAT_MACHINES": "fake"]).machines, [])
    }

    func testAPortOverrideWithoutMachinesOpensNoTunnel() throws {
        let suite = "evlat-remote-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(RemoteMachine.encode([machine]), forKey: RemoteMachine.storageKey)

        XCTAssertEqual(AppController.remoteConfiguration(defaults: defaults, environment: [:]).machines, [machine])
        XCTAssertEqual(AppController.remoteConfiguration(defaults: defaults,
                                                         environment: ["EVLAT_PORT": "48999"]).machines, [])
    }

    func testTheSSHBinaryComesFromTheEnvironment() {
        XCTAssertEqual(AppController.sshPath(environment: [:]), "/usr/bin/ssh")
        XCTAssertEqual(AppController.sshPath(environment: ["EVLAT_SSH": "/tmp/fake-ssh"]), "/tmp/fake-ssh")
        XCTAssertEqual(AppController.sshPath(environment: ["EVLAT_SSH": " "]), "/usr/bin/ssh")
    }

    // MARK: - Diagnostics

    func testTheListNamesTheMachineOfARemoteRow() {
        let row = Signal(provider: "hooks", entity: "remote:fake:s-1", phase: .waiting, label: "project",
                         detail: "/srv/project", fidelity: .official, updatedAt: Date(),
                         machine: Signal.Machine(name: "devbox",
                                                 dim: Signal.Machine.Dim(reason: .disconnected, since: Date())))
        XCTAssertTrue(AppController.listLine(row).hasSuffix("  @ devbox (not reachable)"))
    }

    func testTheListSaysWhyThereIsNoTunnel() {
        let none = AppController.remoteMachineLines(
            RemoteMachine.configuration(environment: ["EVLAT_PORT": "48999"], stored: nil),
            environment: ["EVLAT_PORT": "48999"])
        XCTAssertEqual(none, ["remote machines: none (EVLAT_PORT is set without EVLAT_MACHINES: no tunnel is opened)"])
        let env = ["EVLAT_MACHINES": "ben@devbox,-x"]
        let lines = AppController.remoteMachineLines(RemoteMachine.configuration(environment: env, stored: nil),
                                                     environment: env)
        XCTAssertEqual(lines.first, "remote machines: 1 (from EVLAT_MACHINES)")
        XCTAssertTrue(lines.contains { $0.contains("machine  devbox  → ben@devbox") })
        XCTAssertTrue(lines.contains { $0.contains("-x ignored") })
    }

    private func send(_ request: URLRequest) -> Int {
        var request = request
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var status = -1
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return status
    }
}
