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

    /// The fixed point: what the menu writes into the user's file, byte for
    /// byte. A change here reads every earlier install as `modified`.
    func testTheInstalledStatusLineCommandIsUnchanged() {
        let relay = #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -s -m 2 -X POST"#
            + #" -H "Content-Type: application/json" --data-binary @-"#
            + #" http://127.0.0.1:48151/usage/claude >/dev/null 2>&1 &"#
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
        XCTAssertFalse(StatusLineRelay.command(wrapping: "x", port: 9, source: .claude).contains(marker))
    }

    func testTheOriginalComesBackOutOfTheWrapper() {
        for original in ["cat", "echo 'a' \"b\" # c", "", "printf '\\n'", "a'''b"] {
            XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: original, source: .claude), source: .claude),
                           .some(original), original)
        }
        XCTAssertEqual(StatusLineRelay.original(in: StatusLineRelay.command(wrapping: nil, source: .claude), source: .claude), .some(nil))
        XCTAssertNil(StatusLineRelay.original(in: "bash statusline.sh", source: .claude), "not ours")
        let wrapped = StatusLineRelay.command(wrapping: "cat", source: .claude)
        XCTAssertNil(StatusLineRelay.original(in: wrapped + " extra", source: .claude), "edited after")
        XCTAssertNil(StatusLineRelay.original(in: wrapped.replacingOccurrences(of: "-m 2", with: "-m 5"), source: .claude))
        XCTAssertNil(StatusLineRelay.original(in: String(wrapped.dropLast()), source: .claude), "an unclosed quote")
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
                let wrapped = try run(shell, StatusLineRelay.command(wrapping: original, port: listener.port, source: .claude),
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
        let result = try run("/bin/sh", StatusLineRelay.command(wrapping: nil, port: listener.port, source: .claude), input: input)
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
            let result = try run("/bin/sh", StatusLineRelay.command(wrapping: "printf ok", port: port, source: .claude), input: input)
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
