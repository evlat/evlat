import Foundation

/// What Evlat puts into a running Docker sandbox (`sbx`) so that the agent
/// inside it reaches Evlat on this Mac, and how it takes it out again. Two
/// things, and nothing of the user's: a network rule scoped to that one
/// sandbox that lets the VM's proxy through to the sandbox listener's port,
/// and one file of Evlat's own, written as root.
///
/// Only the plan lives here — the `sbx` arguments, what goes on stdin, and
/// the reading of `sbx ls --json` — so it is tested without a process. The
/// shell runs it. Every change is made through the `sbx` CLI, never the
/// daemon's own routes.
///
/// It names no agent: the file's path and content are the catalog's
/// (`Agents.sandboxInstall`). An installed contract like
/// `RemoteCommand.script`: a running sandbox keeps the bytes it was given,
/// so they are pinned (`SandboxInstallTests`).
public struct SandboxInstall: Equatable {
    /// The sandbox listener's port. Fixed rather than following
    /// `EVLAT_PORT`: it is written into every sandbox's file and rule, so a
    /// run that moved it would leave them speaking to nothing — or to the
    /// main port.
    public static let defaultPort: UInt16 = LocalAPI.defaultPort + 1
    /// How the VM names this Mac. The sandbox's proxy takes it to
    /// `localhost`, which is why the rule says `localhost`.
    public static let host = "host.docker.internal"
    /// The longest sandbox name a command is made for.
    public static let nameLimit = 64

    /// The listener's port, written into the rule.
    public let port: UInt16
    /// An absolute path in the VM, a file that is Evlat's alone.
    public let path: String
    /// The file's whole content.
    public let content: String

    public init(port: UInt16 = defaultPort, path: String, content: String) {
        self.port = port
        self.path = path
        self.content = content
    }

    /// One `sbx` run: its arguments after the program, and what goes on its
    /// stdin (`nil`: none).
    public struct Command: Equatable {
        public let arguments: [String]
        public let input: String?

        public init(arguments: [String], input: String? = nil) {
            self.arguments = arguments
            self.input = input
        }
    }

    /// The rule's resource: the listener's port as the VM's proxy sees it.
    var resource: String { "localhost:\(port)" }

    /// The commands that set `sandbox` up, in order: the rule, then the
    /// file. Both can run again: `sbx` keeps one rule per resource, and the
    /// file is replaced whole. `nil` for a name that is not one
    /// (`isSandboxName`): no command is made for it.
    ///
    /// The rule always names the sandbox: without `--sandbox` it would go
    /// into the global policy, open to every sandbox on this Mac. The file
    /// is written to a temporary name in the same folder and moved into
    /// place, so the agent never reads half of it; the temporary name does
    /// not end in `.json`, which is what the folder's reader takes, and
    /// carries the writing shell's pid (`$$`), so two runs at once never
    /// share one. The content goes on stdin, never into an argument.
    public func install(sandbox: String) -> [Command]? {
        guard Self.isSandboxName(sandbox) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        let temporary = RemoteSettings.quoted(path + ".tmp.") + "$$"
        let script = "mkdir -p \(RemoteSettings.quoted(folder))"
            + " && cat > \(temporary)"
            + " && mv -f \(temporary) \(RemoteSettings.quoted(path))"
        return [
            Command(arguments: ["policy", "allow", "network", "--sandbox", sandbox, resource]),
            Command(arguments: ["exec", "-i", "-u", "root", sandbox, "sh", "-c", script], input: content),
        ]
    }

    /// The commands that take it out of `sandbox`: Evlat's file alone, then
    /// the sandbox's rule. `--force` because the removal runs with no
    /// terminal to confirm it. `nil` for a name that is not one.
    public func uninstall(sandbox: String) -> [Command]? {
        guard Self.isSandboxName(sandbox) else { return nil }
        return [
            Command(arguments: ["exec", "-u", "root", sandbox, "rm", "-f", path]),
            Command(arguments: ["policy", "rm", "network", "--sandbox", sandbox,
                                "--resource", resource, "--force"]),
        ]
    }

    /// Lists the sandboxes on this Mac, as JSON (`sandboxes(fromList:)`).
    public static let list = Command(arguments: ["ls", "--json"])

    /// Asks `sbx` its version (`version(fromOutput:)`). Read-only, like the
    /// list: Settings says when it is not the one measured.
    public static let version = Command(arguments: ["version"])
    /// The `sbx` this plan, the list and the daemon's stream were measured
    /// with.
    public static let measuredVersion = "0.46.0"

    /// `sbx version`'s `sbx version: v0.46.0 <commit>` (0.46.0), as
    /// `0.46.0`; `nil` for any other shape.
    public static func version(fromOutput data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for word in text.split(whereSeparator: { $0.isWhitespace }) where word.hasPrefix("v") {
            let number = word.dropFirst()
            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
                return String(number)
            }
        }
        return nil
    }

    /// A name a command may be made for: ASCII letters, digits, `.`, `_`
    /// and `-`, at most `nameLimit`, and not starting with `-` or a dot, so
    /// that `sbx` can never take it for a flag. Stricter than the hook
    /// header's rule (`HookEvent.isSandboxName`), which only labels a row.
    /// The name comes from the daemon and goes into an argument vector.
    public static func isSandboxName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...nameLimit).contains(bytes.count), let first = bytes.first else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
        return alphanumeric(first) && bytes.allSatisfy { alphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    // MARK: - The list

    /// One sandbox as `sbx ls --json` says it.
    public struct Sandbox: Equatable {
        public let name: String
        /// The agent it was made for (`claude`, `shell`, …); `nil` when the
        /// list did not say.
        public let agent: String?
        /// `running`, `stopped`, …: `sbx`'s own word.
        public let status: String?
        /// The folder it was made in, the first of `workspaces`; `nil` for
        /// one made with none (the list then leaves the field out).
        public let workspace: String?

        public init(name: String, agent: String?, status: String?, workspace: String? = nil) {
            self.name = name
            self.agent = agent
            self.status = status
            self.workspace = workspace
        }

        /// Whether it runs now. Only a running sandbox is set up: `sbx exec`
        /// starts a stopped one.
        public var isRunning: Bool { status == "running" }
    }

    /// `sbx ls --json`'s output (`{"sandboxes": [{"name", "agent",
    /// "status", …}]}`, 0.46.0), or `nil` when it is not that shape. An
    /// entry without a name is left out; its other fields are optional.
    public static func sandboxes(fromList data: Data) -> [Sandbox]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["sandboxes"] as? [Any] else { return nil }
        return entries.compactMap { entry in
            guard let fields = entry as? [String: Any], let name = fields["name"] as? String else { return nil }
            let workspace = (fields["workspaces"] as? [Any])?.first as? String
            return Sandbox(name: name, agent: fields["agent"] as? String, status: fields["status"] as? String,
                           workspace: workspace.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
