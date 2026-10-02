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
                    ssh: String) -> RemoteHost.Reply? {
        let nonce = UUID().uuidString
        guard let script = RemoteHost.script(sessionID: sessionID, records: records, nonce: nonce),
              let answer = try? RemoteInstaller.run(ssh, RemoteHost.arguments(target: target, controlPath: controlPath),
                                                    script: script) else { return nil }
        return RemoteHost.reply(exitCode: answer.status, output: answer.output, nonce: nonce, arrivedAt: Date())
    }
}
