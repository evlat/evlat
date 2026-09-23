import XCTest
@testable import EvlatCore

/// The status line relay's contract (`009/phase-5`): the wrapper that lands in
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

    /// The fixed point: what the menu writes into the user's file, byte for
    /// byte. A change here reads every earlier install as `modified`.
    func testTheInstalledStatusLineCommandIsUnchanged() {
        let relay = #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -s -m 2 -X POST"#
            + #" -H "Content-Type: application/json" --data-binary @-"#
            + #" http://127.0.0.1:48151/usage/claude >/dev/null 2>&1 &"#
        XCTAssertEqual(StatusLineRelay.command(wrapping: "bash ~/.claude/statusline.sh"),
                       "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline 'bash ~/.claude/statusline.sh'"#)
        XCTAssertEqual(StatusLineRelay.command(wrapping: nil), "sh -c '" + relay + "'",
                       "no original: it only relays")
        XCTAssertEqual(StatusLineRelay.command(wrapping: "echo 'hi'"),
                       "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline 'echo '\''hi'\'''"#,
                       "a single quote is closed, escaped and reopened")
    }

    func testTheMarkerFollowsThePortAndTheRoute() {
        XCTAssertEqual(StatusLineRelay.marker, "127.0.0.1:\(LocalAPI.defaultPort)\(AgentSource.claude.usagePath!)")
        XCTAssertTrue(StatusLineRelay.command(wrapping: "x").contains(StatusLineRelay.marker))
        XCTAssertFalse(StatusLineRelay.command(wrapping: "x", port: 9).contains(StatusLineRelay.marker))
    }

    func testTheOriginalComesBackOutOfTheWrapper() {
        for original in ["cat", "echo 'a' \"b\" # c", "", "printf '\\n'", "a'''b"] {
            XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: original)),
                           .some(original), original)
        }
        XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: nil)), .some(nil))
        XCTAssertNil(StatusLineRelay.original(in: "bash statusline.sh"), "not ours")
        let wrapped = StatusLineRelay.command(wrapping: "cat")
        XCTAssertNil(StatusLineRelay.original(in: wrapped + " extra"), "edited after")
        XCTAssertNil(StatusLineRelay.original(in: wrapped.replacingOccurrences(of: "-m 2", with: "-m 5")))
        XCTAssertNil(StatusLineRelay.original(in: String(wrapped.dropLast())), "an unclosed quote")
    }

    // MARK: - Running it

    /// What a shell prints and exits with for `command`, fed `input`.
    private struct Run { let stdout: Data; let status: Int32; let seconds: TimeInterval }

    private func run(_ shell: String, _ command: String, input: Data) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
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
    /// listener gets the input byte for byte.
    func testTheWrapperPrintsWhatTheOriginalPrintsAndRelaysTheInput() throws {
        let originals = ["cat", "printf 'a\\n\\n'", "echo 'it'\\''s'", "echo shown # a trailing comment", "exit 3"]
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            for original in originals {
                let listener = try OneShotListener()
                let wrapped = try run(shell, StatusLineRelay.command(wrapping: original, port: listener.port),
                                      input: input)
                let direct = try run(shell, original, input: input)
                XCTAssertEqual(wrapped.stdout, direct.stdout, "\(shell): \(original)")
                XCTAssertEqual(wrapped.status, direct.status, "\(shell): \(original)")
                XCTAssertEqual(listener.body(), input, "\(shell): \(original): the body, byte for byte")
            }
        }
    }

    func testWithoutAnOriginalItOnlyRelays() throws {
        let listener = try OneShotListener()
        let result = try run("/bin/sh", StatusLineRelay.command(wrapping: nil, port: listener.port), input: input)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(listener.body(), input)
    }

    /// Nothing listening, or a listener that never answers: nothing leaks to
    /// stdout and the original's output does not wait for the relay.
    func testAClosedOrSilentEvlatChangesNothing() throws {
        let closed = try OneShotListener()
        let port = closed.port
        closed.close()
        let silent = try OneShotListener(answer: false)
        for port in [port, silent.port] {
            let result = try run("/bin/sh", StatusLineRelay.command(wrapping: "printf ok", port: port), input: input)
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
        XCTAssertEqual(StatusLineRelay.state(of: original), .missing)
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: original))
        XCTAssertEqual(StatusLineRelay.state(of: installed), .current)
        XCTAssertEqual(statusLine(installed)?["command"] as? String,
                       StatusLineRelay.command(wrapping: "bash ~/.claude/s.sh"))
        XCTAssertEqual(statusLine(installed)?["padding"] as? Int, 0, "neighbours stay")
        XCTAssertEqual(statusLine(installed)?["refreshInterval"] as? Int, 5)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.installing(into: installed)))
            .isEqual(to: installed), "a second install changes nothing")
        let removed = try XCTUnwrap(StatusLineRelay.removing(from: installed))
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: original))
    }

    func testWithoutAStatusLineRemoveDeletesTheKey() throws {
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: ["model": "opus"]))
        XCTAssertEqual(statusLine(installed)?["type"] as? String, "command", "added when there was none")
        XCTAssertEqual(statusLine(installed)?["command"] as? String, StatusLineRelay.command(wrapping: nil))
        let removed = try XCTUnwrap(StatusLineRelay.removing(from: installed))
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: ["model": "opus"]))

        let padded = try XCTUnwrap(StatusLineRelay.installing(into: ["statusLine": ["padding": 2]]))
        let back = try XCTUnwrap(StatusLineRelay.removing(from: padded))
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(to: ["statusLine": ["padding": 2]]),
                      "another key keeps the object")
    }

    /// A command without `type` is left without one: the round trip is exact.
    func testATypelessCommandStaysTypeless() throws {
        let original: [String: Any] = ["statusLine": ["command": "cat"]]
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: original))
        XCTAssertNil(statusLine(installed)?["type"])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: installed)))
            .isEqual(to: original))
    }

    func testAHandEditedWrapperIsModifiedAndRefused() throws {
        let wrapped = StatusLineRelay.command(wrapping: "cat")
        let inner = wrapped.replacingOccurrences(of: "cat'", with: "cat | tr a b'")
        XCTAssertEqual(StatusLineRelay.state(of: ["statusLine": ["command": inner]]), .current,
                       "the original edited inside its quotes is still a wrapper, of another command")
        let edited = wrapped.replacingOccurrences(of: "-m 2", with: "-m 9")
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": edited]]
        XCTAssertEqual(StatusLineRelay.state(of: settings), .modified)
        XCTAssertNil(StatusLineRelay.installing(into: settings), "no half install")
        XCTAssertNil(StatusLineRelay.removing(from: settings), "no half removal")
    }

    func testShapesThatAreNotOursAreRefused() {
        for value: Any in ["bash s.sh", ["type": "command", "command": 3], ["type": "static", "command": "cat"]] {
            XCTAssertNil(StatusLineRelay.installing(into: ["statusLine": value]), "\(value)")
        }
        XCTAssertEqual(StatusLineRelay.state(of: ["statusLine": "bash s.sh"]), .missing)
    }

    func testRemovingWhatIsMissingChangesNothing() throws {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "cat"]]
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(StatusLineRelay.removing(from: settings)))
            .isEqual(to: settings))
    }

    // MARK: - Files

    private func settingsFile() throws -> URL {
        try FileManager.default.createDirectory(at: AgentSource.claude.configDirectory(home: home),
                                                withIntermediateDirectories: true)
        return AgentSource.claude.settingsFile(home: home)
    }

    private func json(_ url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: .fragmentsAllowed)
    }

    private func statusBackup(_ url: URL) -> URL { url.appendingPathExtension("statusline.evlat.bak") }

    func testTheFileRoundTripsAndEveryInstallBacksUpTheStatusLine() throws {
        let url = try settingsFile()
        try Data(#"{"statusLine": {"type": "command", "command": "cat"}, "model": "opus"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try StatusLineRelay.state(at: url), .missing)

        XCTAssertEqual(try StatusLineRelay.install(at: url), .written)
        XCTAssertEqual(try StatusLineRelay.state(at: url), .current)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "cat"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: statusBackup(url).path)[.posixPermissions]
                       as? Int, 0o600, "the backup keeps the file's mode")

        XCTAssertEqual(try StatusLineRelay.install(at: url), .unchanged)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "cat"],
                       "an install that writes nothing leaves the backup")

        XCTAssertEqual(try StatusLineRelay.remove(at: url), .written)
        XCTAssertEqual(try StatusLineRelay.state(at: url), .missing)
        let back = try XCTUnwrap(try json(url) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(
            to: ["statusLine": ["type": "command", "command": "cat"], "model": "opus"]))

        // The user changes the command; the next install backs up theirs, not
        // the first one — the general `.evlat.bak` would not.
        try Data(#"{"statusLine": {"type": "command", "command": "tac"}}"#.utf8).write(to: url)
        XCTAssertEqual(try StatusLineRelay.install(at: url), .written)
        XCTAssertEqual(try json(statusBackup(url)) as? [String: String], ["type": "command", "command": "tac"])
    }

    func testWithoutAStatusLineTheBackupIsNull() throws {
        let url = try settingsFile()
        XCTAssertEqual(try StatusLineRelay.install(at: url), .written)
        XCTAssertTrue(try json(statusBackup(url)) is NSNull)
        XCTAssertEqual(try StatusLineRelay.remove(at: url), .written)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(try json(url) as? [String: Any])).isEqual(to: [:]))
    }

    func testAModifiedFileIsRefusedAndLeftAsItWas() throws {
        let url = try settingsFile()
        let edited = StatusLineRelay.command(wrapping: "cat") + " | tr a b"
        let bytes = try JSONSerialization.data(withJSONObject: ["statusLine": ["command": edited]])
        try bytes.write(to: url)
        XCTAssertEqual(try StatusLineRelay.state(at: url), .modified)
        for write in [StatusLineRelay.install(at:), StatusLineRelay.remove(at:)] {
            XCTAssertThrowsError(try write(url)) { XCTAssertEqual($0 as? SettingsFile.Failure, .malformed) }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusBackup(url).path))
    }

    /// A write refused because the file changed underneath leaves the last
    /// statusline backup as it was.
    func testARefusedWriteKeepsTheLastBackup() throws {
        let url = try settingsFile()
        try Data(#"{"statusLine": {"command": "cat"}}"#.utf8).write(to: url)
        try StatusLineRelay.install(at: url)
        try StatusLineRelay.remove(at: url)
        let kept = try Data(contentsOf: statusBackup(url))
        try Data(#"{"statusLine": {"command": "tac"}}"#.utf8).write(to: url)
        XCTAssertThrowsError(try SettingsFile.apply(at: url, beforeWrite: {
            try? Data(#"{"statusLine": {"command": "rev"}}"#.utf8).write(to: url)
        }, backUp: { _, mode in
            try SettingsFile.replace(self.statusBackup(url), with: Data("null".utf8), mode: mode)
        }) { StatusLineRelay.installing(into: $0) ?? $0 }) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .changedUnderneath)
        }
        XCTAssertEqual(try Data(contentsOf: statusBackup(url)), kept)
    }

    /// The backup is replaced in one step: a directory in its place is not
    /// removed, the write is refused.
    func testABackupNeverReplacesADirectory() throws {
        let url = try settingsFile()
        try FileManager.default.createDirectory(at: statusBackup(url), withIntermediateDirectories: false)
        XCTAssertThrowsError(try StatusLineRelay.install(at: url)) {
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
        try StatusLineRelay.install(at: url)
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
        try StatusLineRelay.remove(at: url)
        let after = try XCTUnwrap(try json(url) as? [String: Any])["hooks"] as? [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(after)).isEqual(to: try XCTUnwrap(hooks)))
        XCTAssertEqual(try HookSettings.state(at: url, for: .claude), .current)
    }

    func testNoDirectoryIsNotCreated() {
        let url = AgentSource.claude.settingsFile(home: home)
        XCTAssertThrowsError(try StatusLineRelay.install(at: url)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .noDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSource.claude.configDirectory(home: home).path))
    }
}

