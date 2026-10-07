import Foundation
import EvlatCore
import EvlatAgents

/// Runs `RemoteSettings`' scripts over `ssh` — per change, read → plan →
/// write — and `RemoteCommand`'s, one call each; the machine's one
/// read-only call (`RemoteSettings.readingScript`); and the tunnels' channel
/// steps (`RemoteTunnel`): the probe with its reading, and the forward.
///
/// The work runs on its own serial queue, never the main one: `ssh` can take
/// `ConnectTimeout` to fail. The result is delivered on the main queue, and
/// one machine runs one job at a time — a second is refused, not queued, so
/// two writes can never race on the same server file. A channel step takes
/// no lock — the user's press is never refused for it — and runs on a queue
/// of its own: behind another machine's job it would wait out that job's
/// `ConnectTimeout` and miss its own deadline. What it shares with a write
/// is harmless: its read finds a file that changed while it was read
/// unreadable, and it touches no settings file.
///
/// **Main queue only** for `run` and `isBusy`, like the window that calls it.
final class RemoteInstaller {
    typealias Result = Swift.Result<SettingsFile.Outcome, RemoteSettings.Failure>
    typealias CommandResult = Swift.Result<RemoteCommand.Report, RemoteCommand.Failure>

    private let sshPath: String
    private let queue: DispatchQueue
    /// The tunnels' channel steps; one at a time per machine already
    /// (`RemoteTunnel`), side by side across machines.
    private let channels = DispatchQueue(label: "evlat.remote-channel", attributes: .concurrent)
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
    ///
    /// `controlPath`, here and on the other jobs: the socket of the
    /// machine's tunnel master (`RemoteTunnels.controlPath(of:)`), read on
    /// the main queue by the caller; every call of the job rides it.
    @discardableResult
    func run(_ changes: [RemoteSettings.Change], _ action: RemoteSettings.Action,
             machine: String, target: String, controlPath: String? = nil,
             completion: @escaping ([(RemoteSettings.Change, Result)]) -> Void) -> Bool {
        let sshPath = self.sshPath, beforeWrite = self.beforeWrite
        return start(machine: machine, completion: completion) {
            var results: [(RemoteSettings.Change, Result)] = []
            for change in changes {
                if results.contains(where: { $0.1 == .failure(.unreachable) }) {
                    results.append((change, .failure(.unreachable)))
                    continue
                }
                let result = Self.apply(change, action, target: target, ssh: sshPath, controlPath: controlPath,
                                        beforeWrite: { beforeWrite(change) })
                results.append((change, result))
            }
            return results
        }
    }

    /// Installs or removes the server's `evlat` on `target`, under the same
    /// one-job-per-machine lock as the settings: the buttons of both go off
    /// together. `pathLine`, on a removal: the startup file whose Evlat
    /// `PATH` line goes with the command, in the same job, once the command
    /// is gone.
    @discardableResult
    func runCommand(_ action: RemoteSettings.Action, pathLine: String? = nil,
                    machine: String, target: String, controlPath: String? = nil,
                    completion: @escaping (CommandResult, Result?) -> Void) -> Bool {
        let sshPath = self.sshPath
        return start(machine: machine, completion: { (both: (CommandResult, Result?)) in completion(both.0, both.1) }) {
            let command = Self.applyCommand(action, target: target, ssh: sshPath,
                                            controlPath: controlPath)
            guard action == .remove, case .success = command, let pathLine else { return (command, Result?.none) }
            return (command, Self.apply(.pathLine(pathLine), .remove, target: target, ssh: sshPath,
                                        controlPath: controlPath))
        }
    }

    /// Reads the machine's settings files and command in one call, under the
    /// same lock: `false`, and no `completion`, while a job runs there — a
    /// read is skipped, never queued behind a write.
    @discardableResult
    func read(machine: String, target: String, controlPath: String? = nil,
              completion: @escaping (Swift.Result<RemoteSettings.Reading, RemoteSettings.Failure>) -> Void) -> Bool {
        let sshPath = self.sshPath
        return start(machine: machine, completion: completion) {
            Self.applyRead(target: target, ssh: sshPath, controlPath: controlPath)
        }
    }

