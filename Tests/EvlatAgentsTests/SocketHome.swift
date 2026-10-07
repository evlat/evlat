import Foundation
@testable import EvlatCore

/// A home short enough for Evlat's socket under it — `$TMPDIR` plus a UUID
/// and `.config/evlat/run/evlat.sock` pass what a unix address holds — with
/// a listener at that socket that takes one HTTP request. The installed
/// commands find it as they would on this Mac or a server: by `$HOME`.
///
/// `/tmp/evlat-<8 hex>`, new for every test (the suite runs in parallel),
/// removed by `remove()`.
final class SocketHome {
    let path: String
    var socket: String { (path as NSString).appendingPathComponent(EvlatSocket.relativePath) }

    init() throws {
        path = "/tmp/evlat-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// The environment a command runs with here: this home, the usual `PATH`.
    var environment: [String: String] {
        ["HOME": path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// A listener at the socket; `answer: false` holds the connection and
    /// says nothing.
    func listen(answer: Bool = true) throws -> OneShotListener {
        try FileManager.default.createDirectory(atPath: (socket as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try OneShotListener(path: socket, answer: answer)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A unix socket listener that takes one HTTP request, keeps its request
/// line, headers and body, and answers `{}` — or, with `answer: false`,
/// holds the connection and says nothing. BSD sockets: the core's tests
/// have no `Network`.
final class OneShotListener {
    private let socket: Int32
    private let path: String
    private let done = DispatchSemaphore(value: 0)
    private var received = Data()
    private var head = ""
    private var held: Int32 = -1
    private var closed = false
    private let lock = NSLock()

    init(path: String, answer: Bool = true) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        self.socket = socket
        self.path = path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socket)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 && listen(socket, 4) == 0
            }
        }
        guard bound else { Darwin.close(socket); throw CocoaError(.fileWriteUnknown) }
        let listening = socket
        DispatchQueue.global().async { [self] in
            let client = accept(listening, nil, nil)
            guard client >= 0 else { done.signal(); return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Self.complete(request) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                request.append(buffer, count: count)
            }
            lock.lock()
            if let split = request.range(of: Data("\r\n\r\n".utf8)) {
                head = String(decoding: request[request.startIndex..<split.lowerBound], as: UTF8.self)
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

    /// The request is in; `false` if none came within 5 s. Asked again,
    /// the first answer stands.
    private var arrived: Bool?
    private func wait() -> Bool {
        if let arrived { return arrived }
        let result = done.wait(timeout: .now() + 5) == .success
        arrived = result
        return result
    }

    /// The body, once the request is in; `nil` if none came within 5 s.
    func body() -> Data? {
        guard wait() else { return nil }
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// The request line and headers, once the request is in.
    func requestHead() -> String? {
        guard wait() else { return nil }
        lock.lock(); defer { lock.unlock() }
        return head
    }

    /// Once: a second `close` of a number the system handed out again would
    /// close someone else's descriptor.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(socket)
        if held >= 0 { Darwin.close(held) }
        unlink(path)
    }

    deinit { close() }
}
