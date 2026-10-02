import Foundation
import EvlatCore

/// Asks a server where a remote session's connection is (`RemoteHost`): one
/// `ssh` over the machine's live tunnel master, on a queue of its own, its
/// answer delivered on the main queue.
///
/// Not under `RemoteInstaller`'s per-machine lock: the call only reads, and
/// a card must not wait for a settings write, nor make one wait. The caller
/// asks once per card (`DetailModel`); a master that has gone is no call at
/// all (`RemoteHost.arguments`), never a new login.
final class RemoteHostLookup {
    private let sshPath: String
    private let queue: DispatchQueue
    /// The longest one call may take. Over a live master the script took
    /// 0.19–0.25 s, its tmux question is cut at 2 s; a call still running
    /// past this is stuck, and the queue is serial.
    static let deadline: TimeInterval = 10

    init(sshPath: String, queue: DispatchQueue = DispatchQueue(label: "evlat.remote-host")) {
        self.sshPath = sshPath
        self.queue = queue
    }

    /// `false`, and no `completion`, for an id that is not a session id: it
    /// never reaches a script. `completion` gets `nil` for "not known".
    @discardableResult
    func find(sessionID: String, records: SessionRecords, target: String, controlPath: String,
              completion: @escaping (RemoteHost.Reply?) -> Void) -> Bool {
        guard RemoteHost.isSessionID(sessionID) else { return false }
        let sshPath = self.sshPath
        queue.async {
            let reply = Self.ask(sessionID: sessionID, records: records, target: target,
                                 controlPath: controlPath, ssh: sshPath)
            DispatchQueue.main.async { completion(reply) }
        }
        return true
    }

    /// The call, synchronously.
    static func ask(sessionID: String, records: SessionRecords, target: String, controlPath: String,
                    ssh: String, deadline: TimeInterval = deadline) -> RemoteHost.Reply? {
        let nonce = UUID().uuidString
        // The terminals' forwarded names are the table's (`TabLink`); the
        // script itself knows none.
        guard let script = RemoteHost.script(sessionID: sessionID, records: records, nonce: nonce,
                                             forwarded: TabLink.forwardedNames),
              let answer = try? RemoteInstaller.run(ssh, RemoteHost.arguments(target: target, controlPath: controlPath),
                                                    script: script, deadline: deadline) else { return nil }
        return RemoteHost.reply(exitCode: answer.status, output: answer.output, nonce: nonce, arrivedAt: Date())
    }
}
