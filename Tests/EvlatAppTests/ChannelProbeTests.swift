import XCTest
@testable import EvlatCore
@testable import EvlatApp

/// The channel's probe (`RemoteTunnel.channelProbe`) as a server runs it:
/// under `/bin/sh`, `/bin/dash` and `/bin/bash`, with `HOME` at a temporary
/// "server" home short enough for its socket, and the real `curl`. It makes
/// the folder the user's alone, leaves a socket that answers, and takes one
/// that refuses or stays silent.
final class ChannelProbeTests: XCTestCase {
    private var home: String!
    private var held: [Int32] = []
    private var listener: HookListener?

    private let shells = ["/bin/sh", "/bin/dash", "/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    private var folder: String { home + "/.config/evlat/run" }
    private var socket: String { home + "/" + EvlatSocket.relativePath }

    override func setUpWithError() throws {
        home = "/private/tmp/evlat-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        listener?.stop()
        held.forEach { Darwin.close($0) }
        try? FileManager.default.removeItem(atPath: home)
    }

    /// The probe's line, and how long it took.
    private func probe(_ shell: String, path: String? = nil) throws -> (channel: RemoteTunnel.Channel?, seconds: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-s"]
        var environment = ["HOME": home!, "PATH": "/usr/bin:/bin"]
        if let path { environment["PATH"] = path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(Data((RemoteTunnel.channelProbe(nonce: "N") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (RemoteTunnel.channel(output: printed, nonce: "N"), Date().timeIntervalSince(start))
    }

    /// A socket bound at the server's path; listening or not, nobody accepts.
    private func bind(listening: Bool) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socket
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        if listening { XCTAssertEqual(Darwin.listen(fd, 4), 0) }
        held.append(fd)
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    func testAFreeSocketIsSaidAndTheFolderIsTheUsersAlone() throws {
        for shell in shells {
            let result = try probe(shell)
            XCTAssertEqual(result.channel, RemoteTunnel.Channel(socket: .free, curl: .ok, path: socket), shell)
            XCTAssertEqual(try mode(folder), 0o700, shell)
            // A folder already there, loose, is brought to 0700.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        }
    }

    /// Another Evlat's socket answers `/health`: left exactly as it is.
    func testASocketThatAnswersIsBusyAndLeftAlone() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let other = HookListener(transport: .unix(socket), origin: .machine) { _ in }
        other.start()
        listener = other
        guard case .listeningAt = other.awaitSettled(timeout: 5) else {
            throw XCTSkip("the other Evlat's socket did not come up: \(other.status.text)")
        }
        let inode = try XCTUnwrap(UnixSocket.identity(of: socket))
        for shell in shells {
            XCTAssertEqual(try probe(shell).channel?.socket, .busy, shell)
            XCTAssertEqual(UnixSocket.identity(of: socket), inode, "\(shell): untouched")
        }
    }

    /// A file nobody listens on — a connection's that ended — is taken.
    func testASocketThatRefusesIsCleared() throws {
        for shell in shells {
            try bind(listening: false)
            let result = try probe(shell)
            XCTAssertEqual(result.channel?.socket, .cleared, shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket), shell)
            XCTAssertLessThan(result.seconds, 3, "\(shell): a refusal is at once")
        }
    }

    /// A socket that takes the connection and never answers is a dead one's
    /// once the probe's patience is out.
    func testASocketSilentForFiveSecondsIsCleared() throws {
        try bind(listening: true)
        let result = try probe("/bin/sh")
        XCTAssertEqual(result.channel?.socket, .cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertGreaterThanOrEqual(result.seconds, Double(RemoteTunnel.probePatience) - 0.5)
    }

    /// Without a `curl` that can ask, a file there is left, and the
    /// forward decides; the `curl` is said either way.
    func testWithoutACurlThatCanAskAFileIsLeft() throws {
        let old = home + "/old-curl"
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'curl: option --unix-socket: is unknown' >&2\nexit 2\n"
            .write(toFile: old + "/curl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old + "/curl")
        try bind(listening: false)
        for shell in shells {
            let none = try probe(shell, path: "/bin")
            XCTAssertEqual(none.channel, RemoteTunnel.Channel(socket: .unknown, curl: .none, path: socket), shell)
            let older = try probe(shell, path: old + ":/bin")
            XCTAssertEqual(older.channel, RemoteTunnel.Channel(socket: .unknown, curl: .old, path: socket), shell)
            XCTAssertTrue(FileManager.default.fileExists(atPath: socket), shell)
        }
    }

    /// The reading's call carries the probe first and reads it back.
    func testTheReadingCallCarriesTheProbe() throws {
        let script = RemoteSettings.readingScript(nonce: "N", agents: [], probing: true)
        XCTAssertTrue(script.hasPrefix(RemoteTunnel.channelProbe(nonce: "N")))
        XCTAssertFalse(RemoteSettings.readingScript(nonce: "N", agents: []).contains(" channel "),
                       "only the tunnel's call probes")
    }
}
