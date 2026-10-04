import Darwin
import XCTest
@testable import EvlatApp

/// The transport to a herdr server's API socket, against a stand-in server
/// on a real unix socket: one line in, one line out, one connection each,
/// and nothing at all past the deadline.
final class HerdrSocketTests: XCTestCase {
    private var server: FakeHerdrServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func start(_ behavior: FakeHerdrServer.Behavior) throws -> FakeHerdrServer {
        let server = try FakeHerdrServer(behavior)
        self.server = server
        return server
    }

    func testOneLineGoesOutAndOneComesBack() throws {
        let server = try start(.answer(#"{"id":"evlat","result":{"type":"pong"}}"#))
        let outcome = HerdrSocket.call(HerdrAPI.listPanes, socket: server.path, until: .now() + 2)
        XCTAssertEqual(outcome, .line(#"{"id":"evlat","result":{"type":"pong"}}"#))
        XCTAssertEqual(server.received, [HerdrAPI.listPanes + "\n"], "the line, its newline, nothing else")
    }

    /// One action's deadline: once it has passed, no connection is made.
    /// It starts at the action's first call, not when the session is made.
    func testNothingIsAskedPastTheDeadline() throws {
        let server = try start(.answer("{}"))
        let call = HerdrSocket.session(budget: 0)
        XCTAssertEqual(call(server.path, HerdrAPI.listPanes), .timeout)
        // Made, then left longer than its budget before its first call.
        let later = HerdrSocket.session(budget: 1)
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(later(server.path, HerdrAPI.listPanes), .line("{}"))
        XCTAssertEqual(server.accepted, 1)
        XCTAssertEqual(HerdrSocket.call(HerdrAPI.listPanes, socket: server.path, until: .now()), .timeout)
        XCTAssertEqual(server.accepted, 1, "the two past their deadline made none")
    }

    /// A server that takes the line and says nothing is not waited for past
    /// the deadline. The bound leaves room for a loaded machine.
    func testASilentServerTimesOut() throws {
        let server = try start(.silent)
        let started = Date()
        XCTAssertEqual(HerdrSocket.call(HerdrAPI.listPanes, socket: server.path, until: .now() + 0.1), .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The server closes as soon as it accepts, before reading what is sent:
    /// the write meets a closed peer. Without `SO_NOSIGPIPE` that write would
    /// end this process.
    func testAServerThatClosesAtOnceIsUnreachable() throws {
        let server = try start(.closeAtOnce)
        let large = String(repeating: "x", count: 4 << 20)
        XCTAssertEqual(HerdrSocket.call(large, socket: server.path, until: .now() + 2), .unreachable)
    }

    func testNoServerIsUnreachable() {
        XCTAssertEqual(HerdrSocket.call("{}", socket: "/tmp/evlat-none-\(UUID().uuidString.prefix(8)).sock",
                                        until: .now() + 1), .unreachable)
        XCTAssertEqual(HerdrSocket.call("{}", socket: "/" + String(repeating: "a", count: 120), until: .now() + 1),
                       .unreachable, "longer than a unix address holds")
    }
}

/// A unix socket server at a short path (a unix address holds 104 bytes),
/// on its own thread.
final class FakeHerdrServer {
    enum Behavior {
        /// Read one line, answer this, close.
        case answer(String)
        /// Read one line, hold the connection, answer nothing.
        case silent
        /// Close each connection as soon as it is accepted.
        case closeAtOnce
    }

    let path = "/tmp/evlat-h-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _accepted = 0
    private var _received: [String] = []
    private var held: [Int32] = []
    private let done = DispatchSemaphore(value: 0)

    var accepted: Int { lock.withLock { _accepted } }
    var received: [String] { lock.withLock { _received } }

    init(_ behavior: Behavior) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw NSError(domain: "FakeHerdrServer", code: Int(errno))
        }
        let thread = Thread { [self] in serve(behavior) }
        thread.start()
    }

    private func serve(_ behavior: Behavior) {
        defer { done.signal() }
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 20) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            lock.withLock { _accepted += 1 }
            if case .closeAtOnce = behavior {
                close(connection)
                continue
            }
            var line: [UInt8] = []
            var byte: UInt8 = 0
            while read(connection, &byte, 1) == 1 {
                line.append(byte)
                if byte == UInt8(ascii: "\n") { break }
            }
            lock.withLock { _received.append(String(decoding: line, as: UTF8.self)) }
            switch behavior {
            case .answer(let reply):
                let bytes = Array((reply + "\n").utf8)
                _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                close(connection)
            case .silent:
                lock.withLock { held.append(connection) }
            case .closeAtOnce:
                break
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        done.wait()
        close(listener)
        lock.withLock { held.forEach { close($0) } }
        unlink(path)
    }
}
