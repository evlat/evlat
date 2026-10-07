import Darwin
import Foundation
import EvlatCore

/// The unix socket chores the shell does in several places — Evlat's own
/// socket (`HookListener`, `UnixHTTP`), the tunnels' masters
/// (`RemoteTunnels`), herdr's API (`HerdrSocket`), the `sbx` daemon
/// (`SandboxWatcher`) — written once.
enum UnixSocket {
    /// A unix address holds 104 bytes, the last a NUL (`sockaddr_un.sun_path`).
    static let pathLimit = EvlatSocket.pathLimit

    /// `path` as an address, or `nil` when it is empty or does not fit.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A new stream socket that never raises `SIGPIPE` — a write to a peer
    /// that closed would otherwise end the process — optionally
    /// non-blocking. `nil` with `errno` set when it cannot be made.
    static func open(nonBlocking: Bool = false) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              !nonBlocking || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(fd)
            errno = code
            return nil
        }
        return fd
    }

    /// Connects `fd` to `path`: `0`, or the `errno` it failed with —
    /// `ENAMETOOLONG` for a path no address holds. A non-blocking socket
    /// answers `EINPROGRESS` while the connection is under way.
    static func connect(_ fd: Int32, to path: String) -> Int32 {
        guard var address = address(path) else { return ENAMETOOLONG }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    // MARK: - Is someone there

    enum State: Equatable {
        case absent
        /// A file nobody listens on: its owner was killed.
        case stale
        case live
        /// Anything else: left alone.
        case unknown(Int32)
    }

    /// Whether something answers at `path`, by connecting to it. Only
    /// `ENOENT` and `ECONNREFUSED` say the file may go.
    static func probe(_ path: String) -> State {
        guard let fd = open() else { return .unknown(errno) }
        defer { Darwin.close(fd) }
        switch connect(fd, to: path) {
        case 0: return .live
        case ENOENT: return .absent
        case ECONNREFUSED: return .stale
        case let code: return .unknown(code)
        }
    }

    // MARK: - The directory

    /// Why a socket's directory was not made ready.
    enum DirectoryRefusal: Error, Equatable {
        /// A link where the directory should be: it could lead anywhere.
        case link
        /// Another user's: they could swap the socket under us.
        case notOwned
        case notDirectory
        case failed(Int32)

        var text: String {
            switch self {
            case .link: return "the directory is a symbolic link"
            case .notOwned: return "the directory belongs to another user"
            case .notDirectory: return "not a directory"
            case .failed(let code): return String(cString: strerror(code))
            }
        }
    }

    /// Makes `directory` this user's alone: made `0700` when missing (its
    /// parents with the default mode), brought to `0700` when not. A link or
    /// another user's directory is refused, never followed or changed: the
    /// directory is the socket's only guard, since the file takes its mode
    /// from the umask.
    static func prepareDirectory(_ directory: String) -> DirectoryRefusal? {
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT else { return .failed(errno) }
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return .failed(EACCES)
            }
            guard lstat(directory, &info) == 0 else { return .failed(errno) }
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .link }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .notDirectory }
        guard info.st_uid == getuid() else { return .notOwned }
        if info.st_mode & 0o777 != 0o700, chmod(directory, 0o700) != 0 { return .failed(errno) }
        return nil
    }

    // MARK: - Whose file

    /// The file at `path` as one value: which file it is, so a listener can
    /// tell its own from one bound there after it.
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// The file at `path`, not following a link; `nil` when there is none.
    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
}
