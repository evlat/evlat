import Foundation

/// The `Evlat` binary as `ssh`'s askpass helper: what marks it, where it asks,
/// and how a prompt is told apart. Pure; the helper's side effects are in
/// `EvlatApp` (`AskpassHelper`), the route in `LocalAPI`.
///
/// `ssh` runs its askpass with the prompt alone in `argv[1]` — no subcommand
/// word, nothing else (measured, OpenSSH 10.2p1). So the binary cannot tell a
/// helper call from a stray word by `argv`; only the tunnel's environment
/// says it, and an unmarked prompt stays a usage error (`LaunchMode`).
public enum Askpass {
    /// `EVLAT_ASKPASS=<port>:<token>`: put by Evlat into the tunnel's `ssh`
    /// only, read by the helper `ssh` starts. The token is never in an argv.
    public static let environmentKey = "EVLAT_ASKPASS"
    /// The header the helper carries the token in (`HTTPRequest.askpassToken`).
    public static let header = "X-Evlat-Askpass"
    /// The route: local, keyed by the token, held until answered (`LocalAPI`).
    public static let path = "/askpass"

    /// Where the running Evlat listens and which attempt is asking.
    public struct Mark: Equatable {
        public let port: UInt16
        public let token: String

        public init(port: UInt16, token: String) {
            self.port = port
            self.token = token
        }
    }

    /// The mark in `environment`, or `nil` when there is none or it does not
    /// read exactly: a port `1…65535` and a 64-hex token, nothing else. A
    /// broken mark is no mark — the binary then never becomes a helper.
    public static func mark(in environment: [String: String]) -> Mark? {
        guard let value = environment[environmentKey] else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy(\.isASCII), parts[0].allSatisfy(\.isNumber),
              let port = UInt16(parts[0]), port > 0, isToken(String(parts[1])) else { return nil }
        return Mark(port: port, token: String(parts[1]))
    }

    /// The environment value that `mark(in:)` reads back.
    public static func value(_ mark: Mark) -> String {
        "\(mark.port):\(mark.token)"
    }

    /// 64 lowercase hex digits, the shape of a machine's `/signal` key.
    public static func isToken(_ value: String) -> Bool {
        RemoteMachine.isSignalKey(value)
    }

    /// One prompt from one helper, held until it is answered.
    public struct Request: Equatable {
        /// Evlat's name for this request: the held connection is keyed by it.
        public let id: String
        /// Which attempt asked; matched to a machine on the main queue.
        public let token: String
        /// The prompt exactly as `ssh` wrote it, several lines for a host key.
        public let prompt: String

        public init(id: String = UUID().uuidString, token: String, prompt: String) {
            self.id = id
            self.token = token
            self.prompt = prompt
        }
    }

    // MARK: - Prompt classes

    /// A password prompt: the one a stored password may answer. Ends in
    /// `password:`, and is not a change of password (`New password:`,
    /// `Retype new password:`). A passphrase, a verification code or anything
    /// unknown is not one — a miss sends the prompt to the user, which is the
    /// safe direction.
    ///
    /// The user and host in front are not read for those words: `ssh`'s own
    /// `user@host's password:` is one whatever the names, and the
    /// `(user@host) ` it puts before a keyboard-interactive prompt is dropped
    /// first — else `newton` or `renewal` would never be answered.
    public static func isPassword(_ prompt: String) -> Bool {
        var text = Substring(prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if text.hasSuffix("'s password:") { return true }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = text[text.index(after: close)...].drop { $0 == " " }
        }
        return text.hasSuffix("password:") && !text.contains("new") && !text.contains("retype")
    }

    /// A yes/no question: the host key's `continue connecting (yes/no/…)`.
    public static func isYesNo(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return text.contains("(yes/no") || text.contains("continue connecting")
    }
}