    /// The tunnel's probe and the machine's reading, in one call over its
    /// master (`RemoteSettings.readingScript`, `probing`). `deadline`: a
    /// call over a master is not bounded by `ConnectTimeout`.
    func channel(target: String, controlPath: String, deadline: TimeInterval = 20,
                 completion: @escaping (Swift.Result<RemoteSettings.Reading, RemoteSettings.Failure>) -> Void) {
        let sshPath = self.sshPath
        channels.async {
            let result = Self.applyRead(target: target, ssh: sshPath, controlPath: controlPath, probing: true,
                                        deadline: deadline)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The channel's forward, asked of the running master
    /// (`RemoteTunnel.forwardArguments`): `true` when it was made.
    func forward(target: String, controlPath: String, remote: String, local: String, deadline: TimeInterval = 10,
                 completion: @escaping (Bool) -> Void) {
        let sshPath = self.sshPath
        channels.async {
            let arguments = RemoteTunnel.forwardArguments(target: target, controlPath: controlPath,
                                                          remote: remote, local: local)
            let made = (try? Self.run(sshPath, arguments, script: "", deadline: deadline))?.status == 0
            DispatchQueue.main.async { completion(made) }
        }
    }

    /// The read's one call, synchronously.
    static func applyRead(target: String, ssh: String, controlPath: String? = nil,
                          patience: Int = RemotePath.patience, probing: Bool = false,
                          deadline: TimeInterval? = nil) -> Swift.Result<RemoteSettings.Reading, RemoteSettings.Failure> {
        let nonce = UUID().uuidString
        guard let answer = try? run(ssh, RemoteSettings.arguments(target: target, controlPath: controlPath),
                                    script: RemoteSettings.readingScript(nonce: nonce, agents: Agents.all,
                                                                       patience: patience, probing: probing),
                                    deadline: deadline) else {
            return .failure(.unreachable)
        }
        do {
            return .success(try RemoteSettings.reading(exitCode: answer.status, output: answer.output, nonce: nonce,
                                                      agents: Agents.all.ids))
        } catch {
            return .failure(.unreachable)
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
    static func applyCommand(_ action: RemoteSettings.Action,
                             target: String, ssh: String, controlPath: String? = nil) -> CommandResult {
        let nonce = UUID().uuidString
        let script = action == .install
            ? RemoteCommand.installScript(nonce: nonce)
            : RemoteCommand.removeScript(nonce: nonce)
        guard let answer = try? run(ssh, RemoteSettings.arguments(target: target, controlPath: controlPath),
                                    script: script) else {
            return .failure(.unreachable)
        }
        return RemoteCommand.result(exitCode: answer.status, output: answer.output, nonce: nonce)
    }

    /// One change, synchronously: two `ssh` calls at most, one when nothing
    /// is to be written.
    static func apply(_ change: RemoteSettings.Change, _ action: RemoteSettings.Action,
                      target: String, ssh: String, controlPath: String? = nil,
                      beforeWrite: () -> Void = {}) -> Result {
        let arguments = RemoteSettings.arguments(target: target, controlPath: controlPath)
        let nonce = UUID().uuidString
        do {
            let read = try run(ssh, arguments, script: RemoteSettings.readScript(path: change.path, nonce: nonce,
                                                                               opening: change.opening))
            let snapshot = try RemoteSettings.snapshot(exitCode: read.status, output: read.output, nonce: nonce)
            guard let write = try RemoteSettings.plan(change, action, original: snapshot.bytes) else {
                return .success(.unchanged)
            }
            beforeWrite()
            let script = RemoteSettings.writeScript(path: change.path, expected: snapshot.checksum, write: write,
                                                   opening: change.opening)
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
    /// Also `RemoteHostLookup`'s, which shares the process and not the lock,
    /// and gives a `deadline`: past it the process is ended and the call is
    /// unreachable — a server stuck in its script must not hold the lookup's
    /// queue, and `ConnectTimeout` does not reach a command over a master.
    static func run(_ path: String, _ arguments: [String],
                    script: String, deadline: TimeInterval? = nil) throws -> (output: Data, status: Int32) {
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
        if let deadline {
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if process.isRunning { process.terminate() }
            }
        }

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
