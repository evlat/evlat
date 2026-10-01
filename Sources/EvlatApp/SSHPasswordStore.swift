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
    func password(for id: String, completion: @escaping (String?) -> Void)
    /// `target` is what the entry is labelled with; the key is the id.
    func save(_ password: String, for id: String, target: String)
    func delete(for id: String)
}

/// The store that keeps nothing past the process: what a test and an
/// isolated process (`EVLAT_PORT`) use. Answers at once.
final class MemoryPasswordStore: SSHPasswordStore {
    private var passwords: [String: String] = [:]

    init(_ passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    func password(for id: String, completion: @escaping (String?) -> Void) {
        completion(passwords[id])
    }

    func save(_ password: String, for id: String, target: String) {
        passwords[id] = password
    }

    func delete(for id: String) {
        passwords[id] = nil
    }
}

/// The store that remembers: one internet password per machine in the
/// user's login keychain — the classic file keychain, not the data
/// protection one, which would need an entitlement. Account is the
/// machine's id, protocol `ssh`, server the target's host, label
/// `Evlat — <target>`, so the entry reads plainly in Keychain Access.
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
    private var unsaved: [String: String] = [:]
    /// Per id, how many saves and deletes were asked: a refused write that
    /// reports back after a later call does not bring its password back.
    private var changes: [String: Int] = [:]

    private static func query(for id: String) -> [CFString: Any] {
        [kSecClass: kSecClassInternetPassword,
         kSecAttrAccount: id,
         kSecAttrProtocol: kSecAttrProtocolSSH]
    }

    func password(for id: String, completion: @escaping (String?) -> Void) {
        if let password = unsaved[id] { return completion(password) }
        queue.async {
            var query = Self.query(for: id)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            let password = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            if status != errSecSuccess, status != errSecItemNotFound { Self.report("read", status) }
            DispatchQueue.main.async { completion(password) }
        }
    }

    func save(_ password: String, for id: String, target: String) {
        unsaved[id] = nil
        changes[id, default: 0] += 1
        let change = changes[id]
        let server = RemoteMachine(id: id, target: target)?.name ?? target
        queue.async { [weak self] in
            let data = Data(password.utf8)
            let attributes: [CFString: Any] = [kSecValueData: data,
                                               kSecAttrServer: server,
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
                self.unsaved[id] = password
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