/// A loopback listener on a free port that takes one HTTP request, keeps its
/// body and answers `{}` — or, with `answer: false`, holds the connection and
/// says nothing. BSD sockets: the core's tests have no `Network`.
private final class OneShotListener {
    let port: UInt16
    private let socket: Int32
    private let done = DispatchSemaphore(value: 0)
    private var received = Data()
    private var held: Int32 = -1
    private var closed = false
    private let lock = NSLock()

    init(answer: Bool = true) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        self.socket = socket
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && listen(socket, 4) == 0
                    && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { Darwin.close(socket); throw CocoaError(.fileWriteUnknown) }
        port = UInt16(bigEndian: address.sin_port)
        let listening = socket
        DispatchQueue.global().async { [self] in
            let client = accept(listening, nil, nil)
            guard client >= 0 else { done.signal(); return }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Self.complete(request) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                request.append(buffer, count: count)
            }
            lock.lock()
            if let split = request.range(of: Data("\r\n\r\n".utf8)) {
                received = request.subdata(in: split.upperBound..<request.endIndex)
            }
            lock.unlock()
            if answer {
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                Darwin.close(client)
            } else {
                lock.lock(); held = client; lock.unlock()
            }
            done.signal()
        }
    }

    /// Headers read and `Content-Length` bytes of body after them.
    private static func complete(_ request: Data) -> Bool {
        guard let split = request.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: request[request.startIndex..<split.lowerBound], as: UTF8.self).lowercased()
        guard let line = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else { return true }
        return request.endIndex - split.upperBound >= length
    }

    /// The body, once the request is in; `nil` if none came within 5 s.
    func body() -> Data? {
        guard done.wait(timeout: .now() + 5) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// Once: a second `close` of a number the system handed out again would
    /// close someone else's descriptor.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(socket)
        if held >= 0 { Darwin.close(held) }
    }

    deinit { close() }
}
