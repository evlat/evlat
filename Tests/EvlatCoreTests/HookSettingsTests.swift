import XCTest
@testable import EvlatCore

/// The hook settings writer's contract. Every test builds its own home under
/// the temporary directory and removes it in `tearDown`: nothing here may reach
/// the user's real `~/.claude` or `~/.codex` (`008` → R3).
final class HookSettingsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Helpers

    private func settingsFile(_ source: AgentSource) throws -> URL {
        try FileManager.default.createDirectory(
            at: source.configDirectory(home: home), withIntermediateDirectories: true)
        return source.settingsFile(home: home)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func backup(_ url: URL) -> URL { url.appendingPathExtension("evlat.bak") }

    private func evlatGroup(_ command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": 5]]]
    }

    /// A made-up tool's group, shaped like the ones found in real files: it
    /// carries a `matcher`. The command is invented, not copied.
    private func foreignGroup(_ name: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": "/usr/local/bin/\(name) notify"]]]
    }

    private func groups(_ settings: [String: Any], _ event: String) -> [Any] {
        (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
    }

    // MARK: - Events and paths

    /// Byte for byte v1's lists (`HookTarget.claude` / `.codex`).
    /// `SubagentStart`/`SubagentStop` are deliberately absent.
    func testTheEventListsAreV1s() {
        XCTAssertEqual(AgentSource.claude.hookEvents, [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "PermissionDenied",
            "Notification", "Stop", "StopFailure",
        ])
        XCTAssertEqual(AgentSource.codex.hookEvents, [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Stop", "Interrupt",
        ])
    }

    func testThePathsDeriveFromTheHome() {
        XCTAssertEqual(AgentSource.claude.settingsFile(home: home).path, home.path + "/.claude/settings.json")
        XCTAssertEqual(AgentSource.codex.settingsFile(home: home).path, home.path + "/.codex/hooks.json")
        XCTAssertEqual(AgentSource.claude.configDirectory(home: home).path, home.path + "/.claude")
        XCTAssertEqual(AgentSource.codex.configDirectory(home: home).path, home.path + "/.codex")
    }

    // MARK: - State

    func testTheWrittenCommandIsTheGoldenOneOnEveryEvent() throws {
        for source in AgentSource.allCases {
            let settings = HookSettings.installing(into: [:], for: source)
            for event in source.hookEvents {
                let group = try XCTUnwrap(groups(settings, event).first as? [String: Any])
                let hooks = try XCTUnwrap(group["hooks"] as? [[String: Any]])
                XCTAssertEqual(hooks.count, 1)
                XCTAssertEqual(hooks[0]["command"] as? String, LocalAPI.installedHookCommand(for: source))
                XCTAssertEqual(hooks[0]["type"] as? String, "command")
                XCTAssertEqual(hooks[0]["timeout"] as? Int, 5)
            }
            XCTAssertEqual(HookSettings.state(of: settings, for: source), .current)
        }
    }

    /// What v1 installed is what v2 writes: a file holding today's golden
    /// command on every event reads `current`.
    func testAGoldenInstallReadsCurrent() {
        for source in AgentSource.allCases {
            let command = LocalAPI.installedHookCommand(for: source)
            var hooks: [String: Any] = [:]
            for event in source.hookEvents { hooks[event] = [foreignGroup("other"), evlatGroup(command)] }
            XCTAssertEqual(HookSettings.state(of: ["hooks": hooks], for: source), .current)
        }
    }

    func testAMissingEventOrAnOldCommandReadsOutdated() {
        let source = AgentSource.claude
        let command = LocalAPI.installedHookCommand(for: source)
        var hooks: [String: Any] = [:]
        for event in source.hookEvents { hooks[event] = [evlatGroup(command)] }

        var missingOne = hooks
        missingOne.removeValue(forKey: "Stop")
        XCTAssertEqual(HookSettings.state(of: ["hooks": missingOne], for: source), .outdated)

        var oldOne = hooks
        oldOne["Stop"] = [evlatGroup("curl -s -m 2 -X POST --data-binary @- http://127.0.0.1:48151/hook")]
        XCTAssertEqual(HookSettings.state(of: ["hooks": oldOne], for: source), .outdated)
    }

    func testNothingInstalledReadsMissing() {
        XCTAssertEqual(HookSettings.state(of: [:], for: .claude), .missing)
        XCTAssertEqual(HookSettings.state(of: ["hooks": ["Stop": [foreignGroup("other")]]], for: .codex),
                       .missing)
    }

    // MARK: - Transformations

    /// Shaped like the real file: foreign groups with a `matcher`, Evlat at
    /// index 0 on some events and 1 on others. Installing keeps every foreign
    /// group at its index with its content — Codex's trust is keyed by index.
    func testInstallingKeepsForeignGroupsAtTheirIndex() throws {
        let source = AgentSource.claude
        let old = "curl -s -m 2 -X POST --data-binary @- http://127.0.0.1:48151/hook"
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [evlatGroup(old), foreignGroup("a")],
                "PreToolUse": [foreignGroup("b"), evlatGroup(old), foreignGroup("c"), evlatGroup(old)],
                "Elicitation": [foreignGroup("d")],
            ] as [String: Any],
        ]
        let result = HookSettings.installing(into: settings, for: source)
        let command = LocalAPI.installedHookCommand(for: source)

        let stop = groups(result, "Stop")
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(NSDictionary(dictionary: stop[0] as! [String: Any]).isEqual(to: evlatGroup(command)))
        XCTAssertTrue(NSDictionary(dictionary: stop[1] as! [String: Any]).isEqual(to: foreignGroup("a")))

        // The first Evlat group changes in place; the extra one is dropped.
        let pre = groups(result, "PreToolUse")
        XCTAssertEqual(pre.count, 3)
        XCTAssertTrue(NSDictionary(dictionary: pre[0] as! [String: Any]).isEqual(to: foreignGroup("b")))
        XCTAssertTrue(NSDictionary(dictionary: pre[1] as! [String: Any]).isEqual(to: evlatGroup(command)))
        XCTAssertTrue(NSDictionary(dictionary: pre[2] as! [String: Any]).isEqual(to: foreignGroup("c")))

        // An event Evlat does not install, and the rest of the file, are untouched.
        XCTAssertTrue(NSDictionary(dictionary: groups(result, "Elicitation")[0] as! [String: Any])
            .isEqual(to: foreignGroup("d")))
        XCTAssertEqual(result["model"] as? String, "opus")
        // A missing event gets the group appended.
        XCTAssertEqual(groups(result, "SessionStart").count, 1)
        XCTAssertEqual(HookSettings.state(of: result, for: source), .current)
    }

    /// Removing an Evlat group that has a foreign group behind it moves that
    /// group down one index. Expected: removal cannot keep an index it deletes.
    func testRemovingDropsOnlyEvlatGroupsAndShiftsTheOnesBehind() throws {
        let source = AgentSource.codex
        let command = LocalAPI.installedHookCommand(for: source)
        let settings: [String: Any] = ["hooks": [
            "Stop": [evlatGroup(command), foreignGroup("a")],
            "PreToolUse": [evlatGroup(command)],
            "Elicitation": [foreignGroup("d")],
        ] as [String: Any]]
        let result = HookSettings.removing(from: settings, for: source)

        let stop = groups(result, "Stop")
        XCTAssertEqual(stop.count, 1)
        XCTAssertTrue(NSDictionary(dictionary: stop[0] as! [String: Any]).isEqual(to: foreignGroup("a")))
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"], "an emptied event key goes away")
        XCTAssertNotNil(hooks["Elicitation"])
        XCTAssertEqual(HookSettings.state(of: result, for: source), .missing)
    }

    func testNonObjectGroupsAndNonArrayEventValuesAreKept() throws {
        let source = AgentSource.claude
        let settings: [String: Any] = ["hooks": [
            "Stop": ["a stray string", 42, foreignGroup("a")] as [Any],
            "Notification": "not an array",
        ] as [String: Any]]

        let installed = HookSettings.installing(into: settings, for: source)
        let stop = groups(installed, "Stop")
        XCTAssertEqual(stop.count, 4)
        XCTAssertEqual(stop[0] as? String, "a stray string")
        XCTAssertEqual(stop[1] as? Int, 42)
        XCTAssertEqual((installed["hooks"] as? [String: Any])?["Notification"] as? String, "not an array")
        // The event it could not write stays missing, so the state says so.
        XCTAssertEqual(HookSettings.state(of: installed, for: source), .outdated)

        let removed = HookSettings.removing(from: installed, for: source)
        let kept = groups(removed, "Stop")
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept[0] as? String, "a stray string")
        XCTAssertEqual((removed["hooks"] as? [String: Any])?["Notification"] as? String, "not an array")
    }

    // MARK: - Files

    func testInstallingAndRemovingRoundTripOnDisk() throws {
        let url = try settingsFile(.claude)
        try write(#"{"model":"opus"}"#, to: url)

        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
        XCTAssertEqual(try json(url)["model"] as? String, "opus")

        XCTAssertEqual(try HookSettings.remove(at: url, for: .claude), .written)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .missing)
    }

    func testAMissingFileInAnExistingDirectoryIsInstalled() throws {
        let url = try settingsFile(.codex)
        XCTAssertEqual(try HookSettings.state(at: url, for: .codex), .missing)
        XCTAssertEqual(try HookSettings.install(at: url, for: .codex), .written)
        XCTAssertEqual(try HookSettings.state(at: url, for: .codex), .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup(url).path),
                       "there were no bytes to back up")
    }

    /// Nothing to do means no write: neither the file nor its backup moves.
    func testAnUnchangedTransformDoesNotTouchTheFileOrTheBackup() throws {
        let url = try settingsFile(.claude)
        try write("{}", to: url)
        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)
        let bytes = try Data(contentsOf: url)
        let backupBytes = try Data(contentsOf: backup(url))
        let stamp = try modified(url)
        let backupStamp = try modified(backup(url))

        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .unchanged)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try modified(url), stamp)
        XCTAssertEqual(try Data(contentsOf: backup(url)), backupBytes)
        XCTAssertEqual(try modified(backup(url)), backupStamp)

        let bare = try settingsFile(.codex)
        try write(#"{"model":"o3"}"#, to: bare)
        let bareStamp = try modified(bare)
        XCTAssertEqual(try HookSettings.remove(at: bare, for: .codex), .unchanged)
        XCTAssertEqual(try Data(contentsOf: bare), Data(#"{"model":"o3"}"#.utf8))
        XCTAssertEqual(try modified(bare), bareStamp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup(bare).path))
    }

    func testMalformedJSONAndANonObjectRootAreRefused() throws {
        let url = try settingsFile(.claude)
        for text in ["{ not json", "[1, 2]"] {
            try write(text, to: url)
            XCTAssertThrowsError(try HookSettings.install(at: url, for: .claude)) {
                XCTAssertEqual($0 as? HookSettings.Failure, .malformed)
            }
            XCTAssertThrowsError(try HookSettings.state(at: url, for: .claude))
            XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup(url).path))
        }
    }

    func testAnEmptyFileCountsAsAnEmptyObject() throws {
        let url = try settingsFile(.claude)
        try write("  \n", to: url)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .missing)
        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
    }

    /// No directory is created: a Codex entry must not conjure `~/.codex`.
    func testAMissingDirectoryIsRefusedAndNotCreated() throws {
        let url = AgentSource.codex.settingsFile(home: home)
        XCTAssertThrowsError(try HookSettings.install(at: url, for: .codex)) {
            XCTAssertEqual($0 as? HookSettings.Failure, .noDirectory)
        }
        XCTAssertThrowsError(try HookSettings.state(at: url, for: .codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// Dotfile managers keep the settings file as a link. The write goes to
    /// the target and the link stays a link; the backup is a plain file with
    /// the target's old bytes, and a second write does not overwrite it.
    func testASymlinkIsWrittenThroughAndBackedUpAsBytes() throws {
        let url = try settingsFile(.claude)
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("settings.json")
        let original = #"{"model":"opus"}"#
        try write(original, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)

        let linkType = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        XCTAssertEqual(linkType, .typeSymbolicLink)
        XCTAssertEqual(try HookSettings.state(at: target, for: .claude), .current)
        let backupType = try FileManager.default.attributesOfItem(atPath: backup(url).path)[.type]
            as? FileAttributeType
        XCTAssertEqual(backupType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: backup(url)), Data(original.utf8))

        XCTAssertEqual(try HookSettings.remove(at: url, for: .claude), .written)
        XCTAssertEqual(try Data(contentsOf: backup(url)), Data(original.utf8), "the first backup is kept")
    }

    /// A link whose target is gone is refused: writing would replace the
    /// link with a plain file.
    func testADanglingSymlinkIsRefusedAndStaysALink() throws {
        let url = try settingsFile(.claude)
        let gone = home.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: gone)
        XCTAssertThrowsError(try HookSettings.install(at: url, for: .claude)) {
            XCTAssertEqual($0 as? HookSettings.Failure, .unreadable)
        }
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
    }

    /// `settings.json` can hold secrets under `env`; the backup must not be
    /// more readable than the file it copies.
    func testTheBackupKeepsTheFilesMode() throws {
        let url = try settingsFile(.claude)
        try write(#"{"env":{"KEY":"secret"}}"#, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)
        let mode = try FileManager.default.attributesOfItem(atPath: backup(url).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testANonObjectHooksValueIsLeftAlone() throws {
        let url = try settingsFile(.claude)
        try write(#"{"hooks":["someone else's"]}"#, to: url)
        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .unchanged)
        XCTAssertEqual(try Data(contentsOf: url), Data(#"{"hooks":["someone else's"]}"#.utf8))
    }

    /// Two installs stacked on one event fire every hook twice.
    func testADuplicateEvlatGroupReadsOutdated() {
        let source = AgentSource.claude
        let command = LocalAPI.installedHookCommand(for: source)
        var hooks: [String: Any] = [:]
        for event in source.hookEvents { hooks[event] = [evlatGroup(command)] }
        hooks["Stop"] = [evlatGroup(command), evlatGroup(command)]
        XCTAssertEqual(HookSettings.state(of: ["hooks": hooks], for: source), .outdated)
        let folded = HookSettings.installing(into: ["hooks": hooks], for: source)
        XCTAssertEqual(groups(folded, "Stop").count, 1)
        XCTAssertEqual(HookSettings.state(of: folded, for: source), .current)
    }

    /// The file changes between the read and the write (the user saved it,
    /// or the agent did): the write is refused and their version stays.
    func testAFileChangedBeforeTheWriteIsNotOverwritten() throws {
        let url = try settingsFile(.claude)
        try write("{}", to: url)
        let theirs = #"{"model":"sonnet"}"#
        XCTAssertThrowsError(try HookSettings.apply(at: url, beforeWrite: {
            try? Data(theirs.utf8).write(to: url)
        }) { HookSettings.installing(into: $0, for: .claude) }) {
            XCTAssertEqual($0 as? HookSettings.Failure, .changedUnderneath)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data(theirs.utf8))
    }

    /// Other tools' commands used to be rewritten with `\/` on every install.
    func testSlashesAreNotEscaped() throws {
        let url = try settingsFile(.claude)
        try write(#"{"statusLine":{"command":"/usr/local/bin/line"}}"#, to: url)
        XCTAssertEqual(try HookSettings.install(at: url, for: .claude), .written)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(#"\/"#))
        XCTAssertTrue(text.contains("/usr/local/bin/line"))
        XCTAssertTrue(text.contains("http://127.0.0.1:48151/hook"))
    }
}
