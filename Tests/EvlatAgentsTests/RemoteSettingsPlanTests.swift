import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// `RemoteSettings`' pure half: exit codes, the read's output, the plan. The
/// scripts themselves run against a fake `ssh` in `EvlatAppTests.RemoteSettingsTests`.
final class RemoteSettingsPlanTests: XCTestCase {
    func testExitCodesMapToTheLocalFailuresAndAnythingElseIsUnreachable() {
        XCTAssertNil(RemoteSettings.failure(exitCode: 0))
        XCTAssertEqual(RemoteSettings.failure(exitCode: 10), .file(.noDirectory))
        XCTAssertEqual(RemoteSettings.failure(exitCode: 11), .file(.unreadable))
        XCTAssertEqual(RemoteSettings.failure(exitCode: 12), .file(.changedUnderneath))
        XCTAssertEqual(RemoteSettings.failure(exitCode: 13), .file(.unwritable))
        for code: Int32 in [1, 2, 126, 127, 255] {
            XCTAssertEqual(RemoteSettings.failure(exitCode: code), .unreachable, "\(code)")
        }
    }

    func testTheReadFindsItsLineBehindABanner() throws {
        let output = Data("motd\nN2 no\nN 123 45\n{\"a\":1}\n".utf8)
        let snapshot = try RemoteSettings.snapshot(exitCode: 0, output: output, nonce: "N")
        XCTAssertEqual(snapshot, RemoteSettings.Snapshot(bytes: Data("{\"a\":1}\n".utf8), checksum: "123 45"))
        let none = try RemoteSettings.snapshot(exitCode: 0, output: Data("N absent\n".utf8), nonce: "N")
        XCTAssertEqual(none, RemoteSettings.Snapshot(bytes: nil, checksum: "absent"))
        XCTAssertThrowsError(try RemoteSettings.snapshot(exitCode: 0, output: Data("motd\n".utf8), nonce: "N")) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.unreadable))
        }
        XCTAssertThrowsError(try RemoteSettings.snapshot(exitCode: 255, output: Data(), nonce: "N")) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .unreachable)
        }
    }

    func testThePlanWritesNothingWhenNothingChanges() throws {
        let installed = try SettingsFile.encode(HookSettings.installing(into: [:], for: .claude))
        XCTAssertNil(try RemoteSettings.plan(.hooks(.claude), .install, original: installed))
        XCTAssertNil(try RemoteSettings.plan(.hooks(.claude), .remove, original: nil))
        XCTAssertNil(try RemoteSettings.plan(.statusLine(.claude), .remove, original: Data("{}".utf8)))
        let write = try XCTUnwrap(try RemoteSettings.plan(.statusLine(.claude), .install, original: nil))
        XCTAssertEqual(write.backup, Data("null".utf8), "no statusLine before: the backup says so")
    }

    /// A server's hooks are this Mac's transformation without the approval
    /// hook: its route is `404` through a tunnel.
    /// A server's file from before the socket: its hooks and its usage line
    /// read as Evlat's older ones, and the unit's one press moves both in
    /// place — other tools' groups at their index, no new backup for the
    /// line, which keeps the user's command from before any wrapper.
    func testAServersOlderUnitReadsOutdatedAndOnePressMovesIt() throws {
        let tcp = try XCTUnwrap(LocalAPITests.tcpCommand["claude"])
        var hooks: [String: Any] = [:]
        for event in Claude().hooks.events {
            hooks[event] = [["hooks": [["type": "command", "command": "/usr/local/bin/other"]]],
                            ["hooks": [["type": "command", "command": tcp, "timeout": 5]]]]
        }
        let line = StatusLineRelayTests.wrapper(StatusLineRelayTests.tcpRelay, "bash ~/s.sh")
        let old = try SettingsFile.encode(["hooks": hooks, "statusLine": ["type": "command", "command": line]])
        let reading = RemoteSettings.Reading(files: [.claude: .success(RemoteSettings.Snapshot(bytes: old, checksum: "1 2"))],
                                             command: .missing)
        XCTAssertEqual(reading.hooks(.claude), .state(.outdated))
        XCTAssertEqual(reading.statusLine(.claude), .state(.outdated))
        guard case .state(let unit) = reading.unit(.claude) else { return XCTFail("no unit") }
        XCTAssertEqual(unit.status, .outdated)
        XCTAssertTrue(unit.installsRelay)

        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(.claude), .install, original: old))
        XCTAssertNil(write.backup, "moving the older line takes no backup")
        let settings = try SettingsFile.parse(write.contents)
        XCTAssertEqual(LocalHooks.state(of: settings, for: .claude, approvals: false), .current)
        XCTAssertEqual(StatusLineRelay.state(of: settings, source: .claude), .current)
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String,
                       StatusLineRelay.command(wrapping: "bash ~/s.sh", source: .claude))
        let stop = ((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
        XCTAssertEqual((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "/usr/local/bin/other",
                       "another tool's group keeps its index")
        XCTAssertNil(try RemoteSettings.plan(.agent(.claude), .install, original: write.contents), "then current")
    }

    func testAServersHooksNeverCarryTheApprovalHook() throws {
        let write = try XCTUnwrap(try RemoteSettings.plan(.hooks(.claude), .install, original: nil))
        XCTAssertFalse(String(decoding: write.contents, as: UTF8.self).contains("/approval"))
        XCTAssertEqual(write.contents, try SettingsFile.encode(HookSettings.installing(into: [:], for: .claude)))
        let local = try SettingsFile.encode(LocalHooks.installing(into: [:], for: .claude, approvals: true))
        XCTAssertTrue(String(decoding: local, as: UTF8.self).contains("/approval"), "this Mac's do")
        // A file with the command alone is current on a server.
        XCTAssertNil(try RemoteSettings.plan(.hooks(.claude), .install, original: write.contents))
    }

    /// An install that cannot reach current without overwriting someone
    /// else's value is refused, as the local writer refuses it.
    func testAnInstallThatCannotBeCompletedIsMalformed() {
        let foreign = Data(#"{"hooks":"not an object"}"#.utf8)
        XCTAssertThrowsError(try RemoteSettings.plan(.hooks(.claude), .install, original: foreign)) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed))
        }
    }

    /// A server's `statusLine` the relay will not wrap counts as the local
    /// card counts it: not a part. The hooks are written once, the unit then
    /// reads current, and a second press writes nothing instead of failing.
    func testAServersStatusLineNotOursDoesNotHoldTheUnit() throws {
        let original = Data(#"{"statusLine":"bash s.sh"}"#.utf8)
        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(.claude), .install, original: original))
        let settings = try SettingsFile.parse(write.contents)
        XCTAssertEqual(settings["statusLine"] as? String, "bash s.sh")
        XCTAssertNil(write.backup, "nothing wrapped")
        XCTAssertNil(try RemoteSettings.plan(.agent(.claude), .install, original: write.contents))
        let reading = RemoteSettings.Reading(
            files: [.claude: .success(RemoteSettings.Snapshot(bytes: write.contents, checksum: "1 1"))],
            command: .missing)
        XCTAssertEqual(reading.unit(.claude), .state(AgentIntegration.State(hooks: .current, relay: .modified)))
        XCTAssertEqual(AgentIntegration.State(hooks: .current, relay: .modified).status, .current)
    }

    /// The script carries a quoted path; the only `$` is the server's `HOME`.
    func testThePathIsTheServersHome() {
        let script = RemoteSettings.readScript(path: Claude().integration.hooksFile, nonce: "N")
        XCTAssertTrue(script.contains(#"f="$HOME"/'.claude/settings.json'"#))
        XCTAssertFalse(script.contains(NSHomeDirectory()), "this Mac's home never enters")
        XCTAssertEqual(RemoteSettings.arguments(target: "devbox").suffix(3), ["--", "devbox", "sh -s"])
    }

    /// Through the tunnel's master the call does not log in again; without
    /// one it is today's list, byte for byte.
    func testWithASocketTheCallRidesTheTunnelsMaster() {
        XCTAssertEqual(RemoteSettings.arguments(target: "devbox", controlPath: "/tmp/e/21580954"), [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-S", "/tmp/e/21580954",
            "-o", "ControlMaster=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
            "--", "devbox", "sh -s",
        ])
        XCTAssertEqual(RemoteSettings.arguments(target: "devbox", controlPath: nil), [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
            "--", "devbox", "sh -s",
        ])
    }
}
