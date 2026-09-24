import Foundation
import EvlatCore

/// One chat turn's `claude -p` process (`011`, Karar 2): stdin a pipe that
/// carries the one user line, stdout read chunk by chunk and handed to the
/// main queue, the tail of stderr kept for the failure.
///
/// The rules are the core's (`ClaudeInvocation`, `ChatStream`,
/// `ChatSession`); this is only the process — `SSHProcess`'s pattern.
///
/// **Main queue** for every callback: chunks and the exit are hopped there
/// in order, so the stream is fed where the store lives.
final class ClaudeRunner {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let tail = StderrTail()
    private let invocation: ClaudeInvocation
    private let onOutput: (Data) -> Void
    private let onExit: (Int32, String) -> Void

    /// `path` replaces the inherited `PATH` when given: the login shell's,
    /// so the turn's own tools find what the user's terminal finds.
    init(executable: String, invocation: ClaudeInvocation, path: String?,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32, String) -> Void) {
        self.invocation = invocation
        self.onOutput = onOutput
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.directory, isDirectory: true)
        var environment = environment.merging(invocation.environment) { _, new in new }
        if let path { environment["PATH"] = path }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// Starts the process and writes the user line: `nil`, or why it could
    /// not start (then `onExit` is never called).
    func run() -> String? {
        let tail = self.tail
        let onOutput = self.onOutput
        // Both pipes are read to their end before the exit is reported: the
        // exit can be seen before the last chunk — the `result` — is read.
        let closed = DispatchGroup()
        closed.enter()
        closed.enter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else {
                DispatchQueue.main.async { onOutput(data) }
                return
            }
            handle.readabilityHandler = nil
            closed.leave()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else { return tail.append(data) }
            handle.readabilityHandler = nil
            if tail.finish() { closed.leave() }
        }
        let onExit = self.onExit
        process.terminationHandler = { process in
            // A grandchild holding the pipes open must not hold the exit
            // back for ever.
            _ = closed.wait(timeout: .now() + 1)
            let status = process.terminationStatus
            let text = tail.text
            DispatchQueue.main.async { onExit(status, text) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return error.localizedDescription
        }
        // A child that died at once has closed its end: writing would raise
        // SIGPIPE and take Evlat with it. The flag turns that into an error.
        let fd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.write(contentsOf: invocation.input)
        return nil
    }

    /// Stdin closed. After the `result` this is what lets the process exit
    /// (measured, `011/phase-1`: 0.8 s later).
    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// Ends the turn: SIGINT, the documented way ("To end the turn instead,
    /// send SIGINT"), and stdin closed so the process does not wait for a
    /// next message. Whether SIGINT alone exits 2.1.281 is not measured.
    func interrupt() {
        if process.isRunning { kill(process.processIdentifier, SIGINT) }
        closeInput()
    }

    /// Evlat is quitting.
    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
    }
}

/// Finds `claude` once (`011`, İşletme): `EVLAT_CLAUDE` first; else the login
/// shell's `PATH`, read once with a time limit, because an app opened from
/// Finder inherits a short `PATH` and would find neither `claude` nor the
/// tools its turns run.
final class ClaudeLocator {
    struct Location: Equatable {
        /// The binary, or `nil` when there is none.
        let executable: String?
        /// The `PATH` turns run with; `nil` keeps the inherited one.
        let path: String?
    }

    private let environment: [String: String]
    private let loginPath: () -> String?
    private var found: Location?
    private var waiting: [(Location) -> Void] = []

    /// The markers around the `PATH` in the login shell's output: a profile
    /// may print a banner, and only what is between them is read.
    static let marker = "__EVLAT_PATH__"

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         loginPath: @escaping () -> String? = { ClaudeLocator.readLoginPath() }) {
        self.environment = environment
        self.loginPath = loginPath
        if let raw = environment["EVLAT_CLAUDE"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            found = Location(executable: FileManager.default.isExecutableFile(atPath: path) ? path : nil,
                             path: nil)
        }
    }

    /// Calls back on the main queue — at once when already known, else after
    /// one lookup off the main queue. Called on the main queue.
    func locate(_ completion: @escaping (Location) -> Void) {
        if let found { return completion(found) }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        let loginPath = self.loginPath
        let inherited = environment["PATH"]
        DispatchQueue.global(qos: .userInitiated).async {
            let path = loginPath()
            let location = Location(executable: Self.find("claude", in: path ?? inherited ?? ""),
                                    path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A miss is not kept: `claude` may be installed, or a slow
                // shell may answer, by the next send.
                if location.executable != nil { self.found = location }
                let waiting = self.waiting
                self.waiting = []
                waiting.forEach { $0(location) }
            }
        }
    }

    /// The first executable `name` along a `PATH`.
    static func find(_ name: String, in path: String) -> String? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func markedPath(in output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// The user's login shell, asked once for its `PATH`: `-l -i` so both
    /// the profile and the rc file run, as in a terminal. Ended after
    /// `timeout`; a shell that prints no marker gives `nil`.
    static func readLoginPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                              timeout: TimeInterval = 5) -> String? {
        let process = Process()
        let output = Pipe()
        let collected = Collected()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Read as it arrives and stop at the closing marker or EOF,
        // whichever is first: a daemon started from an rc file may inherit
        // stdout and hold the pipe open long after the shell is gone, so
        // neither the shell's exit nor EOF alone can be waited for.
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            if collected.append(data) { done.signal() }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let answered = done.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return answered ? markedPath(in: collected.text) : nil
    }

    /// The login shell's output so far; `append` says when to stop reading.
    private final class Collected {
        private let lock = NSLock()
        private var data = Data()
        private var signalled = false

        /// `true` once, when the path is complete or the pipe ended.
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                data.append(chunk)
                let complete = chunk.isEmpty
                    || String(decoding: data, as: UTF8.self).components(separatedBy: ClaudeLocator.marker).count >= 3
                guard complete, !signalled else { return false }
                signalled = true
                return true
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
