import Foundation

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
