import Darwin
import Foundation
import EvlatCore

/// One HTTP/1.1 request to a unix socket, answered or given up: Evlat's own
/// clients — the askpass helper, `Evlat signal` and `watch`, `--list`'s
/// probes — on Evlat's socket (`EvlatSocket`). `URLSession` speaks no unix
/// socket. Blocking: every caller is a command waiting for its one answer.
enum UnixHTTP {
    enum Answer: Equatable {
        /// The status and the body as they came.
        case status(Int, Data)
        /// Nobody listens there: no such file, or a file nobody accepts on.
        case notRunning
        /// The deadline passed before the answer was whole.
        case timeout
        case failed(String)
    }

    /// The longest answer read; Evlat's are a few hundred bytes.
    static let maxAnswer = 1 << 20

    /// `method route` with `headers` and `body` to the socket at `path`.
    /// `timeout` bounds the whole exchange; `nil` waits as long as the far
    /// side does — a person's answer to a prompt — and ends with its close.
    static func send(_ route: String, method: String = "POST", socket path: String,
                     headers: [(String, String)] = [], body: Data = Data(),
                     timeout: TimeInterval?) -> Answer {
        let deadline = timeout.map { DispatchTime.now() + $0 }
        guard let fd = UnixSocket.open(nonBlocking: true) else { return .failed(String(cString: strerror(errno))) }
        defer { close(fd) }

        switch UnixSocket.connect(fd, to: path) {
        case 0: break
        case EINPROGRESS, EAGAIN:
            if let failed = wait(fd, for: POLLOUT, until: deadline) { return failed }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return .failed("getsockopt") }
            if error == ENOENT || error == ECONNREFUSED { return .notRunning }
            if error != 0 { return .failed(String(cString: strerror(error))) }
        case ENOENT, ECONNREFUSED:
            return .notRunning
        case let code:
            return .failed(String(cString: strerror(code)))
        }

        // The host only fills `Host:`, which must read as loopback
        // (`LocalAPI.isLoopback`).
        var head = "\(method) \(route) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let request = Array(Data(head.utf8) + body)
        var sent = 0
        while sent < request.count {
            let written = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                sent += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                if let failed = wait(fd, for: POLLOUT, until: deadline) { return failed }
            } else {
                return .failed(String(cString: strerror(errno)))
            }
        }

        var answer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while answer.count <= maxAnswer {
            if let whole = parse(answer) { return whole }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                answer.append(contentsOf: chunk[..<count])
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                if let failed = wait(fd, for: POLLIN, until: deadline) { return failed }
            } else if count == 0 {
                // Closed: whatever came is the answer, if it reads as one.
                return parse(answer, closed: true) ?? .failed("closed before an answer")
            } else {
                return .failed(String(cString: strerror(errno)))
            }
        }
        return .failed("an answer past \(maxAnswer) bytes")
    }

    /// The answer in `data` once it is whole: its head read, and its body
    /// as long as `Content-Length` says — or, with none, up to the close.
    static func parse(_ data: Data, closed: Bool = false) -> Answer? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let words = lines[0].split(separator: " ")
        guard words.count >= 2, words[0].hasPrefix("HTTP/"), let code = Int(words[1]) else {
            return .failed("not an HTTP answer")
        }
        let length = lines.dropFirst().lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        let body = data[end.upperBound...]
        if let length {
            guard body.count >= length else { return closed ? .failed("closed before the body") : nil }
            return .status(code, Data(body.prefix(length)))
        }
        return closed ? .status(code, Data(body)) : nil
    }

    /// `poll` for one event until the deadline (`nil`: none). `nil` when it
    /// came — a hang-up too: the read or write that follows says what it
    /// was — else the answer that ends the exchange.
    private static func wait(_ fd: Int32, for event: Int32, until deadline: DispatchTime?) -> Answer? {
        while true {
            var milliseconds: Int32 = -1
            if let deadline {
                let now = DispatchTime.now()
                guard now < deadline else { return .timeout }
                let left = deadline.uptimeNanoseconds - now.uptimeNanoseconds
                milliseconds = Int32(clamping: (left + 999_999) / 1_000_000)
            }
            var entry = pollfd(fd: fd, events: Int16(event), revents: 0)
            let result = poll(&entry, 1, milliseconds)
            if result > 0 { return nil }
            if result == 0 { return .timeout }
            if errno != EINTR { return .failed(String(cString: strerror(errno))) }
        }
    }
}
