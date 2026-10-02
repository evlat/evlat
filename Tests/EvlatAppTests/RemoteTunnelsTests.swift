import XCTest
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The tunnel's shell against a **fake `ssh`**: a script each test writes,
/// which records its arguments and then either holds its stdin open like the
/// real remote `cat` or prints one OpenSSH line and exits. The real `ssh` is
/// never run from a test — every `RemoteTunnels` here is handed the fake's
/// path.
final class RemoteTunnelsTests: XCTestCase {
    private var directory: URL!
    /// Where the masters' sockets go: short, since `$TMPDIR` plus a UUID is
    /// already past what a socket path may hold (`RemoteTunnel.controlPath`).
    private var sockets: String!
    /// Sockets a test holds open; closed at the end.
    private var held: [Int32] = []
    private var tunnels: RemoteTunnels?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sockets = "/tmp/e-" + UUID().uuidString.prefix(6)
    }

    override func tearDownWithError() throws {
        // Every fake started here ends here, even when an assertion failed.
        tunnels?.stopAll()
        tunnels = nil
        askpassListener?.stop()
        askpassListener = nil
        held.forEach { Darwin.close($0) }
        held = []
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(atPath: sockets)
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
            printf '%s\\n' "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" "HOME=$HOME" >> '\(log.path).env'
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

    private func environment(in log: URL) -> [String] {
        ((try? String(contentsOf: URL(fileURLWithPath: log.path + ".env"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private let machine = RemoteMachine(id: "fake", target: "fake")!
    private let key = String(repeating: "a", count: 64)
    /// What `ssh` is started with, besides the tunnel's own variables.
    private let base = ["SSH_AUTH_SOCK": "/private/tmp/evlat-test-agent.sock", "HOME": "/Users/ben",
                        "PATH": "/usr/bin:/bin"]

    private func make(ssh path: String, registry: Registry = Registry(),
                      workspace: NotificationCenter = NotificationCenter(),
                      confirmAfter: TimeInterval = 0.2,
                      schedule: RemoteTunnels.Schedule? = nil) -> RemoteTunnels {
        let made = RemoteTunnels(registry: registry, sshPath: path, platform: .unknown,
                                 now: Date.init, socketDirectory: sockets, environment: base,
                                 workspace: workspace,
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
        tunnels.add(machine, key: key)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }

        let run = try XCTUnwrap(runs(in: fake.log).first)
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        let socket = try XCTUnwrap(RemoteTunnel.controlPath(directory: sockets, machineID: "fake"),
                                   "the test's socket directory is short enough for a master")
        XCTAssertEqual(tunnels.controlPath(of: "fake"), socket)
        XCTAssertEqual(run, RemoteTunnel.arguments(target: "fake", localPort: port, controlPath: socket),
                       "remote 48151 onto the machine's own listener, the target after --")
        XCTAssertNotEqual(port, LocalAPI.defaultPort)
        XCTAssertEqual(environment(in: fake.log),
                       ["SSH_AUTH_SOCK=/private/tmp/evlat-test-agent.sock", "HOME=/Users/ben"],
                       "ssh sees Evlat's environment, the agent included")
        let mode = try FileManager.default.attributesOfItem(atPath: sockets)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)

        tunnels.remove(id: "fake")
        XCTAssertNil(tunnels.controlPath(of: "fake"))
    }

    /// A socket file left by a master that is gone (`kill -9`) is cleared
    /// before the new master starts; one that answers belongs to a running
    /// master — another Evlat's — and is left alone, the tunnel then running
    /// without a master of its own.
    func testAStaleSocketIsClearedAndALiveOneIsLeftAlone() throws {
        let socket = try XCTUnwrap(RemoteTunnel.controlPath(directory: sockets, machineID: "fake"))
        try FileManager.default.createDirectory(atPath: sockets, withIntermediateDirectories: true)
        Darwin.close(try bindSocket(at: socket, listening: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let fake = try fakeSSH(.connect)
        var tunnels = make(ssh: fake.path)
        tunnels.add(machine, key: key)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "the stale file is gone")
        XCTAssertEqual(runs(in: fake.log).first?.contains("-M"), true)
        tunnels.stopAll()

        held.append(try bindSocket(at: socket, listening: true))
        let other = try fakeSSH(.connect)
        try FileManager.default.removeItem(at: other.log)
        tunnels = make(ssh: other.path)
        tunnels.add(machine, key: key)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        XCTAssertEqual(runs(in: other.log).first, RemoteTunnel.arguments(target: "fake", localPort: port),
                       "no master of its own beside a live one")
        XCTAssertNil(tunnels.controlPath(of: "fake"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "a live socket is not touched")
    }

    /// A unix socket bound at `path`; listening or not, its file stays.
    private func bindSocket(at path: String, listening: Bool) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        if listening { XCTAssertEqual(Darwin.listen(fd, 1), 0) }
        return fd
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
        tunnels.add(machine, key: key)
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
        tunnels.add(machine, key: key)
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

    /// The hand-off from the tunnel: the first request marks the link up
    /// **before** the event lands, so the row is live, not dimmed as
    /// "not heard since the link came up".
    func testATunneledHookBecomesALiveRemoteRowWithoutAPid() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        // Long enough that only the request can mark the link up.
        let tunnels = make(ssh: fake.path, registry: registry, confirmAfter: 60)
        tunnels.add(machine, key: key)
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

    /// A usage report goes to the machine's provider for its own agent —
    /// no agent is singled out — and an agent switched off on the machine
    /// has no provider: its report is dropped and its windows go.
    func testAUsageReportGoesToItsAgentsProviderOnTheMachine() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine, key: key)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        func post(_ source: some Agent, _ body: String) -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(source.statusLineUsage!.path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            return send(request)
        }
        let reset = Int(Date().timeIntervalSince1970) + 3600
        XCTAssertEqual(post(.claude, #"{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":\#(reset)}}}"#), 200)
        XCTAssertEqual(post(.antigravity, #"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_time":"2099-01-01T00:00:00Z"}}}"#), 200)
        waitUntil("both windows") { registry.snapshot().usage.count == 2 }
        XCTAssertEqual(Set(registry.snapshot().usage.map(\.provider)),
                       ["claude-usage@fake", "antigravity-usage@fake"], "each to its own agent's provider")

        tunnels.setAgents(["claude", "codex"], of: "fake")
        XCTAssertEqual(registry.snapshot().usage.map(\.provider), ["claude-usage@fake"],
                       "switched off: its provider and windows go")
        XCTAssertEqual(post(.antigravity, #"{"quota":{"gemini-5h":{"remaining_fraction":0.2,"reset_time":"2099-01-01T00:00:00Z"}}}"#), 200)
        XCTAssertEqual(registry.snapshot().usage.map(\.provider), ["claude-usage@fake"], "and its report is dropped")
        XCTAssertEqual(tunnels.machines.first?.agents, ["claude", "codex"], "kept on the machine's entry")
        XCTAssertEqual(tunnels.enabledAgents(of: "fake"), [.claude, .codex])
    }

    /// A machine's switches hide its own agents' rows, after the merge,
    /// and leave this Mac's set alone; the hidden row is switched off, not
    /// gone, so its finish is not retold when it comes back.
    func testAMachinesSwitchesHideItsOwnRowsOnly() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        registry.machineSources = { [weak tunnels] in tunnels?.enabledAgents(of: $0) }
        registry.enabledSources = { [] }
        tunnels.add(machine, key: key)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s-3"}"#.utf8)
        XCTAssertEqual(send(request), 200)
        waitUntil("row") { registry.snapshot().ordered.contains { $0.entity == "remote:fake:s-3" } }
        XCTAssertEqual(registry.snapshot().ordered.first?.machine?.id, "fake",
                       "this Mac's empty set does not hide a machine's row")

        tunnels.setAgents(["codex"], of: "fake")
        XCTAssertEqual(registry.snapshot().ordered, [])
        XCTAssertEqual(registry.snapshot().switchedOff, ["remote:fake:s-3"])
        tunnels.setAgents(["codex", "claude"], of: "fake")
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["remote:fake:s-3"])
    }

    func testRemovingAMachineDropsItsRows() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine, key: key)
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

    /// With its machine's key a tunnel's `/signal` becomes that
    /// machine's outside row — namespaced, named after the machine, live while
    /// the tunnel is up, dimmed when it goes, gone with the machine. Without
    /// the key, with a wrong one or with another machine's, `403` and no row.
    func testAKeyedSignalThroughTheTunnelIsTheMachinesRow() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        let other = try XCTUnwrap(RemoteMachine(id: "other", target: "other"))
        let otherKey = String(repeating: "b", count: 64)
        tunnels.add(machine, key: key)
        tunnels.add(other, key: otherKey)
        XCTAssertEqual(tunnels.signalKey(of: "fake"), key)
        waitUntil("connected") {
            tunnels.state(of: "fake")?.isConnected == true && tunnels.state(of: "other")?.isConnected == true
        }
        guard case .listening(let port)? = tunnels.listenerStatus(of: "fake") else {
            return XCTFail("the machine's listener is not up")
        }
        let body = #"{"id":"x","ttl":60,"phase":"working","label":"build","sender":"npm"}"#
        func post(_ key: String?) -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(SignalReport.path)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key { request.setValue(key, forHTTPHeaderField: SignalReport.keyHeader) }
            request.httpBody = Data(body.utf8)
            return send(request)
        }
        XCTAssertEqual(post(nil), 403)
        XCTAssertEqual(post(String(repeating: "c", count: 64)), 403)
        XCTAssertEqual(post(otherKey), 403, "another machine's key does not open this one")
        XCTAssertEqual(registry.snapshot().ordered, [], "a refused request leaves no row")

        XCTAssertEqual(post(key), 200)
        waitUntil("row") { registry.snapshot().ordered.contains { $0.entity == "signal:fake:x" } }
        let row = try XCTUnwrap(registry.snapshot().ordered.first { $0.entity == "signal:fake:x" })
        XCTAssertEqual(row.kind, .custom)
        XCTAssertEqual(row.fidelity, .manual)
        XCTAssertEqual(row.machine?.name, "fake")
        XCTAssertEqual(row.sender, "npm")
        XCTAssertTrue(row.isLive)

        // The tunnel goes: the row stays, dimmed.
        tunnels.sleep()
        let dimmed = try XCTUnwrap(registry.snapshot().ordered.first { $0.entity == "signal:fake:x" })
        XCTAssertEqual(dimmed.machine?.dim?.reason, .disconnected)
        XCTAssertFalse(dimmed.isLive)

        tunnels.remove(id: "fake")
        XCTAssertFalse(registry.snapshot().ordered.contains { $0.entity.hasPrefix("signal:fake:") })
        XCTAssertNil(tunnels.signalKey(of: "fake"))
    }

    // MARK: - Asking for a password

    /// `Tests/Fixtures/fake-ssh`, copied and warmed: the fake that asks its
    /// askpass. Configured through the environment `ssh` is started with.
    private func promptingSSH() throws -> (path: String, log: URL) {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh")
        let copy = directory.appendingPathComponent("fake-ssh-prompting")
        try FileManager.default.copyItem(at: fixture, to: copy)
        FreshExecutable.warm(copy.path)
        return (copy.path, directory.appendingPathComponent("prompting.log"))
    }

    /// The built binary: the helper `ssh` runs.
    private var helper: String {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat").path
    }

    /// This Mac's listener as the app has it: `/askpass` held and handed
    /// to the tunnels, their answers written back, an abandoned one told.
    private var askpassListener: HookListener?

    private func makeAsking(ssh path: String, log: URL, environment extra: [String: String],
                            store: SSHPasswordStore = MemoryPasswordStore(),
                            port: Bool = true, confirmAfter: TimeInterval = 0.2,
                            settled: @escaping () -> Bool = { true }) throws -> RemoteTunnels {
        var tunnelsRef: RemoteTunnels?
        let listener = HookListener(port: 0, onAbandoned: { id in tunnelsRef?.abandoned(id) }) { delivery in
            if case .askpass(let request) = delivery { tunnelsRef?.ask(request) }
        }
        listener.start()
        askpassListener = listener
        guard case .listening(let bound) = listener.awaitSettled(timeout: 5) else {
            throw XCTSkip("listener did not come up: \(listener.status.text)")
        }
        var environment = base.merging(extra) { _, new in new }
        environment["FAKE_SSH_LOG"] = log.path
        let made = RemoteTunnels(registry: Registry(), sshPath: path, platform: .unknown,
                                 now: Date.init, socketDirectory: sockets, environment: environment,
                                 workspace: NotificationCenter(), confirmAfter: confirmAfter,
                                 askpass: RemoteTunnels.AskpassRoute(binary: helper, port: { port ? bound : nil },
                                                                     settled: settled),
                                 store: store, onChange: {})
        made.respond = { [weak listener] id, response in listener?.answer(id, with: response) }
        tunnelsRef = made
        tunnels = made
        return made
    }

    private func askpassLines(_ log: URL) -> [String] {
        ((try? String(contentsOf: URL(fileURLWithPath: log.path + ".askpass"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private let passwordPrompt = "ben@fake's password: "

    /// The stored password answers the try's first password prompt and no
    /// other: a second prompt on the same try is refused, and the login
    /// that refused the stored one is not tried again.
    func testTheStoredPasswordGoesToTheFirstPasswordPromptOnce() throws {
        let fake = try promptingSSH()
        let store = MemoryPasswordStore(["fake": StoredPassword(password: "s3cr€t", prompt: passwordPrompt)])
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt,
                                                   "FAKE_SSH_PROMPT2": passwordPrompt],
                                     store: store)
        tunnels.add(machine, key: key)
        waitUntil("stopped for the user", timeout: 15) { tunnels.state(of: "fake") == .needsUser(rejected: true) }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 0 s3cr€t", "askpass 1 "])
        XCTAssertEqual(runs(in: fake.log).count, 1, "a refused password is not sent again")
        let run = try XCTUnwrap(runs(in: fake.log).first)
        XCTAssertTrue(run.contains("BatchMode=no"))
        XCTAssertTrue(run.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(tunnels.prompts.isEmpty, "a quiet try puts nothing in front of the user")
        // The refused stored password is forgotten: "Enter Password…" asks
        // the user instead of sending it again.
        var kept: String? = "unread"
        store.password(for: "fake") { kept = $0?.password }
        XCTAssertNil(kept)
        tunnels.retryByUser(id: "fake")
        waitUntil("the user is asked", timeout: 15) { !tunnels.prompts.isEmpty }
        tunnels.prompts.forEach { tunnels.answer($0.id, with: nil) }
    }

    /// A quiet try refuses a host key question: `ssh`'s own line, and the
    /// failure is the host key as it always was.
    func testAQuietTryRefusesAHostKeyQuestion() throws {
        let fake = try promptingSSH()
        let question = """
            The authenticity of host 'fake (10.0.0.9)' can't be established.
            ED25519 key fingerprint is SHA256:abc.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: ["FAKE_SSH_PROMPT1": question])
        tunnels.add(machine, key: key)
        waitUntil("waiting", timeout: 15) {
            if case .waiting(_, .hostKey)? = tunnels.state(of: "fake") { return true }
            return false
        }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 1 "])
    }

    /// `ssh` keeps Evlat's environment — the agent first of all — with the
    /// askpass variables added; with no port to ask, none of them, and
    /// `ssh` never prompts.
    func testTheAgentIsKeptAndAskpassComesOnlyWithAPort() throws {
        let fake = try promptingSSH()
        var tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: [:])
        tunnels.add(machine, key: key)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertEqual(environment(in: fake.log), [
            "SSH_AUTH_SOCK=/private/tmp/evlat-test-agent.sock",
            "SSH_ASKPASS=\(helper)", "SSH_ASKPASS_REQUIRE=force", "EVLAT_ASKPASS=set",
        ])
        tunnels.stopAll()
        askpassListener?.stop()

        try FileManager.default.removeItem(atPath: fake.log.path + ".env")
        try FileManager.default.removeItem(at: fake.log)
        tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: [:], port: false)
        tunnels.add(machine, key: key)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertEqual(environment(in: fake.log), [
            "SSH_AUTH_SOCK=/private/tmp/evlat-test-agent.sock",
            "SSH_ASKPASS=unset", "SSH_ASKPASS_REQUIRE=unset", "EVLAT_ASKPASS=",
        ])
        let run = try XCTUnwrap(runs(in: fake.log).first)
        XCTAssertTrue(run.contains("BatchMode=yes"), "without a helper, no prompt at all")
    }

    /// A machine just added asks the user; the typed password reaches
    /// `ssh`, and with "Remember" on it is kept once the tunnel is up.
    func testAnAddedMachineAsksTheUserAndKeepsTheAnswerOnceConnected() throws {
        let fake = try promptingSSH()
        let store = MemoryPasswordStore()
        var changes = 0
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt, "FAKE_SSH_PASSWORD": "typed"],
                                     // Longer than the helper takes to ask: the
                                     // question, not the clock, holds it.
                                     store: store, confirmAfter: 3)
        tunnels.onPromptsChanged = { changes += 1 }
        tunnels.add(machine, key: key, interactive: true)
        waitUntil("asked", timeout: 15) { tunnels.prompts.count == 1 }
        let prompt = try XCTUnwrap(tunnels.prompts.first)
        XCTAssertEqual(prompt.text, passwordPrompt, "the prompt as ssh wrote it")
        XCTAssertEqual(prompt.machine, "fake")
        XCTAssertTrue(prompt.isPassword)
        XCTAssertEqual(tunnels.state(of: "fake"), .connecting, "not connected while the question waits")
        var kept: String?
        store.password(for: "fake") { kept = $0?.password }
        XCTAssertNil(kept)

        tunnels.answer(prompt.id, with: "typed", remember: true)
        XCTAssertTrue(tunnels.prompts.isEmpty)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 0 typed"])
        store.password(for: "fake") { kept = $0?.password }
        XCTAssertEqual(kept, "typed")
        XCTAssertGreaterThanOrEqual(changes, 2)
    }

    /// A try that ends takes its held question with it: the window's
    /// prompt goes, and the helper is answered — nothing is left waiting.
    func testAnEndingTryLetsItsHeldQuestionGo() throws {
        let fake = try promptingSSH()
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: ["FAKE_SSH_PROMPT1": passwordPrompt],
                                     confirmAfter: 3)
        tunnels.add(machine, key: key, interactive: true)
        waitUntil("asked", timeout: 15) { tunnels.prompts.count == 1 }
        tunnels.sleep()
        waitUntil("the question went with the try", timeout: 15) { tunnels.prompts.isEmpty }
        waitUntil("process gone") { tunnels.isProcessRunning(of: "fake") == false }
        XCTAssertEqual(tunnels.state(of: "fake"), .stopped)
    }

    /// A token no running try holds is refused, whatever it asks.
    func testAnUnknownTokenIsRefused() throws {
        let fake = try promptingSSH()
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: [:])
        var answered: [(String, LocalAPI.Response)] = []
        tunnels.respond = { answered.append(($0, $1)) }
        tunnels.ask(Askpass.Request(id: "r-1", token: String(repeating: "c", count: 64), prompt: passwordPrompt))
        XCTAssertEqual(answered.map(\.0), ["r-1"])
        XCTAssertEqual(answered.first?.1, LocalAPI.noAnswer)
        XCTAssertTrue(tunnels.prompts.isEmpty)
    }

    /// What a store was asked, in order; answers from memory like
    /// `MemoryPasswordStore`.
    private final class RecordingStore: SSHPasswordStore {
        private(set) var calls: [String] = []
        private var passwords: [String: StoredPassword]

        /// Each password stored at `prompt`, the fake `ssh`'s by default.
        init(_ passwords: [String: String] = [:], prompt: String = "ben@fake's password: ") {
            self.passwords = passwords.mapValues { StoredPassword(password: $0, prompt: prompt) }
        }

        func password(for id: String, completion: @escaping (StoredPassword?) -> Void) {
            completion(passwords[id])
        }

        func save(_ stored: StoredPassword, for id: String, target: String) {
            calls.append("save \(id) \(stored.password) \(target)")
            passwords[id] = stored
        }

        func delete(for id: String) {
            calls.append("delete \(id)")
            passwords[id] = nil
        }

        var saves: [String] { calls.filter { $0.hasPrefix("save") } }
    }

    // MARK: - Keeping the password

    /// A typed password is written only once the try is connected: not
    /// while its question waits, not when the server refuses it — that one
    /// goes, and with it whatever was stored.
    func testATypedPasswordIsStoredOnlyOnceConnected() throws {
        let fake = try promptingSSH()
        let store = RecordingStore()
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt, "FAKE_SSH_PASSWORD": "right"],
                                     store: store, confirmAfter: 3)
        tunnels.add(machine, key: key, interactive: true)
        waitUntil("asked", timeout: 15) { tunnels.prompts.count == 1 }
        XCTAssertEqual(store.calls, [], "nothing is written while the question waits")

        tunnels.answer(try XCTUnwrap(tunnels.prompts.first).id, with: "wrong", remember: true)
        waitUntil("refused", timeout: 15) { tunnels.state(of: "fake") == .needsUser(rejected: true) }
        XCTAssertEqual(store.saves, [], "a refused password is never kept")
        XCTAssertEqual(store.calls, ["delete fake"])
    }

    /// "Remember" off: the try connects with the typed password, and the
    /// one stored before goes — it is the one the user chose not to keep.
    func testRememberOffForgetsTheStoredPasswordOnceConnected() throws {
        let fake = try promptingSSH()
        // Stored at another prompt: it answers nothing, the user is asked.
        let store = RecordingStore(["fake": "old"], prompt: "ben@old's password: ")
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt],
                                     store: store, confirmAfter: 3)
        tunnels.add(machine, key: key, interactive: true)
        waitUntil("asked", timeout: 15) { tunnels.prompts.count == 1 }
        tunnels.answer(try XCTUnwrap(tunnels.prompts.first).id, with: "typed", remember: false)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertEqual(store.calls, ["delete fake"])
    }

    /// A `ProxyJump`'s nested `ssh` asks through the same helper, and its
    /// jump host's prompt may come first: the machine's stored password
    /// never goes there, and is not forgotten for it.
    func testAnotherHostsPromptNeverGetsTheStoredPassword() throws {
        let fake = try promptingSSH()
        let store = RecordingStore(["fake": "s3cr€t"])
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": "jim@jump's password: ",
                                                   "FAKE_SSH_PROMPT2": passwordPrompt],
                                     store: store)
        tunnels.add(machine, key: key)
        waitUntil("stopped for the user", timeout: 15) { tunnels.state(of: "fake") == .needsUser(rejected: false) }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 1 "])
        XCTAssertEqual(store.calls, [], "the stored password stays")
    }

    /// A second factor after the stored password: a quiet try cannot answer
    /// it, and the login's refusal does not cost the password.
    func testASecondFactorRefusedKeepsTheStoredPassword() throws {
        let fake = try promptingSSH()
        let store = RecordingStore(["fake": "s3cr€t"])
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt,
                                                   "FAKE_SSH_PROMPT2": "Verification code: "],
                                     store: store)
        tunnels.add(machine, key: key)
        waitUntil("stopped for the user", timeout: 15) { tunnels.state(of: "fake") == .needsUser(rejected: false) }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 0 s3cr€t", "askpass 1 "])
        XCTAssertEqual(store.calls, [])
    }

    /// A machine removed takes its stored password with it.
    func testRemovingAMachineForgetsItsPassword() throws {
        let fake = try fakeSSH(.connect)
        let store = RecordingStore(["fake": "s3cr€t"])
        let made = RemoteTunnels(registry: Registry(), sshPath: fake.path, platform: .unknown,
                                 now: Date.init, socketDirectory: sockets, environment: base,
                                 workspace: NotificationCenter(), confirmAfter: 0.2,
                                 store: store, onChange: {})
        tunnels = made
        made.add(machine, key: key)
        waitUntil("connected") { made.state(of: "fake")?.isConnected == true }
        made.remove(id: "fake")
        XCTAssertEqual(store.calls, ["delete fake"])
    }

    // MARK: - Waking

    /// After a wake the quiet try logs in with the stored password; the
    /// user is asked nothing.
    func testAWakeLogsInQuietlyWithTheStoredPassword() throws {
        let fake = try promptingSSH()
        let store = RecordingStore(["fake": "s3cr€t"])
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt, "FAKE_SSH_PASSWORD": "s3cr€t"],
                                     store: store)
        var asked = false
        tunnels.onPromptsChanged = { asked = true }
        tunnels.add(machine, key: key)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        tunnels.sleep()
        waitUntil("process gone") { tunnels.isProcessRunning(of: "fake") == false }
        tunnels.wake()
        waitUntil("connected again", timeout: 15) {
            tunnels.state(of: "fake")?.isConnected == true && self.runs(in: fake.log).count == 2
        }
        XCTAssertEqual(askpassLines(fake.log), ["askpass 0 s3cr€t", "askpass 0 s3cr€t"])
        XCTAssertFalse(asked, "no window")
        XCTAssertEqual(store.calls, [])
    }

    /// A machine last connected with a typed password not kept: the wake's
    /// quiet try stops for the user instead of retrying a prompt it cannot
    /// answer.
    func testAWakeWithoutAStoredPasswordWaitsForTheUser() throws {
        let fake = try promptingSSH()
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log,
                                     environment: ["FAKE_SSH_PROMPT1": passwordPrompt, "FAKE_SSH_PASSWORD": "typed"],
                                     store: RecordingStore(), confirmAfter: 3)
        tunnels.add(machine, key: key, interactive: true)
        waitUntil("asked", timeout: 15) { tunnels.prompts.count == 1 }
        tunnels.answer(try XCTUnwrap(tunnels.prompts.first).id, with: "typed", remember: false)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        tunnels.sleep()
        waitUntil("process gone") { tunnels.isProcessRunning(of: "fake") == false }
        tunnels.wake()
        waitUntil("waiting for the user", timeout: 15) { tunnels.state(of: "fake") == .needsUser(rejected: false) }
        XCTAssertTrue(tunnels.prompts.isEmpty)
    }

    // MARK: - Launching

    /// At launch this Mac's listener may still be binding: a try started
    /// then would run without askpass (`BatchMode=yes`) and a password
    /// server would fail it for nothing. The try waits until the listener
    /// is settled, then asks.
    func testTheFirstTryWaitsForThisMacsListener() throws {
        let fake = try promptingSSH()
        var settled = false
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: [:], settled: { settled })
        tunnels.add(machine, key: key)
        waitUntil("the machine's listener is up") {
            if case .listening? = tunnels.listenerStatus(of: "fake") { return true }
            return false
        }
        // The listener's report reaches the main queue after its status.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertNil(tunnels.isProcessRunning(of: "fake"), "no ssh before this Mac's listener is settled")

        settled = true
        tunnels.askpassSettled()
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        let run = try XCTUnwrap(runs(in: fake.log).first)
        XCTAssertTrue(run.contains("BatchMode=no"))
        XCTAssertEqual(runs(in: fake.log).count, 1)
    }

    // MARK: - Which store

    /// Only a launch that is neither a test nor isolated keeps passwords in
    /// the Keychain; making the store touches nothing.
    func testTheKeychainIsOnlyForAProcessThatIsNotIsolated() {
        XCTAssertTrue(AppController.passwordStore(underTests: true, environment: [:]) is MemoryPasswordStore)
        XCTAssertTrue(AppController.passwordStore(underTests: false, environment: ["EVLAT_PORT": "48999"])
                      is MemoryPasswordStore)
        XCTAssertTrue(AppController.passwordStore(underTests: false, environment: ["EVLAT_PORT": ""])
                      is KeychainPasswordStore)
        XCTAssertTrue(AppController.passwordStore(underTests: false, environment: [:]) is KeychainPasswordStore)
    }

    @MainActor
    func testUnderXCTestTheStoreIsInMemory() {
        let controller = AppController(defaults: nil)
        controller.startRemoteTunnels(configuration: RemoteMachine.Configuration(machines: [], fromEnvironment: true,
                                                                                 rejected: []))
        XCTAssertTrue(controller.passwordStore is MemoryPasswordStore)
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
