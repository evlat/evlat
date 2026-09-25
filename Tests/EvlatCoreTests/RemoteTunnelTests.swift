import XCTest
@testable import EvlatCore

/// The tunnel's pure half: who may be a target, what `ssh` is given, what a
/// failure was and when the next try comes. The clock and the deferred call
/// are closures, so the schedule is read off instead of waited out.
final class RemoteTunnelTests: XCTestCase {
    // MARK: - Targets

    func testTheArgumentsAreTheWholeList() {
        XCTAssertEqual(RemoteTunnel.arguments(target: "ben@devbox", localPort: 50123), [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            // A host's config must not replace the command or empty its stdin.
            "-o", "RemoteCommand=none",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
            // The remote end is the port the installed command names, the
            // local end the machine's own listener.
            "-R", "127.0.0.1:48151:127.0.0.1:50123",
            "--", "ben@devbox", "cat >/dev/null",
        ])
    }

    func testTheTargetComesAfterTheOptionTerminator() throws {
        let arguments = RemoteTunnel.arguments(target: "devbox", localPort: 1)
        let terminator = try XCTUnwrap(arguments.firstIndex(of: "--"))
        XCTAssertEqual(arguments[terminator + 1], "devbox")
        XCTAssertEqual(arguments.count, terminator + 3, "only the target and the remote command follow")
    }

    func testTargetsThatAreNotHostsAreRefused() {
        XCTAssertEqual(RemoteMachine.validate(target: ""), .empty)
        XCTAssertEqual(RemoteMachine.validate(target: "-oProxyCommand=touch /tmp/x"), .option)
        XCTAssertEqual(RemoteMachine.validate(target: "-oProxyCommand=x"), .option)
        XCTAssertEqual(RemoteMachine.validate(target: "a b"), .invalidCharacter)
        XCTAssertEqual(RemoteMachine.validate(target: "devbox\n"), .invalidCharacter)
        XCTAssertEqual(RemoteMachine.validate(target: "dev\u{7}box"), .invalidCharacter)
        XCTAssertNil(RemoteMachine(id: "x", target: "-oProxyCommand=x"))
        XCTAssertNil(RemoteMachine.validate(target: "ben@devbox.example.com"))
        XCTAssertNil(RemoteMachine.validate(target: "devbox"))
    }

    func testTheNameIsTheHostOrTheAlias() {
        XCTAssertEqual(RemoteMachine(id: "1", target: "ben@sunucu")?.name, "sunucu")
        XCTAssertEqual(RemoteMachine(id: "1", target: "devbox")?.name, "devbox")
        XCTAssertEqual(RemoteMachine(id: "1", target: "ben@")?.name, "ben@")
        XCTAssertEqual(RemoteMachine(id: "1", target: "ben@sunucu")?.identity,
                       Signal.Machine.Identity(id: "1", name: "sunucu"))
    }

    // MARK: - Which machines

    private func stored(_ machines: [RemoteMachine]) -> Data? { RemoteMachine.encode(machines) }

