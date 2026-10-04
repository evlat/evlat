import Foundation
import EvlatCore

/// Asks a server where a remote session's connection is (`RemoteHost`): one
/// `ssh` over the machine's live tunnel master, on a queue of its own, its
/// answer delivered on the main queue. At a click it also has the server
/// select the session's herdr pane (`select`), the one call that changes
/// anything there.
///
/// Not under `RemoteInstaller`'s per-machine lock: the call only reads, or
/// selects a pane, and a card must not wait for a settings write, nor make
/// one wait. A card
/// asks once (`DetailModel`); the news asks too, with an instance of its
/// own — its own queue, `newsDeadline` — so a card's stuck question never
/// holds a finish's sound. A master that has gone is no call at
/// all (`RemoteHost.arguments`), never a new login.
final class RemoteHostLookup {
    private let sshPath: String
    private let queue: DispatchQueue
    /// This instance's longest call.
    private let callDeadline: TimeInterval
    /// The longest one call may take. Over a live master the script took
    /// 0.19–0.25 s, its tmux question is cut at 2 s; a call still running
    /// past this is stuck, and the queue is serial.
    static let deadline: TimeInterval = 10
    /// The news's longest call: a finish waits for it before it is told.
    /// A pane's answer is never walked for the news (`Connection.direct`),
    /// so cutting its tmux or herdr question loses nothing. Past it the
    /// news is told.
    static let newsDeadline: TimeInterval = 1

    init(sshPath: String, queue: DispatchQueue = DispatchQueue(label: "evlat.remote-host"),
         deadline: TimeInterval = RemoteHostLookup.deadline) {
        self.sshPath = sshPath
        self.queue = queue
        self.callDeadline = deadline
    }

    /// `false`, and no `completion`, for an id that is not a session id: it
    /// never reaches a script. `completion` gets `nil` for "not known".
    @discardableResult
    func find(sessionID: String, records: SessionRecords, target: String, controlPath: String,
              completion: @escaping (RemoteHost.Reply?) -> Void) -> Bool {
        guard RemoteHost.isSessionID(sessionID) else { return false }
        let sshPath = self.sshPath
        let deadline = callDeadline
        queue.async {
            let reply = Self.ask(sessionID: sessionID, records: records, target: target,
                                 controlPath: controlPath, ssh: sshPath, deadline: deadline)
            DispatchQueue.main.async { completion(reply) }
        }
        return true
    }

    /// The click's call: the server selects the session's herdr pane
    /// (`RemoteHost.selectScript`), on the same queue as the questions.
    /// `false`, and no `completion`, for an id that is not a session id.
    /// `completion` comes on the main queue once it is over, selected or
    /// not. A call still queued `startBy` after the click — behind another
    /// card's slow question — is not made: the window has come meanwhile,
    /// and a pane selected under the user's hands later would be a surprise.
    /// One already started runs its course, up to `selectDeadline`, and may
    /// still select the pane after the window came.
    @discardableResult
    func select(sessionID: String, records: SessionRecords, target: String, controlPath: String,
                startBy: TimeInterval, completion: @escaping () -> Void) -> Bool {
        guard RemoteHost.isSessionID(sessionID) else { return false }
        let sshPath = self.sshPath
        let latest = DispatchTime.now() + startBy
        queue.async {
            if DispatchTime.now() < latest {
                Self.selectPane(sessionID: sessionID, records: records, target: target,
                                controlPath: controlPath, ssh: sshPath)
            }
            DispatchQueue.main.async { completion() }
        }
        return true
    }

    /// The longest one selection may take: it needs a few herdr calls,
    /// each cut at 2 s; over a live master it took 37–112 ms.
    static let selectDeadline: TimeInterval = 3

    /// The selection, synchronously; over the master only, like `ask`.
    /// Whether herdr took the pane.
    @discardableResult
    static func selectPane(sessionID: String, records: SessionRecords, target: String, controlPath: String,
                           ssh: String, deadline: TimeInterval = selectDeadline) -> Bool {
        let nonce = UUID().uuidString
        guard let script = RemoteHost.selectScript(sessionID: sessionID, records: records, nonce: nonce),
              let answer = try? RemoteInstaller.run(ssh, RemoteHost.arguments(target: target, controlPath: controlPath),
                                                    script: script, deadline: deadline) else { return false }
        return RemoteHost.selected(exitCode: answer.status, output: answer.output, nonce: nonce)
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
