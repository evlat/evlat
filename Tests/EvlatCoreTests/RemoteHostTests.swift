import XCTest
@testable import EvlatCore

/// `RemoteHost`: the read-only script a server runs to say which ssh
/// connection a session is under, and what the Mac reads of its answer. The
/// script runs here under `sh`, `dash` and `bash` against a `/proc` and a
/// home made in a temporary folder, shaped as the measured server's
/// (Ubuntu, OpenSSH 9.6p1: `claude → bash → sshd: root@pts/0 → listener`).
final class RemoteHostTests: XCTestCase {
    private static let shells = ["/bin/sh", "/bin/dash", "/bin/bash"]
    private static let session = "8087b2ed-d738-42da-abf1-8693d1094eda"
    private static let records = SessionRecords(directory: ".agent/sessions", idKey: "sessionId", pidKey: "pid")

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-host-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - The session id

    func testOnlyAUUIDIsASessionID() {
        XCTAssertTrue(RemoteHost.isSessionID(Self.session))
        XCTAssertTrue(RemoteHost.isSessionID(Self.session.uppercased()))
        for bad in ["", "abc", Self.session + "x", "'; rm -rf ~; '", "8087b2ed d738 42da abf1 8693d1094eda",
                    "{8087b2ed-d738-42da-abf1-8693d1094eda}"] {
            XCTAssertFalse(RemoteHost.isSessionID(bad), bad)
            XCTAssertNil(RemoteHost.script(sessionID: bad, records: Self.records, nonce: "n"), bad)
        }
    }

    func testTheSessionIDComesFromItsMachinesEntity() {
        XCTAssertEqual(RemoteHost.sessionID(entity: "remote:m1:\(Self.session)", machineID: "m1"), Self.session)
        XCTAssertNil(RemoteHost.sessionID(entity: "remote:m2:\(Self.session)", machineID: "m1"))
        XCTAssertNil(RemoteHost.sessionID(entity: Self.session, machineID: "m1"), "a local row")
        XCTAssertNil(RemoteHost.sessionID(entity: "remote:m1:not-a-uuid", machineID: "m1"))
    }

    /// The id goes in as it came — the records spell it in lower case,
    /// which `UUID.uuidString` would not — and as one quoted word.
    func testTheIDIsQuotedAsItCame() throws {
        let script = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n"))
        XCTAssertTrue(script.contains("id='\(Self.session)'\n"))
    }

    // MARK: - The call

    /// Over the master or not at all: a gone master must not turn into a
    /// login, so the fallback connection is made to fail before `--`.
    func testTheCallRidesOnlyTheMaster() {
        let arguments = RemoteHost.arguments(target: "devbox", controlPath: "/tmp/e/1")
        let base = RemoteSettings.arguments(target: "devbox", controlPath: "/tmp/e/1")
        let proxy = try! XCTUnwrap(arguments.firstIndex(of: "ProxyCommand=/usr/bin/false"))
        XCTAssertEqual(arguments[proxy - 1], "-o")
        XCTAssertLessThan(proxy, try! XCTUnwrap(arguments.firstIndex(of: "--")))
        XCTAssertEqual(arguments.filter { $0 != "-o" && $0 != "ProxyCommand=/usr/bin/false" },
                       base.filter { $0 != "-o" })
        XCTAssertEqual(arguments.suffix(3), ["--", "devbox", "sh -s"])
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
    }

    // MARK: - The answer

    func testTheAnswerIsReadBehindALoginsChatter() throws {
        let output = Data("Welcome to Ubuntu\nn1 ssh 19554 22 1761253365 2946736728 1790972720.90\n".utf8)
        let reply = RemoteHost.reply(exitCode: 0, output: output, nonce: "n1",
                                     arrivedAt: Date(timeIntervalSince1970: 1790972720.60))
        guard case .connection(let connection) = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(connection.clientPort, 19554)
        XCTAssertEqual(connection.serverPort, 22)
        XCTAssertEqual(connection.startedAt.timeIntervalSince1970, 1761253365 + 29467367.28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(connection.offset), 0.30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(connection.localStart).timeIntervalSince1970,
                       1761253365 + 29467367.28 - 0.30, accuracy: 0.001)
    }

