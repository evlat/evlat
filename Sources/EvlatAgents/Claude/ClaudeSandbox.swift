import Foundation
import EvlatCore

/// Claude Code inside a Docker sandbox: its hooks go in the managed
/// settings file, written by the kit (`SandboxKit`) as root.
///
/// Not `~/.claude/settings.json`: `sbx` writes its own there
/// (`permissions.defaultMode: bypassPermissions`), and a kit's file would
/// replace it. A Claude sandbox made without the kit has no
/// `/etc/claude-code` (measured), so this file is nobody else's.
enum ClaudeSandbox {
    static let managedSettingsPath = "/etc/claude-code/managed-settings.json"

    /// The same events the Mac installs, each with the sandbox's command,
    /// in the shape `HookSettings` writes. Keys sorted, so the bytes are
    /// the same on every run and can be pinned.
    static func managedSettings(port: UInt16) -> String {
        let hooks = Claude().hooks
        let ours: [String: Any] = ["hooks": [[
            "type": "command",
            "command": LocalAPI.installedHookCommand(for: hooks, endpoint: .sandbox(port: port)),
            "timeout": 5,
        ]]]
        let settings: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: hooks.events.map { ($0, [ours]) })]
        // Plain dictionaries of strings and numbers: serialising cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: settings,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func install(port: UInt16) -> SandboxKit.Install {
        SandboxKit.Install(path: managedSettingsPath, content: managedSettings(port: port))
    }
}

extension Agents {
    /// The kit for Docker sandboxes, on the sandbox listener's `port`: what
    /// each agent that runs in one needs written there. Claude Code only so
    /// far; another agent's hooks in a sandbox are not measured.
    public static func sandboxKit(port: UInt16 = SandboxKit.defaultPort) -> SandboxKit {
        SandboxKit(port: port, installs: [ClaudeSandbox.install(port: port)])
    }
}