    func testTheEnvironmentListReplacesTheStoredOne() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "saved"))
        let config = RemoteMachine.configuration(environment: ["EVLAT_MACHINES": "fake, ben@devbox,,-x"],
                                                 stored: stored([saved]))
        XCTAssertEqual(config.machines.map(\.target), ["fake", "ben@devbox"])
        // The id is the target: nowhere to keep a generated one.
        XCTAssertEqual(config.machines.map(\.id), ["fake", "ben@devbox"])
        XCTAssertTrue(config.fromEnvironment)
        XCTAssertEqual(config.rejected, ["-x"])
    }

    // MARK: - Signal keys

    /// Every machine has a key (`013`): a stored one is kept, a missing or
    /// unusable one is made, and a key whose machine is gone is dropped.
    func testEveryMachineGetsAKeyAndOnlyTheListedOnesKeepOne() throws {
        let kept = String(repeating: "a", count: 64)
        let machines = try ["m-1", "m-2", "m-3"].map { try XCTUnwrap(RemoteMachine(id: $0, target: "t\($0)")) }
        var made = 0
        let keys = RemoteMachine.signalKeys(
            for: machines,
            stored: ["m-1": kept, "m-2": "short", "gone": String(repeating: "b", count: 64), "m-3": 7],
            generate: { made += 1; return String(repeating: "\(made)", count: 64) })
        XCTAssertEqual(keys, ["m-1": kept,
                              "m-2": String(repeating: "1", count: 64),
                              "m-3": String(repeating: "2", count: 64)])
        XCTAssertEqual(RemoteMachine.signalKeys(for: [], stored: nil, generate: { "x" }), [:])
        XCTAssertEqual(RemoteMachine.signalKeysStorageKey, "remote.signalKeys")
        XCTAssertTrue(RemoteMachine.isSignalKey(kept))
        XCTAssertFalse(RemoteMachine.isSignalKey(String(repeating: "g", count: 64)))
        XCTAssertFalse(RemoteMachine.isSignalKey(String(repeating: "a", count: 63)))
    }

    func testAnEmptyEnvironmentListMeansNoMachine() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "saved"))
        let config = RemoteMachine.configuration(environment: ["EVLAT_MACHINES": ""], stored: stored([saved]))
        XCTAssertEqual(config.machines, [])
        XCTAssertTrue(config.fromEnvironment)
    }

    /// A process measured on another port must not open a second tunnel to
    /// the user's servers.
    func testAPortOverrideWithoutAMachineListOpensNoTunnel() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "saved"))
        let config = RemoteMachine.configuration(environment: ["EVLAT_PORT": "48999"], stored: stored([saved]))
        XCTAssertEqual(config.machines, [])
        let both = RemoteMachine.configuration(environment: ["EVLAT_PORT": "48999", "EVLAT_MACHINES": "fake"],
                                               stored: stored([saved]))
        XCTAssertEqual(both.machines.map(\.target), ["fake"])
    }

    func testTheStoredListIsReadEntryByEntry() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "ben@devbox"))
        let config = RemoteMachine.configuration(environment: [:], stored: stored([saved]))
        XCTAssertEqual(config.machines, [saved])
        XCTAssertFalse(config.fromEnvironment)
        // A refused target and a malformed entry drop themselves only.
        let mixed = Data(#"[{"id":"a","target":"-oX"},{"id":"b"},{"id":"c","target":"ok"}]"#.utf8)
        XCTAssertEqual(RemoteMachine.decode(mixed).map(\.id), ["c"])
        XCTAssertEqual(RemoteMachine.decode(Data("not json".utf8)), [])
        XCTAssertEqual(RemoteMachine.decode(nil), [])
    }

    // MARK: - Failures

    func testEachOpenSSHLineIsClassified() {
        let samples: [(String, RemoteTunnel.Failure)] = [
            ("ben@devbox: Permission denied (publickey).", .authentication),
            ("Error: remote port forwarding failed for listen port 48151", .portBusy),
            ("Host key verification failed.", .hostKey),
            ("ssh: Could not resolve hostname devbox: nodename nor servname provided, or not known", .hostName),
            ("ssh: connect to host devbox port 22: Connection refused", .unreachable),
            ("ssh: connect to host devbox port 22: Operation timed out", .unreachable),
            ("ssh: connect to host devbox port 22: Network is unreachable", .unreachable),
            ("Connection closed by 10.0.0.2 port 22", .other),
            ("", .other),
        ]
        for (line, expected) in samples {
            XCTAssertEqual(RemoteTunnel.classify(stderr: line), expected, line)
        }
        // A warning ahead of the line that matters does not decide it.
        XCTAssertEqual(RemoteTunnel.classify(stderr: """
            Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.
            Error: remote port forwarding failed for listen port 48151
            """), .portBusy)
    }

    // MARK: - Schedule

    func testTheWaitDoublesUpToFiveMinutes() {
        XCTAssertEqual((1...10).map { RemoteTunnel.delay(afterFailures: $0) },
                       [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        XCTAssertEqual(RemoteTunnel.delay(afterFailures: 1_000), 300)
    }

    // MARK: - State machine

    /// The shell's side, by hand: launches are counted, the clock is moved,
    /// and scheduled calls wait in a list until the test runs them.
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var launches: [Int] = []
        var terminations = 0
        var scheduled: [(delay: TimeInterval, run: () -> Void, cancelled: Bool)] = []
        var changes: [RemoteTunnel.State] = []
        /// What a launch does: nothing (a process now runs) by default.
        var onLaunch: (Int) -> Void = { _ in }

        lazy var tunnel: RemoteTunnel = {
            let tunnel = RemoteTunnel(effects: RemoteTunnel.Effects(
                launch: { [unowned self] generation in
                    self.launches.append(generation)
                    self.onLaunch(generation)
                },
                terminate: { [unowned self] in self.terminations += 1 },
                now: { [unowned self] in self.now },
                schedule: { [unowned self] delay, run in
                    let index = self.scheduled.count
                    self.scheduled.append((delay, run, false))
                    return { [unowned self] in self.scheduled[index].cancelled = true }
                }))
            tunnel.onChange = { [unowned self] in self.changes.append($0) }
            return tunnel
        }()

        /// The live scheduled calls' delays.
        var pending: [TimeInterval] { scheduled.filter { !$0.cancelled }.map(\.delay) }

        func runPending() {
            let live = scheduled.indices.filter { !scheduled[$0].cancelled }
            for index in live {
                scheduled[index].cancelled = true
                scheduled[index].run()
            }
        }
    }

    func testAProcessThatStaysUpConnects() {
        let h = Harness()
        h.tunnel.start()
        XCTAssertEqual(h.launches, [1])
        XCTAssertEqual(h.tunnel.state, .connecting)
        XCTAssertEqual(h.pending, [RemoteTunnel.defaultConfirmAfter])
        h.now += 3
        h.runPending()
        XCTAssertEqual(h.tunnel.state, .connected(since: h.now))
    }

    func testARequestConnectsWithoutWaiting() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.heard()
        XCTAssertEqual(h.tunnel.state, .connected(since: h.now))
        XCTAssertEqual(h.pending, [], "the confirmation is no longer needed once heard")
    }

    func testAFailureWaitsOnTheScheduleAndTriesAgain() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.exited(generation: 1, stderr: "Error: remote port forwarding failed for listen port 48151")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .portBusy))
        XCTAssertEqual(h.pending, [2])
        h.now += 2
        h.runPending()
        XCTAssertEqual(h.launches, [1, 2])
        h.tunnel.exited(generation: 2, stderr: "Permission denied (publickey).")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 4, failure: .authentication))
        XCTAssertEqual(h.pending, [4])
    }

    func testATunnelThatStayedUpStartsTheScheduleOver() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.exited(generation: 1, stderr: "")
        h.runPending()
        h.tunnel.exited(generation: 2, stderr: "")
        XCTAssertEqual(h.pending, [4])
        h.runPending()
        h.tunnel.heard()
        // Up for less than a minute: still counting.
        h.now += 59
        h.tunnel.exited(generation: 3, stderr: "")
        XCTAssertEqual(h.pending, [8])
        h.runPending()
        h.tunnel.heard()
        h.now += 60
        h.tunnel.exited(generation: 4, stderr: "")
        XCTAssertEqual(h.pending, [2])
    }

    func testALaunchThatFailsAtOnceStillWaits() {
        let h = Harness()
        h.onLaunch = { [unowned h] generation in h.tunnel.exited(generation: generation, stderr: "no such file") }
        h.tunnel.start()
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .other))
        XCTAssertEqual(h.pending, [2], "no confirmation is scheduled for a process that is gone")
    }

    func testSleepClosesTheProcessAndWakeTriesAtOnce() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.heard()
        h.tunnel.sleep()
        XCTAssertEqual(h.terminations, 1)
        XCTAssertEqual(h.tunnel.state, .stopped)
        // The terminated process's exit arrives late and changes nothing.
        h.tunnel.exited(generation: 1, stderr: "Connection closed")
        XCTAssertEqual(h.tunnel.state, .stopped)
        XCTAssertEqual(h.pending, [])
        h.tunnel.wake()
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertEqual(h.tunnel.state, .connecting)
    }

    func testWakeDropsAPendingWait() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.exited(generation: 1, stderr: "")
        h.runPending()
        h.tunnel.exited(generation: 2, stderr: "")
        XCTAssertEqual(h.pending, [4])
        h.tunnel.sleep()
        XCTAssertEqual(h.pending, [])
        h.tunnel.wake()
        XCTAssertEqual(h.launches.count, 3)
        h.tunnel.exited(generation: h.launches.last!, stderr: "")
        XCTAssertEqual(h.pending, [2], "the schedule starts over after a wake")
    }

    func testStopEndsForGood() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.stop()
        XCTAssertEqual(h.terminations, 1)
        h.tunnel.exited(generation: 1, stderr: "")
        h.tunnel.wake()
        XCTAssertEqual(h.launches, [1])
        XCTAssertEqual(h.tunnel.state, .stopped)
    }

    func testEveryChangeIsReported() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.heard()
        h.tunnel.exited(generation: 1, stderr: "")
        XCTAssertEqual(h.changes.count, 3)
        XCTAssertEqual(h.changes.first, .connecting)
        XCTAssertTrue(h.changes[1].isConnected)
    }
}