    func testAnythingElseIsNotKnown() {
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RemoteHost.reply(exitCode: 0, output: Data("n none\n".utf8), nonce: "n", arrivedAt: at),
                       .noConnection)
        for text in ["", "n\n", "x ssh 1 22 1 1 1\n", "n ssh 0 22 1 1 1\n", "n ssh 70000 22 1 1 1\n",
                     "n ssh 1 22 0 1 1\n", "n ssh a 22 1 1 1\n", "n ssh 1 22 1 -1 1\n", "n ssh 1 22 1 1\n",
                     "n nonesuch\n", "n none extra\n", "pre n ssh 1 22 1 1 1\n"] {
            XCTAssertNil(RemoteHost.reply(exitCode: 0, output: Data(text.utf8), nonce: "n", arrivedAt: at), text)
        }
        XCTAssertNil(RemoteHost.reply(exitCode: 255, output: Data("n none\n".utf8), nonce: "n", arrivedAt: at),
                     "a failed call says nothing, whatever it printed")
    }

    /// `date` without `%N` prints a letter: the start is still read, the
    /// offset is not.
    func testAClockWithoutNanosecondsGivesNoOffset() {
        let reply = RemoteHost.reply(exitCode: 0, output: Data("n ssh 1 22 100 50 1790972720.N\n".utf8), nonce: "n",
                                     arrivedAt: Date())
        guard case .connection(let connection) = reply else { return XCTFail() }
        XCTAssertNil(connection.offset)
        XCTAssertNil(connection.localStart)
        XCTAssertEqual(connection.startedAt.timeIntervalSince1970, 100.5, accuracy: 0.001)
    }

    // MARK: - The script, in three shells

    /// The measured chain: the agent under a shell under the connection's
    /// `sshd`, under the listener (parent 1).
    func testTheConnectionsPortsAndStartAreSaid() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 12345),
                         (700, "bash", 600, 12350), (800, "claude", 700, 12400)],
                 agent: 800, environment: ["TERM=xterm", "SSH_CONNECTION=31.223.75.17 19554 116.202.9.44 22"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 19554 22 1000 12345 2000.25", shell)
        }
    }

    /// From OpenSSH 9.8 the connection's process is `sshd-session`; a user
    /// other than root has a `[priv]` one under the listener first. Either
    /// way it is the one whose parent is the listener.
    func testTheListenersChildIsTheConnection() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd-session", 500, 222),
                         (650, "sshd-session", 600, 230), (700, "bash", 650, 240), (800, "claude", 700, 250)],
                 agent: 800, environment: ["SSH_CONNECTION=10.0.0.1 50000 10.0.0.2 2222"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n ssh 50000 2222 1000 222 2000.25", shell)
        }
    }

    /// A name with spaces and a parenthesis is read up to the last `)`.
    func testAProcessNameIsReadWhole() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 7),
                         (800, "my (odd) agent", 600, 9)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        XCTAssertEqual(try run("/bin/sh"), "n ssh 1 22 1000 7 2000.25")
    }

    func testNoSshdAboveIsSaidOutright() throws {
        try tree(chain: [(1, "systemd", 0, 1), (300, "login", 1, 5), (700, "bash", 300, 6), (800, "claude", 700, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        for shell in Self.shells {
            XCTAssertEqual(try run(shell), "n none", shell)
        }
    }

    /// `sshd -i` started by systemd for each connection: its parent is no
    /// listener, so no connection is claimed.
    func testAnSshdWithoutAListenerIsNoConnection() throws {
        try tree(chain: [(1, "systemd", 0, 1), (600, "sshd", 1, 5), (800, "claude", 600, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        XCTAssertEqual(try run("/bin/sh"), "n none")
    }

    /// In tmux or herdr the environment is the server's first client's:
    /// nothing is said this phase.
    func testAMultiplexersPaneSaysNothing() throws {
        for variable in ["TMUX=/tmp/tmux-0/default,1,0", "HERDR_ENV=1"] {
            try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5),
                             (800, "claude", 600, 7)],
                     agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22", variable])
            for shell in Self.shells {
                XCTAssertEqual(try run(shell), "", "\(shell) \(variable)")
            }
        }
    }

    func testNotLinuxNoRecordOrNoProcessSaysNothing() throws {
        let chain: [(Int, String, Int, Int)] = [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5),
                                                (800, "claude", 600, 7)]
        let environment = ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"]

        try tree(chain: chain, agent: 800, environment: environment, linux: false)
        XCTAssertEqual(try run("/bin/sh"), "", "no /proc/self")

        try tree(chain: chain, agent: 800, environment: environment, recordedID: UUID().uuidString.lowercased())
        XCTAssertEqual(try run("/bin/sh"), "", "another session's record")

        try tree(chain: chain, agent: 800, environment: environment, recordedPid: 999)
        XCTAssertEqual(try run("/bin/sh"), "", "a record whose process is gone")
    }

    /// Nothing is written: the tree and the home are byte for byte the same
    /// after a run.
    func testTheScriptWritesNothing() throws {
        try tree(chain: [(1, "systemd", 0, 1), (500, "sshd", 1, 300), (600, "sshd", 500, 5), (800, "claude", 600, 7)],
                 agent: 800, environment: ["SSH_CONNECTION=1.1.1.1 1 2.2.2.2 22"])
        let before = try listing()
        for shell in Self.shells { _ = try run(shell) }
        XCTAssertEqual(try listing(), before)
    }

    // MARK: - Helpers

    private var proc: URL { root.appendingPathComponent("proc") }
    private var home: URL { root.appendingPathComponent("home") }
    private var bin: URL { root.appendingPathComponent("bin") }

    /// A `/proc` with `chain` (pid, name, parent, start ticks), `btime 1000`,
    /// the agent's environment, and its record under the home. `date` is a
    /// fake on `PATH` that prints `2000.25`: this Mac's has no `%N`.
    private func tree(chain: [(pid: Int, name: String, parent: Int, start: Int)], agent: Int,
                      environment: [String], linux: Bool = true,
                      recordedID: String = RemoteHostTests.session, recordedPid: Int? = nil) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: proc, withIntermediateDirectories: true)
        if linux { try fm.createDirectory(at: proc.appendingPathComponent("self"), withIntermediateDirectories: true) }
        try "cpu  1 2 3\nbtime 1000\nprocesses 9\n".write(to: proc.appendingPathComponent("stat"),
                                                          atomically: true, encoding: .utf8)
        for entry in chain {
            let folder = proc.appendingPathComponent(String(entry.pid))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Fields 3…: state, ppid, then up to 22 (starttime) and a few more.
            let middle = Array(repeating: "0", count: 17).joined(separator: " ")
            let stat = "\(entry.pid) (\(entry.name)) S \(entry.parent) \(middle) \(entry.start) 4096 300 0\n"
            try stat.write(to: folder.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
            if entry.pid == agent {
                let bytes = environment.map { $0 + "\0" }.joined()
                try bytes.write(to: folder.appendingPathComponent("environ"), atomically: true, encoding: .utf8)
            }
        }
        let records = home.appendingPathComponent(Self.records.directory)
        try fm.createDirectory(at: records, withIntermediateDirectories: true)
        let pid = recordedPid ?? agent
        try #"{"pid":\#(pid),"sessionId":"\#(recordedID)","cwd":"/root","pidDomain":"linux"}"#
            .write(to: records.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"pid":1,"sessionId":"00000000-0000-0000-0000-000000000000"}"#
            .write(to: records.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let date = bin.appendingPathComponent("date")
        try "#!/bin/sh\necho 2000.25\n".write(to: date, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: date.path)
    }

    private func run(_ shell: String) throws -> String {
        let script = try XCTUnwrap(RemoteHost.script(sessionID: Self.session, records: Self.records, nonce: "n",
                                                     proc: proc.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-s"]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, shell)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func listing() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { files[url.path] = data } else { files[url.path] = Data() }
        }
        return files
    }
}
