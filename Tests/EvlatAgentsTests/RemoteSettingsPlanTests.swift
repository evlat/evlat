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
        XCTAssertEqual(RemoteSettings.failure(exitCode: 14), .file(.malformed), "a link at a file of Evlat's own")
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
        let installed = try SettingsFile.encode(LocalHooks.installing(into: [:], for: .claude, target: .server))
        XCTAssertNil(try RemoteSettings.plan(.hooks(.claude), .install, original: installed))
        XCTAssertNil(try RemoteSettings.plan(.hooks(.claude), .remove, original: nil))
        XCTAssertNil(try RemoteSettings.plan(.statusLine(.claude), .remove, original: Data("{}".utf8)))
        let write = try XCTUnwrap(try RemoteSettings.plan(.statusLine(.claude), .install, original: nil))
        XCTAssertEqual(write.backup, Data("null".utf8), "no statusLine before: the backup says so")
    }

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
        XCTAssertEqual(LocalHooks.state(of: settings, for: .claude, target: .server), .current)
        XCTAssertEqual(StatusLineRelay.state(of: settings, source: .claude), .current)
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String,
                       StatusLineRelay.command(wrapping: "bash ~/s.sh", source: .claude))
        let stop = ((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
        XCTAssertEqual((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "/usr/local/bin/other",
                       "another tool's group keeps its index")
        XCTAssertNil(try RemoteSettings.plan(.agent(.claude), .install, original: write.contents), "then current")
    }

    /// A server's Claude unit carries the approval group, as this Mac's
    /// does: one file, one write. A server copy from before it, the
    /// command alone, reads outdated and the press completes it.
    func testAServersClaudeUnitCarriesTheApprovalGroup() throws {
        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(.claude), .install, original: nil))
        let settings = try SettingsFile.parse(write.contents)
        XCTAssertEqual(ApprovalHook.state(of: settings, for: Claude().approvals!), .current)
        XCTAssertEqual(LocalHooks.state(of: settings, for: .claude, target: .server), .current)
        let commandAlone = try SettingsFile.encode(HookSettings.installing(into: [:], for: .claude))
        XCTAssertEqual(LocalHooks.state(of: try SettingsFile.parse(commandAlone), for: .claude, target: .server),
                       .outdated)
        let completed = try XCTUnwrap(try RemoteSettings.plan(.hooks(.claude), .install, original: commandAlone))
        XCTAssertEqual(ApprovalHook.state(of: try SettingsFile.parse(completed.contents), for: Claude().approvals!),
                       .current)
        let removed = try XCTUnwrap(try RemoteSettings.plan(.agent(.claude), .remove, original: write.contents))
        XCTAssertFalse(String(decoding: removed.contents, as: UTF8.self).contains("/approval"), "both go")
    }

    /// A server's Codex unit carries Codex's own group, on its path and its
    /// two minutes; a server copy with the command alone, as every copy
    /// before it, reads outdated and one press completes it, other tools'
    /// groups left where they are.
    func testAServersCodexUnitCarriesItsApprovalGroup() throws {
        let channel = try XCTUnwrap(Codex().approvals)
        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(.codex), .install, original: nil))
        let settings = try SettingsFile.parse(write.contents)
        XCTAssertEqual(ApprovalHook.state(of: settings, for: channel), .current)
        XCTAssertEqual(ApprovalHook.state(of: settings, for: Claude().approvals!), .missing, "not Claude's")
        XCTAssertEqual(LocalHooks.state(of: settings, for: .codex, target: .server), .current)
        XCTAssertEqual(LocalHooks.state(of: settings, for: .codex, target: .mac), .current,
                       "this Mac's rule asks for the command alone")
        var hooks = HookSettings.installing(into: [:], for: .codex)["hooks"] as? [String: Any] ?? [:]
        hooks["PermissionRequest"] = [["hooks": [["type": "command", "command": "/usr/local/bin/other"]]]]
            + (hooks["PermissionRequest"] as? [Any] ?? [])
        let commandAlone = try SettingsFile.encode(["hooks": hooks])
        XCTAssertEqual(LocalHooks.state(of: try SettingsFile.parse(commandAlone), for: .codex, target: .server),
                       .outdated)
        let completed = try SettingsFile.parse(
            try XCTUnwrap(try RemoteSettings.plan(.hooks(.codex), .install, original: commandAlone)).contents)
        XCTAssertEqual(LocalHooks.state(of: completed, for: .codex, target: .server), .current)
        let groups = (completed["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 3, "the other tool's, the command's, then ours")
        XCTAssertEqual((groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "/usr/local/bin/other", "another tool's group keeps its index: Codex keys trust by it")
        let removed = try XCTUnwrap(try RemoteSettings.plan(.agent(.codex), .remove, original: write.contents))
        XCTAssertFalse(String(decoding: removed.contents, as: UTF8.self).contains("/approval"), "both go")
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
        let script = RemoteSettings.readScript(path: Claude().integration.file, nonce: "N")
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

    // MARK: - A file of Evlat's own: OpenCode's plugin

    /// A server's OpenCode unit is the plugin, whole, in this Mac's bytes: the
    /// plan reads its state from the bytes (never as JSON) and says what to
    /// do for each of the four states, install and remove alike.
    func testAServersOpenCodeUnitIsThePluginWhole() throws {
        let file = OpenCodePlugin.file
        let current = Data(file.contents.utf8)
        XCTAssertEqual(file.contents, LocalHooks.manual(for: OpenCode()), "this Mac's bytes")
        let older = Data(file.contents.replacingOccurrences(of: "\(file.versionPrefix)\(file.version)\n",
                                                             with: "\(file.versionPrefix)\(file.version - 1)\n").utf8)
        let later = Data(file.contents.replacingOccurrences(of: "\(file.versionPrefix)\(file.version)\n",
                                                             with: "\(file.versionPrefix)\(file.version + 1)\n").utf8)
        let theirs = Data("// mine\n".utf8)
        let whole = RemoteSettings.Write(contents: current, backup: nil, form: .whole)

        XCTAssertEqual(try RemoteSettings.plan(.agent(.opencode), .install, original: nil), whole, "missing: written")
        XCTAssertEqual(try RemoteSettings.plan(.agent(.opencode), .install, original: older), whole, "older: moved")
        XCTAssertNil(try RemoteSettings.plan(.agent(.opencode), .install, original: current), "current: nothing")
        XCTAssertNil(try RemoteSettings.plan(.agent(.opencode), .install, original: later), "a later copy's is current")
        XCTAssertThrowsError(try RemoteSettings.plan(.agent(.opencode), .install, original: theirs)) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed), "unmarked: the user's, refused")
        }
        let removal = RemoteSettings.Write(contents: Data(), backup: nil, form: .removal)
        XCTAssertNil(try RemoteSettings.plan(.agent(.opencode), .remove, original: nil))
        XCTAssertNil(try RemoteSettings.plan(.agent(.opencode), .remove, original: theirs), "the user's stays")
        for original in [current, older, later] {
            XCTAssertEqual(try RemoteSettings.plan(.agent(.opencode), .remove, original: original), removal)
        }
        for change in [RemoteSettings.Change.hooks(.opencode), .statusLine(.opencode)] {
            XCTAssertThrowsError(try RemoteSettings.plan(change, .install, original: nil), "no hooks in a plugin") {
                XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed))
            }
        }
        XCTAssertFalse(RemoteSettings.relays(.opencode))
        XCTAssertTrue(RemoteSettings.serves(.opencode))
        XCTAssertEqual(RemoteSettings.Change.agent(.opencode).path, ".config/opencode/plugins/evlat.js")
        XCTAssertEqual(RemoteSettings.Change.agent(.opencode).opening, OpenCode().presence)
        XCTAssertEqual(Agents.served.map(\.id), Agents.all.map(\.id), "every agent is served")
    }

    /// The scripts: a file of Evlat's own keeps no first backup, and its
    /// removal checks the same `cksum`, never follows a link and takes
    /// nothing but the file; a settings file's write is as it was.
    func testTheScriptsOfAFileOfEvlatsOwn() {
        let path = ".config/opencode/plugins/evlat.js"
        let bytes = Data("// evlat-opencode-plugin\n".utf8)
        let whole = RemoteSettings.writeScript(path: path, expected: "1 2",
                                               write: .init(contents: bytes, backup: nil, form: .whole),
                                               opening: OpenCode().presence)
        XCTAssertFalse(whole.contains(".evlat.bak"), "no backup of Evlat's own file")
        // A link at the path is the user's: every script of such a file ends on it, and a
        // settings file's follows links as it always did.
        let ends = "[ ! -h \"$f\" ] || exit 14"
        XCTAssertTrue(whole.contains(ends))
        XCTAssertTrue(RemoteSettings.readScript(path: path, nonce: "n", opening: OpenCode().presence, owned: true).contains(ends))
        XCTAssertFalse(RemoteSettings.readScript(path: path, nonce: "n", opening: OpenCode().presence).contains(ends))
        XCTAssertTrue(RemoteSettings.readingScript(nonce: "n", agents: [OpenCode()]).contains(ends))
        XCTAssertFalse(RemoteSettings.readingScript(nonce: "n", agents: [Claude(), Codex(), Antigravity()]).contains(ends))
        XCTAssertTrue(whole.contains("mv -f \"$tmp\" \"$t\""), "one rename")
        XCTAssertTrue(whole.contains("mkdir -p"), "the folder is made where the agent is")
        let merged = RemoteSettings.writeScript(path: ".claude/settings.json", expected: "1 2",
                                                write: .init(contents: bytes, backup: nil))
        XCTAssertTrue(merged.contains("[ ! -e \"$f.evlat.bak\" ] && [ ! -h \"$f.evlat.bak\" ]; then cp -p"),
                      "a settings file keeps its first backup")

        let removal = RemoteSettings.writeScript(path: path, expected: "1 2",
                                                 write: .init(contents: Data(), backup: nil, form: .removal),
                                                 opening: OpenCode().presence)
        XCTAssertTrue(removal.contains("[ \"$s\" = \"$e\" ] || exit 12"), "the file read is the file taken out")
        XCTAssertTrue(removal.contains("rm -f \"$t\""))
        XCTAssertTrue(removal.contains(ends), "a removal never reaches through a link")
        XCTAssertFalse(removal.contains("mkdir"), "a removal makes nothing")
        XCTAssertFalse(removal.contains("rmdir"), "and takes no folder")
        XCTAssertFalse(removal.contains("mv "), "and writes nothing")
    }

    /// The pasted block closes each part at a line that is its delimiter
    /// alone, so no line of the plugin may be one.
    func testNoLineOfThePluginIsTheBlocksDelimiter() {
        let lines = OpenCodePlugin.file.contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespaces) == RemoteSettings.combinedDelimiter })
    }
}
