import Foundation

/// The kit Evlat makes for Docker Sandboxes (`sbx`): a mixin a sandbox is
/// made with (`sbx run --kit <folder>`, or `sbx kit add` for one that
/// exists) so that the agent inside it reaches Evlat on this Mac. Two
/// things, and nothing of the user's: a network rule that lets the VM's
/// proxy through to the sandbox listener's port, and, run as root when the
/// kit is applied, the writing of each install's file.
///
/// An installed contract, like `RemoteCommand.script`: a sandbox keeps the
/// bytes it was made with (`sbx` does not look at the folder again), so the
/// text is marked and versioned, made from Swift constants, and pinned
/// (`SandboxKitTests`). Any change to the bytes raises `version`, which the
/// hook command sends in `X-Evlat-Kit`: the listener learns from traffic
/// which sandboxes run an older kit.
///
/// It names no agent: what is written where is the catalog's
/// (`Agents.sandboxKit`). The format is `sbx`'s, which calls it early
/// access; the shape below is the one measured to work (`schemaVersion`
/// "2", `setup.install`).
public struct SandboxKit: Equatable {
    /// Line 1 of `spec.yaml`: what makes the kit Evlat's.
    public static let marker = "# evlat-sandbox-kit"
    /// Line 2 (`# version N`) and the hook's `X-Evlat-Kit`; raised whenever
    /// a byte of the kit changes.
    public static let version = 1
    /// The sandbox listener's port. Fixed rather than following
    /// `EVLAT_PORT`: it is written into every kit and every sandbox made
    /// with one, so a run that moved it would leave them speaking to
    /// nothing — or to the main port.
    public static let defaultPort: UInt16 = LocalAPI.defaultPort + 1
    /// How the VM names this Mac. The sandbox's proxy takes it to
    /// `localhost`, which is why the rule below says `localhost`.
    public static let host = "host.docker.internal"
    /// The kit's name in `sbx`.
    public static let name = "evlat"
    /// The heredoc's end. No install's content may have it as a line.
    static let delimiter = "EVLAT_KIT"

    /// A file written inside the sandbox when the kit is applied: an
    /// absolute path in the VM, and its whole content.
    public struct Install: Equatable {
        public let path: String
        public let content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    /// A file of the kit's own folder, relative to it.
    public struct File: Equatable {
        public let path: String
        public let content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    public let port: UInt16
    public let installs: [Install]

    public init(port: UInt16 = defaultPort, installs: [Install]) {
        self.port = port
        self.installs = installs
    }

    /// What the kit's folder holds: `spec.yaml` alone, the installs' content
    /// carried inside it.
    public var files: [File] { [File(path: "spec.yaml", content: spec)] }

    /// `spec.yaml`. Every install is one `setup.install` step, a shell
    /// command run as root: make the folder, write the file whole. The
    /// content goes in a quoted heredoc, so nothing in it is expanded, and
    /// the YAML literal block keeps it byte for byte.
    public var spec: String {
        var text = """
            \(Self.marker)
            # version \(Self.version)
            #
            # Made by Evlat: it lets the agent in this sandbox tell Evlat on the
            # Mac what it is doing. Evlat writes this folder again as it needs to,
            # so an edit here is lost.
            schemaVersion: "2"
            kind: mixin
            name: \(Self.name)
            displayName: Evlat
            description: "Sends the agent's hook events to Evlat on the Mac"
            permissions:
              network:
                allow:
                  - localhost:\(port)
            setup:
              install:

            """
        for install in installs {
            text += "    - description: \"Write \(install.path)\"\n"
            text += "      command: |\n"
            for line in Self.command(writing: install).split(separator: "\n", omittingEmptySubsequences: false) {
                text += "        " + line + "\n"
            }
        }
        return text
    }

    /// The step that writes one install: its folder, then the file. Paths
    /// are single-quoted (`RemoteSettings.quoted`).
    static func command(writing install: Install) -> String {
        precondition(!install.content.split(separator: "\n").contains { $0 == Substring(delimiter) },
                     "an install's content must not end its heredoc")
        let folder = (install.path as NSString).deletingLastPathComponent
        return "mkdir -p \(RemoteSettings.quoted(folder)) && cat > \(RemoteSettings.quoted(install.path))"
            + " <<'\(delimiter)'\n" + install.content + "\n" + delimiter
    }
}
