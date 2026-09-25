import Foundation
import EvlatCore

/// Runs `RemoteSettings`' scripts over `ssh` — per change, read → plan →
/// write — and `RemoteCommand`'s, one call each.
///
/// The work runs on its own queue, never the main one: `ssh` can take
/// `ConnectTimeout` to fail. The result is delivered on the main queue, and
/// one machine runs one job at a time — a second is refused, not queued, so
/// two writes can never race on the same server file.
///
/// **Main queue only** for `run` and `isBusy`, like the window that calls it.
final class RemoteInstaller {
    typealias Result = Swift.Result<SettingsFile.Outcome, RemoteSettings.Failure>
    typealias CommandResult = Swift.Result<RemoteCommand.Report, RemoteCommand.Failure>

    private let sshPath: String
    private let queue: DispatchQueue
    private var busy: Set<String> = []

    /// Called on the work queue between a change's read and its write; the
    /// test that changes the server's file in that gap sets it.
    var beforeWrite: (RemoteSettings.Change) -> Void = { _ in }

    /// `sshPath` is handed in: `AppController.sshPath()` reads `EVLAT_SSH`,
    /// and a test gives its fake.
    init(sshPath: String, queue: DispatchQueue = DispatchQueue(label: "evlat.remote-installer")) {
        self.sshPath = sshPath
        self.queue = queue
    }

    func isBusy(_ machine: String) -> Bool { busy.contains(machine) }

    /// Applies `changes` in order on `target`. A change whose directory is
    /// missing (Codex not installed) fails alone; once `ssh` cannot reach the
    /// server the rest are not tried and fail the same way. `false`, and
    /// `completion` is never called, while the machine has a job running.
    @discardableResult
    func run(_ changes: [RemoteSettings.Change], _ action: RemoteSettings.Action,
             machine: String, target: String,
             completion: @escaping ([(RemoteSettings.Change, Result)]) -> Void) -> Bool {
        let sshPath = self.sshPath, beforeWrite = self.beforeWrite
        return start(machine: machine, completion: completion) {
            var results: [(RemoteSettings.Change, Result)] = []
            for change in changes {
                if results.contains(where: { $0.1 == .failure(.unreachable) }) {
                    results.append((change, .failure(.unreachable)))
                    continue
                }
                let result = Self.apply(change, action, target: target, ssh: sshPath,
                                        beforeWrite: { beforeWrite(change) })
                results.append((change, result))
            }
            return results
        }
    }

    /// Installs or removes the server's `evlat` and its key on `target`,
    /// under the same one-job-per-machine lock as the settings: the buttons
    /// of both go off together.
    @discardableResult
    func runCommand(_ action: RemoteSettings.Action, key: String, machine: String, target: String,
                    completion: @escaping (CommandResult) -> Void) -> Bool {
        let sshPath = self.sshPath
        return start(machine: machine, completion: completion) {
            Self.applyCommand(action, key: key, target: target, ssh: sshPath)
        }
    }

    /// `work` on the work queue, its result on the main one; `false` while
    /// the machine has a job running.
    private func start<T>(machine: String, completion: @escaping (T) -> Void,
                          work: @escaping () -> T) -> Bool {
        guard busy.insert(machine).inserted else { return false }
        queue.async {
            let result = work()
            DispatchQueue.main.async { [weak self] in
                self?.busy.remove(machine)
                completion(result)
            }
        }
        return true
    }

    /// The command's one call, synchronously.
    static func applyCommand(_ action: RemoteSettings.Action, key: String,
                             target: String, ssh: String) -> CommandResult {
        let nonce = UUID().uuidString
        let script = action == .install
            ? RemoteCommand.installScript(key: key, nonce: nonce)
            : RemoteCommand.removeScript(nonce: nonce)
        guard let answer = try? run(ssh, RemoteSettings.arguments(target: target), script: script) else {
            return .failure(.unreachable)
        }
        return RemoteCommand.result(exitCode: answer.status, output: answer.output, nonce: nonce)
    }

    /// One change, synchronously: two `ssh` calls at most, one when nothing
    /// is to be written.
    static func apply(_ change: RemoteSettings.Change, _ action: RemoteSettings.Action,
                      target: String, ssh: String, beforeWrite: () -> Void = {}) -> Result {
        let arguments = RemoteSettings.arguments(target: target)
        let nonce = UUID().uuidString
        do {
            let read = try run(ssh, arguments, script: RemoteSettings.readScript(path: change.path, nonce: nonce))
            let snapshot = try RemoteSettings.snapshot(exitCode: read.status, output: read.output, nonce: nonce)
            guard let write = try RemoteSettings.plan(change, action, original: snapshot.bytes) else {
                return .success(.unchanged)
            }
            beforeWrite()
            let script = RemoteSettings.writeScript(path: change.path, expected: snapshot.checksum, write: write)
            let written = try run(ssh, arguments, script: script)
            if let failure = RemoteSettings.failure(exitCode: written.status) { throw failure }
            return .success(.written)
        } catch let failure as RemoteSettings.Failure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// The process's stdout and exit status. stdin is fed and stderr drained
    /// on their own threads, so no pipe fills while another is waited on.
    private static func run(_ path: String, _ arguments: [String],
                            script: String) throws -> (output: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // An `ssh` that exits before reading its stdin must not take Evlat
        // with it: the write then fails with EPIPE instead of a SIGPIPE.
        let writer = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        try process.run()

        let group = DispatchGroup()
        let data = Data(script.utf8)
        DispatchQueue.global().async(group: group) {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(writer, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    offset += written
                }
            }
            try? input.fileHandleForWriting.close()
        }
        DispatchQueue.global().async(group: group) {
            _ = errors.fileHandleForReading.readDataToEndOfFile()
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        // A signal is not an exit code the scripts use: unreachable.
        let status = process.terminationReason == .exit ? process.terminationStatus : 255
        return (stdout, status)
    }
}
