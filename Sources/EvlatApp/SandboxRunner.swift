import Foundation
import EvlatCore

/// Runs `sbx` for the sandbox watcher: the plan's commands
/// (`SandboxInstall.install/uninstall`) and the list (`SandboxInstall.list`).
/// `RemoteInstaller`'s pattern: the work runs on its own serial queue, never
/// the main one (`sbx exec` waits for the VM); the result is delivered on the
/// main queue; and one sandbox runs one job at a time — a second is refused,
/// not queued, so an install and a removal never race in the same VM.
///
/// No shell: `sbx` is started with its argument vector, stdin the command's
/// content or `/dev/null`. A command still running after `deadline` is ended
/// and fails.
///
/// **Main queue only** for `run`, `list` and `isBusy`. The queue is serial:
/// jobs for different sandboxes wait for each other too.
final class SandboxRunner {
    /// Why a job failed: the first line `sbx` wrote to stderr, or what
    /// stood in for it (it could not start, it ran past the deadline).
    struct Failure: Error, Equatable {
        let reason: String
        /// The sandbox was not running when its job's turn came: nothing
        /// was run for it.
        var notRunning = false
    }

    let sbxPath: String
    private let queue: DispatchQueue
    private let deadline: TimeInterval
    private var busy: Set<String> = []

    init(sbxPath: String, queue: DispatchQueue = DispatchQueue(label: "dev.kalaomer.evlat.sbx"),
         deadline: TimeInterval = 30) {
        self.sbxPath = sbxPath
        self.queue = queue
        self.deadline = deadline
    }

    func isBusy(_ sandbox: String) -> Bool { busy.contains(sandbox) }

    /// Runs `commands` in order for `sandbox`, stopping at the first that
    /// fails. `false`, and `completion` is never called, while the sandbox
    /// has a job running.
    ///
    /// The list is read again when the job's turn comes, and nothing runs
    /// unless `sandbox` is running then (`Failure.notRunning`): the job may
    /// have waited behind others' on the serial queue, and `sbx exec`
    /// starts a sandbox that stopped meanwhile.
    @discardableResult
    func run(_ commands: [SandboxInstall.Command], sandbox: String,
             completion: @escaping (Result<Void, Failure>) -> Void) -> Bool {
        let path = sbxPath, deadline = self.deadline
        return start(sandbox, completion: completion) {
            let listed = Self.run(path, SandboxInstall.list, deadline: deadline)
            if let failure = listed.failure { return .failure(failure) }
            guard let sandboxes = SandboxInstall.sandboxes(fromList: listed.output) else {
                return .failure(Failure(reason: "sbx ls --json answered another shape"))
            }
            guard sandboxes.contains(where: { $0.name == sandbox && $0.isRunning }) else {
                return .failure(Failure(reason: "not running", notRunning: true))
            }
            for command in commands {
                let answer = Self.run(path, command, deadline: deadline)
                if let failure = answer.failure { return .failure(failure) }
            }
            return .success(())
        }
    }

    /// The sandboxes on this Mac (`sbx ls --json`); `nil` when `sbx` failed
    /// or answered another shape. Read-only, so never refused: it waits its
    /// turn on the queue.
    func list(completion: @escaping ([SandboxInstall.Sandbox]?) -> Void) {
        let path = sbxPath, deadline = self.deadline
        queue.async {
            let answer = Self.run(path, SandboxInstall.list, deadline: deadline)
            let sandboxes = answer.failure == nil ? SandboxInstall.sandboxes(fromList: answer.output) : nil
            DispatchQueue.main.async { completion(sandboxes) }
        }
    }

    /// Where `sbx` says its daemon's socket is
    /// (`SandboxInstall.daemonStatus`), or `nil` when it did not say.
    /// Read-only, like the list.
    func daemonSocket(completion: @escaping (String?) -> Void) {
        let path = sbxPath, deadline = self.deadline
        queue.async {
            let answer = Self.run(path, SandboxInstall.daemonStatus, deadline: deadline)
            let socket = answer.failure == nil ? SandboxInstall.daemonSocket(fromStatus: answer.output) : nil
            DispatchQueue.main.async { completion(socket) }
        }
    }

    /// `sbx`'s version (`SandboxInstall.version`), or `nil` when it did not
    /// say one. Read-only, like the list.
    func version(completion: @escaping (String?) -> Void) {
        let path = sbxPath, deadline = self.deadline
        queue.async {
            let answer = Self.run(path, SandboxInstall.version, deadline: deadline)
            let version = answer.failure == nil ? SandboxInstall.version(fromOutput: answer.output) : nil
            DispatchQueue.main.async { completion(version) }
        }
    }

    private func start<T>(_ key: String, completion: @escaping (T) -> Void, work: @escaping () -> T) -> Bool {
        guard busy.insert(key).inserted else { return false }
        queue.async {
            let result = work()
            DispatchQueue.main.async { [weak self] in
                self?.busy.remove(key)
                completion(result)
            }
        }
        return true
    }

    // MARK: - One process

    struct Answer {
        let output: Data
        let failure: Failure?
    }

    /// One `sbx` run, synchronously. stdout and stderr are drained as they
    /// arrive and stdin fed on its own thread, so no pipe fills while
    /// another is waited on.
    static func run(_ path: String, _ command: SandboxInstall.Command, deadline: TimeInterval) -> Answer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = command.arguments
        let output = Pipe(), errors = Pipe()
        let input = command.input.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // An `sbx` that exits before reading its stdin must not take Evlat
        // with it: the write then fails with EPIPE instead of a SIGPIPE.
        if let input { _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        do {
            try process.run()
        } catch {
            return Answer(output: Data(), failure: Failure(reason: error.localizedDescription))
        }
        // Past the deadline: SIGTERM, then SIGKILL — an `sbx` that ignores
        // the first must not hold the serial queue for good.
        let ended = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            guard process.isRunning else { return }
            ended.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        if let input, let text = command.input {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        // Read as it arrives: a child `sbx` left behind may hold the pipes
        // open after it exits, so their end is waited for only briefly.
        let stdout = Collected(), stderr = Collected()
        let closed = DispatchGroup()
        for (pipe, box) in [(output, stdout), (errors, stderr)] {
            closed.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard data.isEmpty else { return box.append(data) }
                handle.readabilityHandler = nil
                if box.finish() { closed.leave() }
            }
        }
        process.waitUntilExit()
        _ = closed.wait(timeout: .now() + 2)
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil

        if ended.isSet { return Answer(output: stdout.data, failure: Failure(reason: "sbx did not answer in time")) }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let line = String(decoding: stderr.data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            let reason = line ?? "sbx exited with \(process.terminationStatus)"
            return Answer(output: stdout.data, failure: Failure(reason: String(reason.prefix(300))))
        }
        return Answer(output: stdout.data, failure: nil)
    }

    /// One stream's bytes, appended on its handler's thread.
    private final class Collected {
        private let lock = NSLock()
        private var bytes = Data()
        private var finished = false
        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        /// `true` the first time only.
        func finish() -> Bool { lock.withLock { defer { finished = true }; return !finished } }
        var data: Data { lock.withLock { bytes } }
    }

    /// Set once, from the deadline's thread, read after the wait.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
