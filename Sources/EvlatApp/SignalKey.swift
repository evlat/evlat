import Foundation
import EvlatCore

/// The key `/signal` asks for, on disk.
///
/// **The process that holds the port writes it**, once per launch, after the
/// listener is bound (`HookListener`): a process that could not bind never
/// touches the file, so a second Evlat cannot overwrite the running one's key
/// with a key nobody answers to. A program that wants to post reads the file
/// (`Evlat signal`, `Evlat watch`, `--list`); whoever can read it is the user,
/// which is the whole of the claim the key makes — a web page cannot.
///
/// The file is `<home>/Library/Application Support/Evlat/signal-<port>.token`:
/// per port, so an isolated process on another port never shares a key with
/// the app on 48151.
enum SignalKey {
    /// Where the key for `port` lives, or `nil` when there is none to write or
    /// read. `EVLAT_HOME` moves it; an isolated process — `EVLAT_PORT` set
    /// without `EVLAT_HOME` — has none (`ChatStore.root`'s rule): a measured
    /// process neither writes the user's file nor reads it.
    ///
    /// `home` is the resolved one (`AppController.resolvedHome`); the
    /// environment is read raw, since the resolved home has already folded
    /// `EVLAT_HOME` away.
    static func location(port: UInt16, home: URL?,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let set = { (name: String) in !(environment[name]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        if set("EVLAT_PORT") && !set("EVLAT_HOME") { return nil }
        return home?.appendingPathComponent("Library/Application Support/Evlat", isDirectory: true)
            .appendingPathComponent("signal-\(port).token")
    }

    /// The same location, the home resolved from the environment: what a
    /// separate process (`--list`, the command) asks.
    static func location(port: UInt16,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        location(port: port, home: AppController.resolvedHome(environment), environment: environment)
    }

    /// 32 random bytes as 64 hex digits: a header value that needs no escaping.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Writes a new key and returns it, or `nil` (with one stderr line) when
    /// it could not be written — then the listener has no key and refuses
    /// every `/signal` rather than answering to one nobody can read.
    ///
    /// The directory is made `0700` when missing. The key goes into a fresh
    /// temporary file opened `0600` with `O_EXCL|O_NOFOLLOW` and is renamed
    /// over the old one: `rename` replaces a symlink planted at the path
    /// rather than following it, and a reader never sees half a key.
    static func write(to url: URL) -> String? {
        let key = generate()
        do {
            try store(key, at: url)
            return key
        } catch {
            FileHandle.standardError.write(Data("Evlat: signal key not written (\(url.path)): \(error)\n".utf8))
            return nil
        }
    }

    /// The file a listener wrote, set on its queue and read when the
    /// process ends.
    final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var file: (url: URL, key: String)?

        func set(_ url: URL, _ key: String) { lock.withLock { file = (url, key) } }

        /// `SignalKey.remove` for what was written, once.
        func remove() {
            guard let file = lock.withLock({ () -> (url: URL, key: String)? in
                defer { self.file = nil }
                return self.file
            }) else { return }
            SignalKey.remove(file.key, at: file.url)
        }
    }

    /// Removes the key file on quit, if it still holds `key`: a program that
    /// posts afterwards finds no key and stays silent rather than handing the
    /// key and its command line to whatever takes the port next.
    /// A crash leaves the file; the next launch replaces it.
    static func remove(_ key: String, at url: URL) {
        guard read(from: url) == key else { return }
        unlink(url.path)
    }

    /// The key a running Evlat wrote, or `nil` when there is no readable file.
    /// Surrounding whitespace is dropped, so a file edited by hand still reads.
    static func read(from url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    struct WriteError: Error, CustomStringConvertible {
        let step: String
        let code: Int32
        var description: String { "\(step): \(String(cString: strerror(code)))" }
    }

    private static func store(_ key: String, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its mode otherwise — the chats' store
        // makes it first at `0755`. Stated, like the file's.
        if chmod(directory.path, 0o700) != 0 { throw WriteError(step: "chmod directory", code: errno) }
        // Unique, so a temporary left by a crash never blocks `O_EXCL`.
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid())-\(UInt32.random(in: .min ... .max))")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError(step: "open", code: errno) }
        var failure: WriteError?
        // The mode is stated again: `open`'s is filtered through the umask,
        // which can only take bits away, but it is the file's mode that the
        // claim rests on.
        if fchmod(fd, 0o600) != 0 { failure = WriteError(step: "chmod", code: errno) }
        let bytes = Array((key + "\n").utf8)
        if failure == nil, bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != bytes.count {
            failure = WriteError(step: "write", code: errno)
        }
        close(fd)
        if failure == nil, rename(temporary.path, url.path) != 0 { failure = WriteError(step: "rename", code: errno) }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
    }
}
