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
        try? FileManager.default.removeItem(atPath: serverHome)
    }

    private enum Mode {
        /// The master prints its mark and holds its stdin; the forward is
        /// made.
        case connect
        /// One stderr line, then exit 255 — how `ssh` fails.
        case fail(String)
        /// The master holds its stdin and never prints its mark.
        case silent
        /// The forward fails as a server without socket forwarding fails it.
        case refused
    }

    /// The server's home the fake's calls run in: short, its socket under it.
    private var serverHome: String { sockets + "-home" }
    /// The server's socket, where the channel ends on the server.
    private var serverSocket: String { serverHome + "/" + EvlatSocket.relativePath }

    /// The fake and the file the masters' arguments land in, one run per
    /// block (the calls over them in `<log>.calls`).
    private func fakeSSH(_ mode: Mode) throws -> (path: String, log: URL) {
        let log = directory.appendingPathComponent("args.log")
        var environment: [String: String] = [:]
        switch mode {
        case .connect: break
        case .fail(let line): environment["FAKE_SSH_FAIL"] = line
        case .silent: environment["FAKE_SSH_MARK"] = "none"
        case .refused: environment["FAKE_SSH_FORWARD"] = "refused"
        }
        let path = try FakeSSH.make(in: directory, home: serverHome, log: log, environment: environment)
        return (path, log)
    }

    private func runs(in log: URL) -> [[String]] { FakeSSH.runs(in: log) }

    private func calls(in log: URL) -> [[String]] { FakeSSH.runs(in: log, calls: true) }

    private func environment(in log: URL) -> [String] {
        ((try? String(contentsOf: URL(fileURLWithPath: log.path + ".env"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private let machine = RemoteMachine(id: "fake", target: "fake")!
    /// What `ssh` is started with, besides the tunnel's own variables.
    private let base = ["SSH_AUTH_SOCK": "/private/tmp/evlat-test-agent.sock", "HOME": "/Users/ben",
                        "PATH": "/usr/bin:/bin"]

    private func make(ssh path: String, registry: Registry = Registry(),
                      workspace: NotificationCenter = NotificationCenter(),
                      channelDeadline: TimeInterval = 10,
                      schedule: RemoteTunnels.Schedule? = nil) -> RemoteTunnels {
        let made = RemoteTunnels(registry: registry, sshPath: path, platform: .unknown,
                                 now: Date.init, socketDirectory: sockets, environment: base,
                                 workspace: workspace,
                                 channelDeadline: channelDeadline,
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

    /// The machine's end of the channel, once its listener is up.
    private func endpoint(_ tunnels: RemoteTunnels, _ id: String = "fake") throws -> String {
        guard case .listeningAt(let path)? = tunnels.listenerStatus(of: id) else {
            throw XCTSkip("the machine's listener is not up: \(tunnels.listenerStatus(of: id)?.text ?? "none")")
        }
        return path
    }

    // MARK: - Connecting

    /// The order is the channel's: the master with its mark, then over it
    /// the probe with the reading, then the forward of the server's socket
    /// onto the machine's own listener. Only then connected.
    func testAMachineConnectsThroughItsChannel() throws {
        let fake = try fakeSSH(.connect)
        let tunnels = make(ssh: fake.path)
        var readings: [String] = []
        tunnels.onReading = { readings.append($0) }
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }

        let run = try XCTUnwrap(runs(in: fake.log).first)
        let local = try endpoint(tunnels)
        let socket = try XCTUnwrap(RemoteTunnel.controlPath(directory: sockets, machineID: "fake"),
                                   "the test's socket directory is short enough for a master")
        XCTAssertEqual(local, RemoteTunnel.channelPath(directory: sockets, machineID: "fake"))
        XCTAssertEqual(tunnels.controlPath(of: "fake"), socket)
        let mark = try XCTUnwrap(run.last?.components(separatedBy: ";").first?.dropFirst("echo ".count))
        XCTAssertEqual(run, RemoteTunnel.arguments(target: "fake", controlPath: socket, mark: String(mark)),
                       "a master of Evlat's own with no forward of its own, the target after --")
        XCTAssertTrue(mark.hasPrefix("evlat-channel-"))

        let steps = calls(in: fake.log)
        XCTAssertEqual(steps.count, 2, "the probe, then the forward")
        XCTAssertEqual(steps.first, RemoteSettings.arguments(target: "fake", controlPath: socket))
        XCTAssertEqual(steps.last, RemoteTunnel.forwardArguments(target: "fake", controlPath: socket,
                                                                 remote: serverSocket, local: local))
        XCTAssertEqual(readings, ["fake"], "the probe's call read the machine")
        XCTAssertEqual(tunnels.reading(of: "fake")?.channel?.socket, .free)
        XCTAssertEqual(tunnels.reading(of: "fake")?.command, .missing)
        let made = try FileManager.default.attributesOfItem(atPath: serverHome + "/.config/evlat/run")
        XCTAssertEqual(made[.posixPermissions] as? Int, 0o700, "the probe made the server's folder the user's alone")

        XCTAssertEqual(environment(in: fake.log).first, "SSH_AUTH_SOCK=/private/tmp/evlat-test-agent.sock",
                       "ssh sees Evlat's environment, the agent included")
        let mode = try FileManager.default.attributesOfItem(atPath: sockets)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)

        tunnels.remove(id: "fake")
        XCTAssertNil(tunnels.controlPath(of: "fake"))
    }

    /// A socket file left by a master that is gone (`kill -9`) is cleared
    /// before the new master starts; one that answers belongs to a running
    /// master — another Evlat's — and is left alone: with no master of its
    /// own there is no channel, and the try waits.
    func testAStaleMasterSocketIsClearedAndALiveOneIsLeftAlone() throws {
        let socket = try XCTUnwrap(RemoteTunnel.controlPath(directory: sockets, machineID: "fake"))
        try FileManager.default.createDirectory(atPath: sockets, withIntermediateDirectories: true)
        Darwin.close(try bindSocket(at: socket, listening: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let fake = try fakeSSH(.connect)
        var tunnels = make(ssh: fake.path)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "the stale file is gone")
        XCTAssertEqual(runs(in: fake.log).first?.contains("-M"), true)
        tunnels.stopAll()

        held.append(try bindSocket(at: socket, listening: true))
        let other = try fakeSSH(.connect)
        try FileManager.default.removeItem(at: other.log)
        tunnels = make(ssh: other.path, schedule: { _, _ in {} })
        tunnels.add(machine)
        waitUntil("waiting") {
            if case .waiting(_, .other)? = tunnels.state(of: "fake") { return true }
            return false
        }
        XCTAssertEqual(runs(in: other.log), [], "no ssh beside another's live master")
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

    /// Another Evlat's channel answers on the server's socket: the probe
    /// leaves it, no forward is asked, the master closes and the try waits
    /// as `channelBusy`. A socket that refuses is a dead one's: cleared,
    /// and the channel is made over it.
    func testAnAnsweringServerSocketIsLeftAloneAndADeadOneIsCleared() throws {
        try FileManager.default.createDirectory(atPath: (serverSocket as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let other = HookListener(transport: .unix(serverSocket), origin: .machine) { _ in }
        other.start()
        defer { other.stop() }
        guard case .listeningAt = other.awaitSettled(timeout: 5) else {
            throw XCTSkip("the other Evlat's socket did not come up: \(other.status.text)")
        }
        let fake = try fakeSSH(.connect)
        var tunnels = make(ssh: fake.path, schedule: { _, _ in {} })
        tunnels.add(machine)
        waitUntil("busy", timeout: 15) {
            if case .waiting(_, .channelBusy)? = tunnels.state(of: "fake") { return true }
            return false
        }
        XCTAssertEqual(calls(in: fake.log).count, 1, "the probe, and no forward")
        XCTAssertEqual(tunnels.reading(of: "fake")?.channel?.socket, .busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serverSocket), "another Evlat's socket stays")
        tunnels.stopAll()
        other.stop()

        // Its owner gone, its file stays — as `sshd` leaves one.
        Darwin.close(try bindSocket(at: serverSocket, listening: false))
        try FileManager.default.removeItem(at: fake.log.appendingPathExtension("calls"))
        tunnels = make(ssh: fake.path)
        tunnels.add(machine)
        waitUntil("connected", timeout: 15) { tunnels.state(of: "fake")?.isConnected == true }
        XCTAssertEqual(tunnels.reading(of: "fake")?.channel?.socket, .cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: serverSocket), "the dead file went")
        XCTAssertEqual(calls(in: fake.log).count, 2)
    }

    /// The probe found the socket free, the forward failed: the server
    /// allows no socket forwarding.
    func testARefusedForwardIsForwardingRefused() throws {
        let fake = try fakeSSH(.refused)
        let tunnels = make(ssh: fake.path, schedule: { _, _ in {} })
        tunnels.add(machine)
        waitUntil("refused", timeout: 15) {
            if case .waiting(_, .forwardingRefused)? = tunnels.state(of: "fake") { return true }
            return false
        }
        XCTAssertEqual(calls(in: fake.log).count, 2, "the probe, then the forward")
    }

    func testAFailureLineWaitsAndRetriesOnTheSchedule() throws {
        let fake = try fakeSSH(.fail("ssh: connect to host fake port 22: Connection refused"))
        var delays: [TimeInterval] = []
        var retries: [() -> Void] = []
        let tunnels = make(ssh: fake.path, schedule: { delay, run in
            // The channel's deadline is not the schedule under test.
            if delay != 10 {
                delays.append(delay)
                retries.append(run)
            }
            return {}
        })
        tunnels.add(machine)
        waitUntil("waiting") {
            if case .waiting(_, .unreachable)? = tunnels.state(of: "fake") { return true }
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

    /// The mark is a line of its own, found behind a login script's words;
    /// a line that only holds it is not it.
    func testTheMarkIsFoundBehindALoginScriptsWords() {
        let scanner = MarkScanner(mark: "evlat-channel-N")
        XCTAssertFalse(scanner.feed(Data("Welcome\nlast login: evlat-channel-N\nevlat-chan".utf8)))
        XCTAssertTrue(scanner.feed(Data("nel-N\r\nmore".utf8)))
        XCTAssertFalse(scanner.feed(Data("\nevlat-channel-N\n".utf8)), "once")
        XCTAssertFalse(MarkScanner(mark: nil).feed(Data("evlat-channel-N\n".utf8)))
        let chatty = MarkScanner(mark: "m")
        XCTAssertFalse(chatty.feed(Data(repeating: 0x41, count: 100_000)))
        XCTAssertTrue(chatty.feed(Data("\nm\n".utf8)), "a long line before it costs bounded memory")
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

    /// `$TMPDIR` is swept: a channel's end gone from under its listener is
    /// bound again before the next try, so the forward never carries events
    /// to a path nobody listens on.
    func testASweptChannelEndIsBoundAgainBeforeTheNextTry() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        try FileManager.default.removeItem(atPath: local)
        tunnels.sleep()
        tunnels.wake()
        waitUntil("connected again", timeout: 15) {
            tunnels.state(of: "fake")?.isConnected == true && FileManager.default.fileExists(atPath: local)
        }
        XCTAssertEqual(post("/hook", to: local, body: #"{"hook_event_name":"UserPromptSubmit","session_id":"s-4"}"#), 200)
        waitUntil("row") { registry.snapshot().ordered.contains { $0.entity == "remote:fake:s-4" } }
    }

    // MARK: - What arrives

    /// What the server's side posts, sent to the machine's end here as the
    /// channel would carry it.
    private func post(_ route: String, to path: String, body: String,
                      headers: [(String, String)] = []) -> Int {
        guard case .status(let code, _) = UnixHTTP.send(route, socket: path,
                                                        headers: [("Content-Type", "application/json")] + headers,
                                                        body: Data(body.utf8), timeout: 5) else { return -1 }
        return code
    }

    /// The hand-off from the channel: the first request marks the link up
    /// **before** the event lands, so the row is live, not dimmed as
    /// "not heard since the link came up".
    func testATunneledHookBecomesALiveRemoteRowWithoutAPid() throws {
        // A master that never says it is up: only the request can.
        let fake = try fakeSSH(.silent)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry, channelDeadline: 60)
        tunnels.add(machine)
        waitUntil("launched") { self.runs(in: fake.log).count == 1 }
        let local = try endpoint(tunnels)

        XCTAssertEqual(post("/hook", to: local,
                            body: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","evlat_pid":"99"}"#,
                            headers: [("X-Evlat-Pid", "4242")]), 200)

        waitUntil("row") { registry.snapshot().ordered.contains { $0.entity == "remote:fake:s-1" } }
        let row = try XCTUnwrap(registry.snapshot().ordered.first { $0.entity == "remote:fake:s-1" })
        XCTAssertNil(row.activity?.pid, "a remote pid means nothing on this Mac")
        XCTAssertEqual(row.machine?.name, "fake")
        XCTAssertTrue(row.isLive)
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertTrue(tunnels.state(of: "fake")?.isConnected == true)
    }

    // MARK: - Approvals

    /// The approval hook a server's Claude unit installs, run as the agent
    /// runs it: `sh -c` with the request on stdin and the server's home,
    /// whose socket reaches the machine's listener (here a link to it: the
    /// fake makes no forward). Its stdout is the agent's decision.
    private func runApprovalHook(home: String, body: String) throws -> (process: Process, output: () -> Data?) {
        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(.claude), .install, original: nil))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: write.contents) as? [String: Any])
        let groups = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        let command = try XCTUnwrap(groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }.first { $0.contains(ApprovalHook.path) },
            "the server's unit carries the approval command")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(body.utf8))
        try input.fileHandleForWriting.close()
        let lock = NSLock()
        var printed: Data?
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); printed = data; lock.unlock()
        }
        return (process, { lock.lock(); defer { lock.unlock() }; return printed })
    }

    /// End to end: the installed server command waits on the card; Allow
    /// once is the one line on its stdout, and only the asking machine's
    /// row finds it. A channel that closes under a held request is no
    /// decision: empty stdout, exit 0, and the card goes.
    @MainActor
    func testAServersApprovalIsAnsweredFromTheCardAndAClosedChannelIsNoDecision() throws {
        let fake = try fakeSSH(.connect)
        let tunnels = make(ssh: fake.path)
        let store = ApprovalStore(agents: Agents.all)
        tunnels.onApproval = { store.asked($0) }
        tunnels.onHeard = { store.heard($0, machine: $1) }
        tunnels.onAbandoned = { store.abandoned($0) }
        store.respond = { request, response in
            tunnels.answerApproval(request.id, machine: try! XCTUnwrap(request.machine), with: response)
        }
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        try FileManager.default.createDirectory(atPath: (serverSocket as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: serverSocket)
        try FileManager.default.createSymbolicLink(atPath: serverSocket, withDestinationPath: local)
        let body = #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"rm -r build"}}"#

        let allowed = try runApprovalHook(home: serverHome, body: body)
        waitUntil("held") { !store.pending.isEmpty }
        let request = try XCTUnwrap(store.pending.first)
        XCTAssertEqual(request.machine, "fake", "the listener's machine, not the body's")
        XCTAssertEqual(request.source, .claude)
        XCTAssertNil(store.request(forSession: "s-1", machine: nil), "this Mac's row of the same id has no card")
        XCTAssertEqual(store.request(forSession: "s-1", machine: "fake")?.id, request.id)
        XCTAssertTrue(store.answer(request.id, allow: true))
        waitUntil("answered") { !allowed.process.isRunning && allowed.output() != nil }
        XCTAssertEqual(allowed.process.terminationStatus, 0)
        let printed = String(decoding: try XCTUnwrap(allowed.output()), as: UTF8.self)
        XCTAssertEqual(printed, Claude().approvals!.body(.allow(rules: [], directories: [])))
        XCTAssertFalse(printed.contains("\n"), "one line: the decision alone")

        let dropped = try runApprovalHook(home: serverHome, body: body)
        waitUntil("held again") { !store.pending.isEmpty }
        tunnels.remove(id: "fake")
        waitUntil("ended") { !dropped.process.isRunning && dropped.output() != nil }
        XCTAssertEqual(dropped.process.terminationStatus, 0)
        XCTAssertEqual(dropped.output(), Data(), "no decision: the terminal's dialog decides")
        waitUntil("the card goes") { store.pending.isEmpty }
    }

    /// An event heard on the machine resolves its held request as this
    /// Mac's events do: the listener hands it over before the row moves.
    @MainActor
    func testAMachinesEventIsHeardWithItsName() throws {
        let fake = try fakeSSH(.connect)
        let tunnels = make(ssh: fake.path)
        var heard: [(String, String)] = []
        tunnels.onHeard = { heard.append(($0.name, $1)) }
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        XCTAssertEqual(post("/hook", to: local, body: #"{"hook_event_name":"Stop","session_id":"s-1"}"#), 200)
        waitUntil("heard") { !heard.isEmpty }
        XCTAssertEqual(heard.first?.0, "Stop")
        XCTAssertEqual(heard.first?.1, "fake")
    }

    /// A usage report goes to the machine's provider for its own agent —
    /// no agent is singled out — and an agent switched off on the machine
    /// has no provider: its report is dropped and its windows go.
    func testAUsageReportGoesToItsAgentsProviderOnTheMachine() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        func post(_ source: some Agent, _ body: String) -> Int {
            self.post(source.statusLineUsage!.path, to: local, body: body)
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
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        XCTAssertEqual(post("/hook", to: local, body: #"{"hook_event_name":"UserPromptSubmit","session_id":"s-3"}"#), 200)
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
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        XCTAssertEqual(post("/hook", to: local, body: #"{"hook_event_name":"UserPromptSubmit","session_id":"s-2"}"#), 200)
        waitUntil("row") { !registry.snapshot().ordered.isEmpty }
        let pid = try XCTUnwrap(tunnels.processIdentifier(of: "fake"))

        tunnels.remove(id: "fake")
        XCTAssertEqual(registry.snapshot().ordered, [])
        XCTAssertNil(tunnels.state(of: "fake"))
        waitUntil("process gone") { kill(pid, 0) != 0 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: local), "the machine's end goes with it")
    }

    /// A `/signal` through the channel is that machine's outside row —
    /// namespaced, named after the machine, live while the tunnel is up,
    /// dimmed when it goes, gone with the machine. No key: the channel's
    /// end is this user's alone, and a key sent is not read.
    func testASignalThroughTheChannelIsTheMachinesRow() throws {
        let fake = try fakeSSH(.connect)
        let registry = Registry()
        let tunnels = make(ssh: fake.path, registry: registry)
        tunnels.add(machine)
        waitUntil("connected") { tunnels.state(of: "fake")?.isConnected == true }
        let local = try endpoint(tunnels)
        let body = #"{"id":"x","ttl":60,"phase":"working","label":"build","sender":"npm"}"#
        XCTAssertEqual(post(SignalReport.path, to: local, body: body,
                            headers: [("X-Evlat-Key", String(repeating: "c", count: 64))]), 200)
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
    }

    // MARK: - Asking for a password

    /// `Tests/Fixtures/fake-ssh`, copied and warmed: the fake that asks its
    /// askpass. Configured through the environment `ssh` is started with.
    private func promptingSSH() throws -> (path: String, log: URL) {
        let log = directory.appendingPathComponent("prompting.log")
        let path = try FakeSSH.make(in: directory, name: "fake-ssh-prompting", home: serverHome)
        return (path, log)
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
                            port: Bool = true, channelDeadline: TimeInterval = 10,
                            settled: @escaping () -> Bool = { true }) throws -> RemoteTunnels {
        var tunnelsRef: RemoteTunnels?
        // Evlat's socket beside the masters': the directory is short.
        let listener = HookListener(transport: .unix(sockets + "/evlat.sock"),
                                    onAbandoned: { id in tunnelsRef?.abandoned(id) }) { delivery in
            if case .askpass(let request) = delivery { tunnelsRef?.ask(request) }
        }
        listener.start()
        askpassListener = listener
        listener.awaitSettled(timeout: 5)
        let bound = try XCTUnwrap(listener.boundPath, "listener did not come up: \(listener.status.text)")
        var environment = base.merging(extra) { _, new in new }
        environment["FAKE_SSH_LOG"] = log.path
        let made = RemoteTunnels(registry: Registry(), sshPath: path, platform: .unknown,
                                 now: Date.init, socketDirectory: sockets, environment: environment,
                                 workspace: NotificationCenter(), channelDeadline: channelDeadline,
                                 askpass: RemoteTunnels.AskpassRoute(binary: helper, socket: { port ? bound : nil },
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
        tunnels.add(machine)
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
        tunnels.add(machine)
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
        tunnels.add(machine)
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
        tunnels.add(machine)
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
                                     store: store)
        tunnels.onPromptsChanged = { changes += 1 }
        tunnels.add(machine, interactive: true)
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
        let tunnels = try makeAsking(ssh: fake.path, log: fake.log, environment: ["FAKE_SSH_PROMPT1": passwordPrompt])
        tunnels.add(machine, interactive: true)
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
                                     store: store)
        tunnels.add(machine, interactive: true)
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
                                     store: store)
        tunnels.add(machine, interactive: true)
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
        tunnels.add(machine)
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
        tunnels.add(machine)
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
                                 workspace: NotificationCenter(),
                                 store: store, onChange: {})
        tunnels = made
        made.add(machine)
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
        tunnels.add(machine)
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
                                     store: RecordingStore())
        tunnels.add(machine, interactive: true)
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
        tunnels.add(machine)
        waitUntil("the machine's listener is up") {
            if case .listeningAt? = tunnels.listenerStatus(of: "fake") { return true }
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
        XCTAssertTrue(AppController.passwordStore(underTests: false, environment: ["EVLAT_SOCKET": "/tmp/e.sock"])
                      is MemoryPasswordStore)
        XCTAssertTrue(AppController.passwordStore(underTests: false, environment: ["EVLAT_SOCKET": ""])
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
                                                         environment: ["EVLAT_SOCKET": "/tmp/e.sock"]).machines, [])
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
            RemoteMachine.configuration(environment: ["EVLAT_SOCKET": "/tmp/e.sock"], stored: nil),
            environment: ["EVLAT_SOCKET": "/tmp/e.sock"])
        XCTAssertEqual(none, ["remote machines: none (EVLAT_SOCKET is set without EVLAT_MACHINES: no tunnel is opened)"])
        let env = ["EVLAT_MACHINES": "ben@devbox,-x"]
        let lines = AppController.remoteMachineLines(RemoteMachine.configuration(environment: env, stored: nil),
                                                     environment: env)
        XCTAssertEqual(lines.first, "remote machines: 1 (from EVLAT_MACHINES)")
        XCTAssertTrue(lines.contains { $0.contains("machine  devbox  → ben@devbox") })
        XCTAssertTrue(lines.contains { $0.contains("-x ignored") })
    }
}
