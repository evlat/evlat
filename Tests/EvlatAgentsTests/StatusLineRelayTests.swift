import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The status line relay's contract: the wrapper that lands in
/// the user's `settings.json`, what it does when a shell runs it, and how it is
/// put in and taken out. Every file lives under a temporary home removed in
/// `tearDown`; the user's `~/.claude` is never read or written here.
final class StatusLineRelayTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - The installed command

    /// The relay as it is written now: to the socket under the home.
    static let relay = #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -q -s -m 2 --noproxy "*""#
        + #" --unix-socket "$HOME/.config/evlat/run/evlat.sock" -X POST"#
        + #" -H "Content-Type: application/json" --data-binary @-"#
        + #" http://127.0.0.1:48151/usage/claude >/dev/null 2>&1 &"#

    /// The relay every earlier copy wrote, to the loopback port. Pinned
    /// apart: a wrapper with it is Evlat's older one (`.outdated`).
    static let tcpRelay = #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -s -m 2 -X POST"#
        + #" -H "Content-Type: application/json" --data-binary @-"#
        + #" http://127.0.0.1:48151/usage/claude >/dev/null 2>&1 &"#

    /// A wrapper around `original` with `relay`, as some copy of Evlat wrote it.
    static func wrapper(_ relay: String, _ original: String?) -> String {
        guard let original else { return "sh -c '" + relay + "'" }
        return "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline "#
            + "'" + original.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The fixed point: what the menu writes into the user's file, byte for
    /// byte. A change here reads every earlier install as `modified`.
    func testTheInstalledStatusLineCommandIsUnchanged() {
        let relay = Self.relay
        XCTAssertEqual(StatusLineRelay.command(wrapping: "bash ~/.claude/statusline.sh", source: .claude),
                       "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline 'bash ~/.claude/statusline.sh'"#)
        XCTAssertEqual(StatusLineRelay.command(wrapping: nil, source: .claude), "sh -c '" + relay + "'",
                       "no original: it only relays")
        XCTAssertEqual(StatusLineRelay.command(wrapping: "echo 'hi'", source: .claude),
                       "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline 'echo '\''hi'\'''"#,
                       "a single quote is closed, escaped and reopened")
    }

    func testTheMarkerFollowsThePortAndTheRoute() {
        let marker = StatusLineRelay.marker(for: .claude)
        XCTAssertEqual(marker, "127.0.0.1:\(LocalAPI.defaultPort)\(Claude().statusLineUsage!.path)")
        XCTAssertTrue(StatusLineRelay.command(wrapping: "x", source: .claude).contains(marker))
        XCTAssertTrue(Self.wrapper(Self.tcpRelay, "x").contains(marker), "the older wrapper is Evlat's too")
    }

    func testTheOriginalComesBackOutOfTheWrapper() {
        for original in ["cat", "echo 'a' \"b\" # c", "", "printf '\\n'", "a'''b"] {
            XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: original, source: .claude),
                                                    source: .claude).map(\.original), .some(original), original)
            XCTAssertEqual(StatusLineRelay.original(in: Self.wrapper(Self.tcpRelay, original), source: .claude).map(\.original),
                           .some(original), "the older wrapper's: \(original)")
        }
        XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: nil, source: .claude),
                                                source: .claude).map(\.original), .some(nil))
        XCTAssertEqual(StatusLineRelay.original(in: Self.wrapper(Self.tcpRelay, nil), source: .claude).map(\.original), .some(nil))
        XCTAssertNil(StatusLineRelay.original(in: "bash statusline.sh", source: .claude), "not ours")
        let wrapped = StatusLineRelay.command(wrapping: "cat", source: .claude)
        XCTAssertNil(StatusLineRelay.original(in: wrapped + " extra", source: .claude), "edited after")
        XCTAssertNil(StatusLineRelay.original(in: wrapped.replacingOccurrences(of: "-m 2", with: "-m 5"), source: .claude))
        XCTAssertNil(StatusLineRelay.original(in: String(wrapped.dropLast()), source: .claude), "an unclosed quote")
    }

    // MARK: - The wrapper before the socket

    /// Evlat's own older wrapper is `outdated`, never `modified`: the card
    /// offers the press that moves it, and the press does.
    func testTheWrapperBeforeTheSocketIsOutdated() {
        for original in ["bash ~/.claude/s.sh", "echo 'hi'", nil] as [String?] {
            let settings: [String: Any] = ["statusLine": ["type": "command",
                                                          "command": Self.wrapper(Self.tcpRelay, original)]]
            XCTAssertEqual(StatusLineRelay.state(of: settings, source: .claude), .outdated, original ?? "relay alone")
        }
        let edited = Self.wrapper(Self.tcpRelay, "cat").replacingOccurrences(of: "-m 2", with: "-m 9")
        XCTAssertEqual(StatusLineRelay.state(of: ["statusLine": ["command": edited]], source: .claude), .modified,
                       "an older wrapper edited by hand is the user's")
    }

    /// The install takes the original out of the older wrapper and wraps it
    /// again, neighbours kept; the removal takes the older one apart too.
    func testAnInstallRewrapsTheOlderWrapperAndARemovalUnwrapsIt() throws {
        let original: [String: Any] = ["model": "opus",
                                       "statusLine": ["type": "command", "command": "bash ~/s.sh", "padding": 0]]
        let old: [String: Any] = ["model": "opus",
                                  "statusLine": ["type": "command", "command": Self.wrapper(Self.tcpRelay, "bash ~/s.sh"),
                                                 "padding": 0]]
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: old, source: .claude))
        XCTAssertEqual(StatusLineRelay.state(of: installed, source: .claude), .current)
        XCTAssertEqual(statusLine(installed)?["command"] as? String,
                       StatusLineRelay.command(wrapping: "bash ~/s.sh", source: .claude))
        XCTAssertEqual(statusLine(installed)?["padding"] as? Int, 0)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: old, source: .claude)))
            .isEqual(to: original), "the older wrapper comes apart to the original")

        let alone: [String: Any] = ["statusLine": ["type": "command", "command": Self.wrapper(Self.tcpRelay, nil)]]
        let movedAlone = try XCTUnwrap(StatusLineRelay.installing(into: alone, source: .claude))
        XCTAssertEqual(statusLine(movedAlone)?["command"] as? String,
                       StatusLineRelay.command(wrapping: nil, source: .claude))
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: alone, source: .claude)))
            .isEqual(to: [:]))
    }

    /// Moving the older wrapper leaves its backup alone: what it kept is the
    /// user's command from before any wrapper, not the wrapper itself.
    func testMovingTheOlderWrapperKeepsItsBackup() throws {
        let url = try settingsFile()
        try Data(#"{"statusLine": {"type": "command", "command": "cat"}}"#.utf8).write(to: url)
        try StatusLineRelay.install(at: url, source: .claude)
        let kept = try Data(contentsOf: statusBackup(url))
        let old = try JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": Self.wrapper(Self.tcpRelay, "cat")]])
        try old.write(to: url)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .outdated)
        XCTAssertEqual(try StatusLineRelay.install(at: url, source: .claude), .written)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .current)
        XCTAssertEqual(try Data(contentsOf: statusBackup(url)), kept)
        XCTAssertEqual(try StatusLineRelay.remove(at: url, source: .claude), .written)
        XCTAssertEqual(try json(url) as? [String: [String: String]], ["statusLine": ["type": "command", "command": "cat"]])
    }

    // MARK: - Running it

    /// What a shell prints and exits with for `command`, fed `input`, with
    /// `home` as its `$HOME`.
    private struct Run { let stdout: Data; let status: Int32; let seconds: TimeInterval }

    private func run(_ shell: String, _ command: String, input: Data, home: SocketHome) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = home.environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(stdout: output, status: process.terminationStatus, seconds: Date().timeIntervalSince(start))
    }

    private let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}},"note":"it's\n"}"#.utf8 + [10, 10])

    /// Inside a status line runner the wrapper's output and exit code are the
    /// original's, under every shell Claude Code might hand it to, and the
    /// socket under the home gets the input byte for byte.
    func testTheWrapperPrintsWhatTheOriginalPrintsAndRelaysTheInput() throws {
        let originals = ["cat", "printf 'a\\n\\n'", "echo 'it'\\''s'", "echo shown # a trailing comment", "exit 3"]
        let home = try SocketHome()
        defer { home.remove() }
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            for original in originals {
                let listener = try home.listen()
                let wrapped = try run(shell, StatusLineRelay.command(wrapping: original, source: .claude),
                                      input: input, home: home)
                let direct = try run(shell, original, input: input, home: home)
                XCTAssertEqual(wrapped.stdout, direct.stdout, "\(shell): \(original)")
                XCTAssertEqual(wrapped.status, direct.status, "\(shell): \(original)")
                XCTAssertEqual(listener.body(), input, "\(shell): \(original): the body, byte for byte")
                XCTAssertTrue(listener.requestHead()?.hasPrefix("POST /usage/claude HTTP/1.1") == true)
                listener.close()
            }
        }
    }

    func testWithoutAnOriginalItOnlyRelays() throws {
        let home = try SocketHome()
        defer { home.remove() }
        let listener = try home.listen()
        let result = try run("/bin/sh", StatusLineRelay.command(wrapping: nil, source: .claude), input: input, home: home)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(listener.body(), input)
    }

    /// No socket, or a listener that never answers: nothing leaks to
    /// stdout and the original's output does not wait for the relay.
    func testAClosedOrSilentEvlatChangesNothing() throws {
        let home = try SocketHome()
        defer { home.remove() }
        let command = StatusLineRelay.command(wrapping: "printf ok", source: .claude)
        let missing = try run("/bin/sh", command, input: input, home: home)
        let silent = try home.listen(answer: false)
        let held = try run("/bin/sh", command, input: input, home: home)
        for result in [missing, held] {
            XCTAssertEqual(result.stdout, Data("ok".utf8))
            XCTAssertEqual(result.status, 0)
            XCTAssertLessThan(result.seconds, 1, "the relay runs in the background")
        }
        silent.close()
    }

    // MARK: - Transformations

    private func statusLine(_ settings: [String: Any]) -> [String: Any]? {
        settings["statusLine"] as? [String: Any]
    }

    func testInstallThenRemoveGivesTheOriginalBack() throws {
        let original: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "bash ~/.claude/s.sh", "padding": 0, "refreshInterval": 5],
        ]
        XCTAssertEqual(StatusLineRelay.state(of: original, source: .claude), .missing)
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: original, source: .claude))
        XCTAssertEqual(StatusLineRelay.state(of: installed, source: .claude), .current)
        XCTAssertEqual(statusLine(installed)?["command"] as? String,
                       StatusLineRelay.command(wrapping: "bash ~/.claude/s.sh", source: .claude))
        XCTAssertEqual(statusLine(installed)?["padding"] as? Int, 0, "neighbours stay")
        XCTAssertEqual(statusLine(installed)?["refreshInterval"] as? Int, 5)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.installing(into: installed, source: .claude)))
            .isEqual(to: installed), "a second install changes nothing")
        let removed = try XCTUnwrap(StatusLineRelay.removing(from: installed, source: .claude))
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: original))
    }

    func testWithoutAStatusLineRemoveDeletesTheKey() throws {
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: ["model": "opus"], source: .claude))
        XCTAssertEqual(statusLine(installed)?["type"] as? String, "command", "added when there was none")
        XCTAssertEqual(statusLine(installed)?["command"] as? String, StatusLineRelay.command(wrapping: nil, source: .claude))
        let removed = try XCTUnwrap(StatusLineRelay.removing(from: installed, source: .claude))
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: ["model": "opus"]))

        let padded = try XCTUnwrap(StatusLineRelay.installing(into: ["statusLine": ["padding": 2]], source: .claude))
        let back = try XCTUnwrap(StatusLineRelay.removing(from: padded, source: .claude))
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(to: ["statusLine": ["padding": 2]]),
                      "another key keeps the object")
    }

    /// A command without `type` is left without one: the round trip is exact.
    func testATypelessCommandStaysTypeless() throws {
        let original: [String: Any] = ["statusLine": ["command": "cat"]]
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: original, source: .claude))
        XCTAssertNil(statusLine(installed)?["type"])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: installed, source: .claude)))
            .isEqual(to: original))
    }

    func testAHandEditedWrapperIsModifiedAndRefused() throws {
        let wrapped = StatusLineRelay.command(wrapping: "cat", source: .claude)
        let inner = wrapped.replacingOccurrences(of: "cat'", with: "cat | tr a b'")
        XCTAssertEqual(StatusLineRelay.state(of: ["statusLine": ["command": inner]], source: .claude), .current,
                       "the original edited inside its quotes is still a wrapper, of another command")
        let edited = wrapped.replacingOccurrences(of: "-m 2", with: "-m 9")
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": edited]]
        XCTAssertEqual(StatusLineRelay.state(of: settings, source: .claude), .modified)
        XCTAssertNil(StatusLineRelay.installing(into: settings, source: .claude), "no half install")
        XCTAssertNil(StatusLineRelay.removing(from: settings, source: .claude), "no half removal")
    }

    func testShapesThatAreNotOursAreRefused() {
        for value: Any in ["bash s.sh", ["type": "command", "command": 3], ["type": "static", "command": "cat"]] {
            XCTAssertNil(StatusLineRelay.installing(into: ["statusLine": value], source: .claude), "\(value)")
        }
        XCTAssertEqual(StatusLineRelay.state(of: ["statusLine": "bash s.sh"], source: .claude), .missing)
    }

    func testRemovingWhatIsMissingChangesNothing() throws {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "cat"]]
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: settings, source: .claude)))
            .isEqual(to: settings))
    }

    // MARK: - Files

    private func settingsFile() throws -> URL {
        try FileManager.default.createDirectory(at: Claude().hooksFile(home: home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return Claude().hooksFile(home: home)
    }

    private func json(_ url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: .fragmentsAllowed)
    }

    private func statusBackup(_ url: URL) -> URL { url.appendingPathExtension("statusline.evlat.bak") }

    func testTheFileRoundTripsAndEveryInstallBacksUpTheStatusLine() throws {
        let url = try settingsFile()
        try Data(#"{"statusLine": {"type": "command", "command": "cat"}, "model": "opus"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .missing)

        XCTAssertEqual(try StatusLineRelay.install(at: url, source: .claude), .written)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .current)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "cat"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: statusBackup(url).path)[.posixPermissions]
                       as? Int, 0o600, "the backup keeps the file's mode")

        XCTAssertEqual(try StatusLineRelay.install(at: url, source: .claude), .unchanged)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "cat"],
                       "an install that writes nothing leaves the backup")

        XCTAssertEqual(try StatusLineRelay.remove(at: url, source: .claude), .written)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .missing)
        let back = try XCTUnwrap(try json(url) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(
            to: ["statusLine": ["type": "command", "command": "cat"], "model": "opus"]))

        // The user changes the command; the next install backs up theirs, not
        // the first one — the general `.evlat.bak` would not.
        try Data(#"{"statusLine": {"type": "command", "command": "tac"}}"#.utf8).write(to: url)
        XCTAssertEqual(try StatusLineRelay.install(at: url, source: .claude), .written)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "tac"])
    }

    func testWithoutAStatusLineTheBackupIsNull() throws {
        let url = try settingsFile()
        XCTAssertEqual(try StatusLineRelay.install(at: url, source: .claude), .written)
        XCTAssertTrue(try json(statusBackup(url)) is NSNull)
        XCTAssertEqual(try StatusLineRelay.remove(at: url, source: .claude), .written)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(try json(url) as? [String: Any])).isEqual(to: [:]))
    }

    func testAModifiedFileIsRefusedAndLeftAsItWas() throws {
        let url = try settingsFile()
        let edited = StatusLineRelay.command(wrapping: "cat", source: .claude) + " | tr a b"
        let bytes = try JSONSerialization.data(withJSONObject: ["statusLine": ["command": edited]])
        try bytes.write(to: url)
        XCTAssertEqual(try StatusLineRelay.state(at: url, source: .claude), .modified)
        let writes: [(URL, Claude) throws -> SettingsFile.Outcome] = [StatusLineRelay.install(at:source:),
                                                                       StatusLineRelay.remove(at:source:)]
        for write in writes {
            XCTAssertThrowsError(try write(url, .claude)) { XCTAssertEqual($0 as? SettingsFile.Failure, .malformed) }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusBackup(url).path))
    }

    /// A write refused because the file changed underneath leaves the last
    /// statusline backup as it was.
    func testARefusedWriteKeepsTheLastBackup() throws {
        let url = try settingsFile()
        try Data(#"{"statusLine": {"command": "cat"}}"#.utf8).write(to: url)
        try StatusLineRelay.install(at: url, source: .claude)
        try StatusLineRelay.remove(at: url, source: .claude)
        let kept = try Data(contentsOf: statusBackup(url))
        try Data(#"{"statusLine": {"command": "tac"}}"#.utf8).write(to: url)
        XCTAssertThrowsError(try SettingsFile.apply(at: url, beforeWrite: {
            try? Data(#"{"statusLine": {"command": "rev"}}"#.utf8).write(to: url)
        }, backUp: { _, mode in
            try SettingsFile.replace(self.statusBackup(url), with: Data("null".utf8), mode: mode)
        }) { StatusLineRelay.installing(into: $0, source: .claude) ?? $0 }) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .changedUnderneath)
        }
        XCTAssertEqual(try Data(contentsOf: statusBackup(url)), kept)
    }

    /// The backup is replaced in one step: a directory in its place is not
    /// removed, the write is refused.
    func testABackupNeverReplacesADirectory() throws {
        let url = try settingsFile()
        try FileManager.default.createDirectory(at: statusBackup(url), withIntermediateDirectories: false)
        XCTAssertThrowsError(try StatusLineRelay.install(at: url, source: .claude)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .unwritable)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: statusBackup(url).path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing installed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".tmp") }, [], "no temporary file left")
    }

    func testTheHookGroupsAreNotTouched() throws {
        let url = try settingsFile()
        try HookSettings.install(at: url, for: .claude)
        let hooks = try XCTUnwrap(try json(url) as? [String: Any])["hooks"] as? [String: Any]
        try StatusLineRelay.install(at: url, source: .claude)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
        try StatusLineRelay.remove(at: url, source: .claude)
        let after = try XCTUnwrap(try json(url) as? [String: Any])["hooks"] as? [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(after)).isEqual(to: try XCTUnwrap(hooks)))
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
    }

    func testNoDirectoryIsNotCreated() {
        let url = Claude().hooksFile(home: home)
        XCTAssertThrowsError(try StatusLineRelay.install(at: url, source: .claude)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .noDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Claude().hooksFile(home: home).deletingLastPathComponent().path))
    }
}
