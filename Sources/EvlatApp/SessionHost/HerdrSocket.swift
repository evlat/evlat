import Darwin
import Foundation

/// The transport to a herdr server's API socket (`herdr.sock`): connect,
/// write one JSON line, read one line back, close. herdr answers one request
/// per connection — a second line on the same one met `Broken pipe` (0.9.3) —
/// so every request is its own connection. Calls took 0.5–2.5 ms on this Mac.
///
/// It runs on the main queue, as the tmux query does: the card's lookup and
/// the click are synchronous. **One user action's calls share one deadline**
/// (`session`), so however many panes there are, the bar waits at most
/// `budget` for herdr, and once the deadline has passed nothing more is sent.
/// The deadline is on the monotonic clock: a clock set back while a server
/// holds a reply must not hold the main queue with it.
enum HerdrSocket {
    /// What became of one request.
    enum Outcome: Equatable {
        /// The reply's line, without its newline.
        case line(String)
        /// The deadline passed before the reply came, or before the call.
        case timeout
        /// Nobody answered at that path: no such socket, a path too long for
        /// a unix address, a connection refused or closed before a line.
        case unreachable
    }

    /// One request line to a socket path. The pure lookups (`Herdr.pane`,
    /// `HerdrPane.focus`) see herdr only through this, so a test answers for
    /// the server.
    typealias Call = (_ socket: String, _ request: String) -> Outcome

    /// The bar's whole wait for herdr in one action: the card coming up, or
    /// a click's lookup and selection together.
    static let budget: TimeInterval = 0.25

    /// The longest reply read. A list of panes was ~1.5 KB for six.
    static let maxReply = 1 << 20

    /// Calls that share one deadline, which starts at the first call: the
    /// walk before it (processes, sockets, a tmux query) is not herdr's
    /// wait. The main queue is the only caller.
    static func session(budget: TimeInterval = budget) -> Call {
        var deadline: DispatchTime?
        return { socket, request in
            let end = deadline ?? .now() + budget
            deadline = end
            return call(request, socket: socket, until: end)
        }
    }

    static func call(_ request: String, socket path: String, until deadline: DispatchTime) -> Outcome {
        guard DispatchTime.now() < deadline else { return .timeout }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unreachable }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        // The server closes after its one reply, and one that closes before
        // reading makes the write meet a closed peer: without this, SIGPIPE
        // would end Evlat.
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return .unreachable }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return .unreachable }
            switch wait(fd, for: POLLOUT, until: deadline) {
            case .ready: break
            case .timeout: return .timeout
            case .failed: return .unreachable
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return .unreachable }
        }

        let line = Array((request + "\n").utf8)
        var sent = 0
        while sent < line.count {
            let written = line[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                sent += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                switch wait(fd, for: POLLOUT, until: deadline) {
                case .ready: continue
                case .timeout: return .timeout
                case .failed: return .unreachable
                }
            } else {
                return .unreachable
            }
        }

        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while reply.count <= maxReply {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                // Only the new bytes can hold the newline.
                let newline = chunk[..<count].firstIndex(of: UInt8(ascii: "\n"))
                reply += chunk[..<(newline ?? count)]
                if newline != nil { return .line(String(decoding: reply, as: UTF8.self)) }
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                switch wait(fd, for: POLLIN, until: deadline) {
                case .ready: continue
                case .timeout: return .timeout
                case .failed: return .unreachable
                }
            } else {
                // Closed before a whole line: no reply.
                return .unreachable
            }
        }
        return .unreachable
    }

    private enum Wait { case ready, timeout, failed }

    /// `poll` for one event until the deadline. A hang-up counts as ready:
    /// the read or write that follows says what it was.
    private static func wait(_ fd: Int32, for event: Int32, until deadline: DispatchTime) -> Wait {
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { return .timeout }
            let left = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let milliseconds = Int32(clamping: (left + 999_999) / 1_000_000)
            var entry = pollfd(fd: fd, events: Int16(event), revents: 0)
            let result = poll(&entry, 1, milliseconds)
            if result > 0 {
                return entry.revents & Int16(event | POLLHUP | POLLERR) != 0 ? .ready : .failed
            }
            if result == 0 { return .timeout }
            if errno != EINTR { return .failed }
        }
    }
}
