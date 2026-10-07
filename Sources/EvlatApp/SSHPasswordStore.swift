import EvlatCore
import Foundation
import Security

/// Where a machine's `ssh` password is remembered, by machine id. The
/// tunnels read it for a quiet try's password prompt (`RemoteTunnels`); the
/// window's "Remember" box decides whether a typed one is kept.
///
/// Asynchronous on purpose: the Keychain's answer can wait on the user (an
/// access prompt), so a real store calls back on the main queue later and
/// never blocks it. **Main queue only** for the calls and the callbacks.
protocol SSHPasswordStore: AnyObject {
    func password(for id: String, completion: @escaping (StoredPassword?) -> Void)
    /// `target` is what the entry is labelled with; the key is the id.
    func save(_ stored: StoredPassword, for id: String, target: String)
    func delete(for id: String)
}

/// A remembered password and the prompt it was typed at. It answers that
/// prompt only: a `ProxyJump`'s nested `ssh` inherits the askpass variables,
/// and its jump host's `user@jump's password:` may come first — the
/// machine's password must never go there. The prompt is compared, not the
/// host read out of it: an `ssh_config` alias shows its `HostName`.
struct StoredPassword: Equatable {
    let password: String
    let prompt: String

    func answers(_ prompt: String) -> Bool {
        Self.normalized(prompt) == Self.normalized(self.prompt)
    }

    private static func normalized(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The store that keeps nothing past the process: what a test and an
/// second Evlat (`EVLAT_SOCKET`) use. Answers at once.
final class MemoryPasswordStore: SSHPasswordStore {
    private var passwords: [String: StoredPassword] = [:]

    init(_ passwords: [String: StoredPassword] = [:]) {
        self.passwords = passwords
    }

    func password(for id: String, completion: @escaping (StoredPassword?) -> Void) {
        completion(passwords[id])
    }

    func save(_ stored: StoredPassword, for id: String, target: String) {
        passwords[id] = stored
    }

    func delete(for id: String) {
        passwords[id] = nil
    }
}

/// The store that remembers: one internet password per machine in the
/// user's login keychain — the classic file keychain, not the data
/// protection one, which would need an entitlement. Account is the
/// machine's id, protocol `ssh`, server the target's host, label
/// `Evlat — <target>`, so the entry reads plainly in Keychain Access; the
/// comment holds the prompt it answers (`StoredPassword`). An entry with no
/// comment answers no prompt: the user is asked, and the answer replaces it.
///
/// Every Security call runs on one serial queue, never the main one: the
/// keychain may ask the user (an ad-hoc build asks after every build), and
/// that question blocks the calling thread. Serial, so a save is seen by
/// the read after it. A failure is said on stderr (`NSLog` is unreadable
/// for this app) and is not the flow's end: a password whose write failed
/// is kept in memory for the rest of the process.
final class KeychainPasswordStore: SSHPasswordStore {
    private let queue = DispatchQueue(label: "dev.kalaomer.evlat.keychain")
    /// Written passwords the keychain refused; main queue only.
    private var unsaved: [String: StoredPassword] = [:]
    /// Per id, how many saves and deletes were asked: a refused write that
    /// reports back after a later call does not bring its password back.
    private var changes: [String: Int] = [:]

    private static func query(for id: String) -> [CFString: Any] {
        [kSecClass: kSecClassInternetPassword,
         kSecAttrAccount: id,
         kSecAttrProtocol: kSecAttrProtocolSSH]
    }

    func password(for id: String, completion: @escaping (StoredPassword?) -> Void) {
        if let stored = unsaved[id] { return completion(stored) }
        queue.async {
            var query = Self.query(for: id)
            query[kSecReturnData] = true
            query[kSecReturnAttributes] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            let found = item as? [CFString: Any]
            let stored = (found?[kSecValueData] as? Data).flatMap { String(data: $0, encoding: .utf8) }
                .map { StoredPassword(password: $0, prompt: found?[kSecAttrComment] as? String ?? "") }
            if status != errSecSuccess, status != errSecItemNotFound { Self.report("read", status) }
            DispatchQueue.main.async { completion(stored) }
        }
    }

    func save(_ stored: StoredPassword, for id: String, target: String) {
        unsaved[id] = nil
        changes[id, default: 0] += 1
        let change = changes[id]
        let server = RemoteMachine(id: id, target: target)?.name ?? target
        queue.async { [weak self] in
            let data = Data(stored.password.utf8)
            let attributes: [CFString: Any] = [kSecValueData: data,
                                               kSecAttrServer: server,
                                               kSecAttrComment: stored.prompt,
                                               kSecAttrLabel: "Evlat — \(target)"]
            var status = SecItemUpdate(Self.query(for: id) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                let item = Self.query(for: id).merging(attributes) { _, new in new }
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status != errSecSuccess else { return }
            Self.report("write", status)
            DispatchQueue.main.async {
                guard let self, self.changes[id] == change else { return }
                self.unsaved[id] = stored
            }
        }
    }

    func delete(for id: String) {
        unsaved[id] = nil
        changes[id, default: 0] += 1
        queue.async {
            let status = SecItemDelete(Self.query(for: id) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { Self.report("delete", status) }
        }
    }

    private static func report(_ action: String, _ status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        FileHandle.standardError.write(Data("Evlat: keychain \(action) failed: \(message)\n".utf8))
    }
}
