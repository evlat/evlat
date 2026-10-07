import XCTest
@testable import EvlatCore

/// The tunnel's pure half: who may be a target, what `ssh` is given, what a
/// failure was and when the next try comes. The clock and the deferred call
/// are closures, so the schedule is read off instead of waited out.
final class RemoteTunnelTests: XCTestCase {
    // MARK: - Targets

    func testTheArgumentsAreTheWholeList() {
        XCTAssertEqual(RemoteTunnel.arguments(target: "ben@devbox", controlPath: "/tmp/e/d8ca92b2",
                                              mark: "evlat-channel-N"), [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            // On the command line these win over a host's `ControlMaster`,
            // `ControlPath` and `ControlPersist`: the master is Evlat's and
            // ends with the tunnel.
            "-M",
            "-S", "/tmp/e/d8ca92b2",
            "-o", "ControlPersist=no",
            // A host's config must not replace the command or empty its stdin.
            "-o", "RemoteCommand=none",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
            // No `-R` here: the master would remember a forward that failed.
            "--", "ben@devbox", "echo evlat-channel-N; exec cat >/dev/null",
        ])
        XCTAssertEqual(RemoteTunnel.arguments(target: "devbox", controlPath: "/s", mark: "m").filter { $0 == "-M" }.count,
                       1, "a second -M would make it ControlMaster=ask")
        XCTAssertFalse(RemoteTunnel.arguments(target: "devbox", controlPath: "/s", mark: "m").contains("-R"))
        XCTAssertEqual(RemoteTunnel.mark(nonce: "N"), "evlat-channel-N")
    }

    /// The forward, as measured over a master (OpenSSH 9.6p1 server, 10.2p1
    /// client): socket to socket, the server's end absolute.
    func testTheForwardIsAskedOfTheMasterOnly() {
        XCTAssertEqual(RemoteTunnel.forwardArguments(target: "ben@devbox", controlPath: "/tmp/e/d8ca92b2",
                                                     remote: "/home/ben/.config/evlat/run/evlat.sock",
                                                     local: "/tmp/e/d8ca92b2.sock"), [
            "-S", "/tmp/e/d8ca92b2",
            "-o", "ControlMaster=no",
            // A master that has gone is no call, never a login of its own.
            "-o", "ProxyCommand=/usr/bin/false",
            "-O", "forward",
            "-R", "/home/ben/.config/evlat/run/evlat.sock:/tmp/e/d8ca92b2.sock",
            "--", "ben@devbox",
        ])
    }

    /// With an askpass to ask, `ssh` may prompt — once per method — and
    /// the prompt goes to Evlat; without one it never prompts at all: a
    /// controlling terminal would otherwise be asked.
    func testWithAnAskpassSSHMayPromptOnce() {
        let plain = RemoteTunnel.arguments(target: "devbox", controlPath: "/s", mark: "m")
        let asking = RemoteTunnel.arguments(target: "devbox", controlPath: "/s", mark: "m", askpass: true)
        XCTAssertTrue(plain.contains("BatchMode=yes"))
        XCTAssertFalse(plain.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(asking.contains("BatchMode=yes"))
        XCTAssertTrue(asking.contains("BatchMode=no"))
        XCTAssertTrue(asking.contains("NumberOfPasswordPrompts=1"))
        XCTAssertEqual(asking.filter { $0 != "BatchMode=no" && $0 != "NumberOfPasswordPrompts=1" && $0 != "-o" },
                       plain.filter { $0 != "BatchMode=yes" && $0 != "-o" }, "nothing else moves")
        XCTAssertEqual(Array(asking.suffix(3)), ["--", "devbox", "echo m; exec cat >/dev/null"])
    }

    func testTheSocketPathIsShortAndTheSameOnEveryLaunch() {
        XCTAssertEqual(RemoteTunnel.controlPath(directory: "/tmp/e", machineID: "ben@devbox"), "/tmp/e/d8ca92b2")
        XCTAssertEqual(RemoteTunnel.controlPath(directory: "/tmp/e/", machineID: "fake"), "/tmp/e/21580954")
        XCTAssertNotEqual(RemoteTunnel.controlPath(directory: "/tmp/e", machineID: "a"),
                          RemoteTunnel.controlPath(directory: "/tmp/e", machineID: "b"))
        // 104 bytes of `sun_path`, less the 17 `ssh` appends while it sets
        // the socket up, less the terminator: 86.
        XCTAssertEqual(RemoteTunnel.socketPathLimit, 86)
        let fits = "/" + String(repeating: "d", count: 86 - 10)
        XCTAssertEqual(RemoteTunnel.controlPath(directory: fits, machineID: "x")?.utf8.count, 86)
        XCTAssertNil(RemoteTunnel.controlPath(directory: fits + "d", machineID: "x"), "one byte over")
        XCTAssertNil(RemoteTunnel.controlPath(directory: "/tmp/%h", machineID: "x"),
                     "ssh expands % in a control path")
        XCTAssertNil(RemoteTunnel.controlPath(directory: "", machineID: "x"))
    }

    /// The channel's end here sits beside the master's socket, and only
    /// an address's limit applies: `ssh` connects to it, it does not bind.
    func testTheChannelsEndIsTheMastersPathWithSock() {
        XCTAssertEqual(RemoteTunnel.channelPath(directory: "/tmp/e", machineID: "ben@devbox"), "/tmp/e/d8ca92b2.sock")
        let fits = "/" + String(repeating: "d", count: 103 - 15)
        XCTAssertEqual(RemoteTunnel.channelPath(directory: fits, machineID: "x")?.utf8.count, 103)
        XCTAssertNil(RemoteTunnel.channelPath(directory: fits + "d", machineID: "x"), "one byte over")
        XCTAssertNil(RemoteTunnel.channelPath(directory: "/tmp/a:b", machineID: "x"), "-R reads a colon as its separator")
    }

    // MARK: - The probe

    func testTheProbesLineIsReadBehindABanner() {
        let output = Data("""
            Welcome to devbox
            N2 channel busy ok /x
            N channel cleared ok /home/ben smith/.config/evlat/run/evlat.sock
            N command 0 missing -

            """.utf8)
        XCTAssertEqual(RemoteTunnel.channel(output: output, nonce: "N"),
                       RemoteTunnel.Channel(socket: .cleared, curl: .ok,
                                            path: "/home/ben smith/.config/evlat/run/evlat.sock"))
        XCTAssertEqual(RemoteTunnel.channel(output: Data("N channel homeless none \n".utf8), nonce: "N"),
                       RemoteTunnel.Channel(socket: .homeless, curl: .none, path: ""))
        XCTAssertNil(RemoteTunnel.channel(output: Data("N channel odd ok /x\n".utf8), nonce: "N"))
        XCTAssertNil(RemoteTunnel.channel(output: Data(), nonce: "N"))
    }

    func testTheEnvironmentIsAddedToEvlatsOwn() {
        let base = ["SSH_AUTH_SOCK": "/private/tmp/agent.sock", "PATH": "/usr/bin", "HOME": "/Users/ben"]
        XCTAssertEqual(RemoteTunnel.environment(base: base, askpass: nil), base, "the agent is kept")
        let added = RemoteTunnel.environment(base: base, askpass: ["SSH_ASKPASS": "/x/Evlat", "PATH": "/ours"])
        XCTAssertEqual(added["SSH_AUTH_SOCK"], "/private/tmp/agent.sock")
        XCTAssertEqual(added["HOME"], "/Users/ben")
        XCTAssertEqual(added["SSH_ASKPASS"], "/x/Evlat")
        XCTAssertEqual(added["PATH"], "/ours", "the tunnel's own variables win")
    }

    func testTheTargetComesAfterTheOptionTerminator() throws {
        let arguments = RemoteTunnel.arguments(target: "devbox", controlPath: "/s", mark: "m")
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

    func testAnEmptyEnvironmentListMeansNoMachine() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "saved"))
        let config = RemoteMachine.configuration(environment: ["EVLAT_MACHINES": ""], stored: stored([saved]))
        XCTAssertEqual(config.machines, [])
        XCTAssertTrue(config.fromEnvironment)
    }

    /// A second Evlat must not open a second tunnel to the user's
    /// servers; `EVLAT_HOME` alone moves files, not whose Evlat it is.
    func testASecondEvlatWithoutAMachineListOpensNoTunnel() throws {
        let saved = try XCTUnwrap(RemoteMachine(id: "u-1", target: "saved"))
        let config = RemoteMachine.configuration(environment: ["EVLAT_SOCKET": "/tmp/e.sock"], stored: stored([saved]))
        XCTAssertEqual(config.machines, [])
        let both = RemoteMachine.configuration(environment: ["EVLAT_SOCKET": "/tmp/e.sock", "EVLAT_MACHINES": "fake"],
                                               stored: stored([saved]))
        XCTAssertEqual(both.machines.map(\.target), ["fake"])
        XCTAssertEqual(RemoteMachine.configuration(environment: ["EVLAT_HOME": "/tmp/h"], stored: stored([saved]))
            .machines.map(\.target), ["saved"])
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

    /// An entry stored before the machines had switches reads with every
    /// agent on and is written back as it was: the field appears only once
    /// the user changes a switch, and a name this build does not know stays.
    func testAnEntryWithoutAgentsIsTheLiveDefaultAndIsNotRewritten() throws {
        let old = Data(#"[{"id":"u-1","target":"ben@devbox"}]"#.utf8)
        let machine = try XCTUnwrap(RemoteMachine.decode(old).first)
        XCTAssertNil(machine.agents)
        XCTAssertEqual(machine.enabledAgents(of: [.test, .other]), [.test, .other])
        let again = try XCTUnwrap(RemoteMachine.encode([machine]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: again) as? [[String: Any]])
        XCTAssertEqual(object.first?.keys.sorted(), ["id", "target"], "no agents key written for nil")

        var changed = machine
        changed.agents = ["other", "later-agent"]
        let stored = try XCTUnwrap(RemoteMachine.encode([changed]))
        let back = try XCTUnwrap(RemoteMachine.decode(stored).first)
        XCTAssertEqual(back.agents, ["other", "later-agent"])
        XCTAssertEqual(back.enabledAgents(of: [.test, .other]), [.other])
    }

    // MARK: - Failures

    func testEachOpenSSHLineIsClassified() {
        let samples: [(String, RemoteTunnel.Failure)] = [
            ("ben@devbox: Permission denied (publickey).", .authentication),
            // A refused forward's line says nothing on its own: the probe
            // before it decides between busy and refused.
            ("mux_client_forward: forwarding request failed: remote port forwarding failed for listen path /x", .other),
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
            Host key verification failed.
            """), .hostKey)
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
        var stored = false
        var probes: [Int] = []
        var forwards: [(generation: Int, remote: String)] = []

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
                },
                hasStoredPassword: { [unowned self] in self.stored },
                probe: { [unowned self] in self.probes.append($0) },
                forward: { [unowned self] in self.forwards.append(($0, $1)) }))
            tunnel.onChange = { [unowned self] in self.changes.append($0) }
            return tunnel
        }()

        static let free = RemoteTunnel.Channel(socket: .free, curl: .ok, path: "/home/ben/.config/evlat/run/evlat.sock")

        /// The try `generation`'s channel, made: the mark, a free socket,
        /// the forward.
        func connect(_ generation: Int) {
            tunnel.marked(generation: generation)
            tunnel.probed(generation: generation, channel: Self.free)
            tunnel.forwarded(generation: generation, made: true)
        }

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

    /// The order is the channel's: the mark, the probe, the forward —
    /// each asked for once its step before has answered. Only the forward
    /// made is connected.
    func testAChannelMadeOverTheMasterConnects() {
        let h = Harness()
        h.tunnel.start()
        XCTAssertEqual(h.launches, [1])
        XCTAssertEqual(h.tunnel.state, .connecting)
        XCTAssertEqual(h.pending, [RemoteTunnel.defaultChannelDeadline])
        XCTAssertEqual(h.probes, [], "no probe before the mark")
        h.tunnel.marked(generation: 1)
        h.tunnel.marked(generation: 1)
        XCTAssertEqual(h.probes, [1], "once")
        XCTAssertEqual(h.forwards.count, 0, "no forward before the probe")
        h.tunnel.probed(generation: 1, channel: Harness.free)
        XCTAssertEqual(h.forwards.map(\.remote), [Harness.free.path])
        XCTAssertEqual(h.tunnel.state, .connecting, "not before the forward is made")
        h.now += 3
        h.tunnel.forwarded(generation: 1, made: true)
        XCTAssertEqual(h.tunnel.state, .connected(since: h.now))
        XCTAssertEqual(h.pending, [], "the deadline is no longer needed")
    }

    /// A socket a dead connection left, cleared by the probe, or one it
    /// could not ask: the forward goes ahead.
    func testAClearedOrUnaskedSocketIsForwarded() {
        for socket in [RemoteTunnel.Channel.Socket.cleared, .unknown] {
            let h = Harness()
            h.tunnel.start()
            h.tunnel.marked(generation: 1)
            h.tunnel.probed(generation: 1, channel: RemoteTunnel.Channel(socket: socket, curl: .none, path: "/p"))
            XCTAssertEqual(h.forwards.map(\.remote), ["/p"], socket.rawValue)
        }
    }

    /// Another Evlat answers on the server's socket: no forward is asked,
    /// the master closes, and the try waits as `channelBusy`.
    func testABusySocketIsLeftAloneAndTheTryWaits() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.marked(generation: 1)
        h.tunnel.probed(generation: 1, channel: RemoteTunnel.Channel(socket: .busy, curl: .ok, path: "/p"))
        XCTAssertEqual(h.forwards.count, 0)
        XCTAssertEqual(h.terminations, 1, "the master is closed")
        h.tunnel.heard()
        XCTAssertEqual(h.tunnel.state, .connecting, "a failed try is not heard into connected")
        h.tunnel.exited(generation: 1, stderr: "Shared connection to devbox closed.")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .channelBusy))
        XCTAssertEqual(h.pending, [2])
    }

    /// The probe found the socket free and the forward failed: the server
    /// refuses socket forwarding (or another Mac took it in between).
    func testARefusedForwardIsForwardingRefused() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.marked(generation: 1)
        h.tunnel.probed(generation: 1, channel: Harness.free)
        h.tunnel.forwarded(generation: 1, made: false)
        XCTAssertEqual(h.terminations, 1)
        h.tunnel.exited(generation: 1, stderr: "")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .forwardingRefused))
    }

    /// No answer, or a server's end the channel cannot have: `other`.
    func testAProbeThatCannotGiveAChannelIsOther() {
        let channels: [RemoteTunnel.Channel?] = [nil] + [RemoteTunnel.Channel.Socket.long, .unwritable, .homeless]
            .map { RemoteTunnel.Channel(socket: $0, curl: .ok, path: "") }
        for channel in channels {
            let h = Harness()
            h.tunnel.start()
            h.tunnel.marked(generation: 1)
            h.tunnel.probed(generation: 1, channel: channel)
            XCTAssertEqual(h.forwards.count, 0)
            h.tunnel.exited(generation: 1, stderr: "")
            XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .other))
        }
    }

    /// A master that never prints its mark — a server's shell that holds
    /// the command — ends at the deadline instead of reading connected.
    func testAMasterWithoutItsMarkEndsAtTheDeadline() {
        let h = Harness()
        h.tunnel.start()
        h.now += RemoteTunnel.defaultChannelDeadline
        h.runPending()
        XCTAssertEqual(h.terminations, 1)
        XCTAssertEqual(h.tunnel.state, .connecting, "until its exit")
        h.tunnel.exited(generation: 1, stderr: "")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .other))
    }

    /// A step's answer about an earlier try changes nothing.
    func testAnEarlierTrysAnswerChangesNothing() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.marked(generation: 1)
        h.tunnel.exited(generation: 1, stderr: "Connection refused")
        h.runPending()
        XCTAssertEqual(h.launches, [1, 2])
        h.tunnel.probed(generation: 1, channel: Harness.free)
        h.tunnel.forwarded(generation: 1, made: true)
        XCTAssertEqual(h.forwards.count, 0)
        XCTAssertEqual(h.tunnel.state, .connecting)
        h.connect(2)
        XCTAssertTrue(h.tunnel.state.isConnected)
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
        h.tunnel.exited(generation: 1, stderr: "ssh: connect to host devbox port 22: Connection refused")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .unreachable))
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

    // MARK: - Passwords

    /// While a prompt is up nothing is known about the login, and no
    /// deadline runs: the user may take their time. The answer starts the
    /// deadline over.
    func testAHeldPromptHoldsTheDeadline() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.promptOpened()
        XCTAssertEqual(h.pending, [], "nobody has answered")
        h.tunnel.promptAnswered(sentPassword: true)
        XCTAssertEqual(h.pending, [RemoteTunnel.defaultChannelDeadline], "the wait starts over at the answer")
        h.now += 5
        h.connect(1)
        XCTAssertEqual(h.tunnel.state, .connected(since: h.now))
        XCTAssertTrue(h.tunnel.lastConnectedWithPassword)
    }

    /// A password that was sent and refused is not sent again: the tunnel
    /// stops and waits for the user, with no timer.
    func testASentPasswordRefusedWaitsForTheUser() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.promptOpened()
        h.tunnel.promptAnswered(sentPassword: true)
        h.tunnel.exited(generation: 1, stderr: "user@devbox: Permission denied (publickey,password).")
        XCTAssertEqual(h.tunnel.state, .needsUser(rejected: true))
        XCTAssertEqual(h.pending, [], "no retry")
    }

    /// A second factor after the password, refused or answered wrong: the
    /// login's refusal says nothing about the password, so the user is
    /// asked again and nothing reads as "password refused".
    func testARefusalAfterASecondFactorIsNotAPasswordRefused() {
        for refused in [true, false] {
            let h = Harness()
            h.tunnel.start()
            h.tunnel.promptOpened()
            h.tunnel.promptAnswered(sentPassword: true)
            h.tunnel.promptOpened()
            if refused { h.tunnel.promptRefused(password: false) } else { h.tunnel.promptAnswered(sentPassword: false) }
            h.tunnel.exited(generation: 1, stderr: "Permission denied (keyboard-interactive).")
            XCTAssertEqual(h.tunnel.state, .needsUser(rejected: false), "refused: \(refused)")
            XCTAssertEqual(h.pending, [])
        }
    }

    /// A refusal after the channel was made: the password was still
    /// refused, and is not sent again.
    func testARefusalAfterConnectingIsStillARefusal() {
        let h = Harness()
        h.tunnel.start(interactive: true)
        h.tunnel.promptOpened()
        h.tunnel.promptAnswered(sentPassword: true)
        h.connect(1)
        XCTAssertTrue(h.tunnel.state.isConnected)
        h.tunnel.exited(generation: 1, stderr: "Permission denied (password).")
        XCTAssertEqual(h.tunnel.state, .needsUser(rejected: true))
        XCTAssertEqual(h.pending, [])
    }

    /// A quiet try that met a password prompt it could not answer stops when
    /// a password is known to be the way in: one is stored, or the last
    /// connection was made with one.
    func testAQuietPasswordPromptStopsWhenAPasswordIsTheWayIn() {
        let stored = Harness()
        stored.stored = true
        stored.tunnel.start()
        stored.tunnel.promptOpened()
        stored.tunnel.promptRefused(password: true)
        stored.tunnel.exited(generation: 1, stderr: "Permission denied (password).")
        XCTAssertEqual(stored.tunnel.state, .needsUser(rejected: false))
        XCTAssertEqual(stored.pending, [])

        let before = Harness()
        before.tunnel.start(interactive: true)
        before.tunnel.promptOpened()
        before.tunnel.promptAnswered(sentPassword: true)
        before.connect(1)
        XCTAssertTrue(before.tunnel.lastConnectedWithPassword)
        before.tunnel.sleep()
        before.tunnel.wake()
        XCTAssertEqual(before.tunnel.mode, .quiet, "a wake tries quietly")
        before.tunnel.promptOpened()
        before.tunnel.promptRefused(password: true)
        before.tunnel.exited(generation: before.launches.last!, stderr: "Permission denied (password).")
        XCTAssertEqual(before.tunnel.state, .needsUser(rejected: false))
    }

    /// Without either, a password prompt is a failure like the others: the
    /// row says a password is needed and the schedule goes on.
    func testAQuietPasswordPromptOtherwiseWaitsOnTheSchedule() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.promptOpened()
        h.tunnel.promptRefused(password: true)
        h.tunnel.exited(generation: 1, stderr: "Permission denied (publickey,password).")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .passwordNeeded))
        XCTAssertEqual(h.pending, [2])
        XCTAssertTrue(h.tunnel.asksForPassword)
    }

    /// A refused host key question is not a password: the failure is
    /// OpenSSH's own line, as before.
    func testARefusedHostKeyQuestionIsAHostKeyFailure() {
        let h = Harness()
        h.stored = true
        h.tunnel.start()
        h.tunnel.promptOpened()
        h.tunnel.promptRefused(password: false)
        h.tunnel.exited(generation: 1, stderr: "Host key verification failed.")
        XCTAssertEqual(h.tunnel.state, .waiting(retryAt: h.now + 2, failure: .hostKey))
    }

    /// Waiting for the user outlives a sleep and a start; only the user's
    /// own try leaves it, interactive and with the schedule from zero.
    func testOnlyTheUserLeavesWaitingForTheUser() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.promptOpened()
        h.tunnel.promptAnswered(sentPassword: true)
        h.tunnel.exited(generation: 1, stderr: "Permission denied (password).")
        XCTAssertEqual(h.tunnel.state, .needsUser(rejected: true))
        h.tunnel.sleep()
        XCTAssertEqual(h.tunnel.state, .needsUser(rejected: true), "kept through a sleep")
        h.tunnel.wake()
        h.tunnel.start()
        XCTAssertEqual(h.launches, [1], "no quiet try behind the user's back")
        XCTAssertEqual(h.tunnel.state, .needsUser(rejected: true))

        h.tunnel.retryByUser()
        XCTAssertEqual(h.launches, [1, 2])
        XCTAssertEqual(h.tunnel.mode, .interactive)
        XCTAssertEqual(h.tunnel.state, .connecting)
        h.tunnel.exited(generation: 2, stderr: "Connection refused")
        XCTAssertEqual(h.pending, [2], "the schedule starts over")
        h.runPending()
        XCTAssertEqual(h.tunnel.mode, .quiet, "a retry on the schedule is quiet")
    }

    /// A password prompt on the user's own try can be retried from the row
    /// too: "password needed" offers the same press.
    func testTheUserCanTryAgainFromAPasswordNeededWait() {
        let h = Harness()
        h.tunnel.start()
        h.tunnel.promptOpened()
        h.tunnel.promptRefused(password: true)
        h.tunnel.exited(generation: 1, stderr: "Permission denied (password).")
        XCTAssertEqual(h.pending, [2])
        h.tunnel.retryByUser()
        XCTAssertEqual(h.pending, [RemoteTunnel.defaultChannelDeadline], "the pending retry is dropped")
        XCTAssertEqual(h.tunnel.mode, .interactive)
        XCTAssertEqual(h.launches, [1, 2])
    }

    /// A connection made without a password clears what the last one said.
    func testAKeyLoginClearsThePasswordBit() {
        let h = Harness()
        h.tunnel.start(interactive: true)
        h.tunnel.promptOpened()
        h.tunnel.promptAnswered(sentPassword: true)
        h.tunnel.heard()
        XCTAssertTrue(h.tunnel.lastConnectedWithPassword)
        h.tunnel.exited(generation: 1, stderr: "")
        h.runPending()
        h.tunnel.heard()
        XCTAssertFalse(h.tunnel.lastConnectedWithPassword)
    }
}
