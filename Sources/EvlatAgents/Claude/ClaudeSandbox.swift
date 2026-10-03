import Foundation
import EvlatCore

/// Claude Code inside a Docker sandbox: its hooks go in a managed settings
/// file of Evlat's own, written as root (`SandboxInstall`).
///
/// Not `~/.claude/settings.json`, which `sbx` writes itself
/// (`permissions.defaultMode: bypassPermissions`), and not
/// `managed-settings.json`, which is not Evlat's either: Claude Code also
/// reads every `*.json` in `managed-settings.d` (2.1.280, measured with the
/// folder alone), so Evlat writes and removes one file there and touches
/// nothing else.
enum ClaudeSandbox {
    static let managedSettingsPath = "/etc/claude-code/managed-settings.d/evlat.json"

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
}

extension Agents {
    /// The agent whose sandboxes Evlat sets up (`sbx ls --json`'s `agent`
    /// is its id's word). Claude Code only so far; another agent's hooks in
    /// a sandbox are not measured.
    public static let sandboxAgent: AgentID = Claude().id

    /// What Evlat writes into a running sandbox of `sandboxAgent`'s, on the
    /// sandbox listener's `port`: the one file and the rule
    /// (`SandboxInstall.install(sandbox:)`).
    public static func sandboxInstall(port: UInt16 = SandboxInstall.defaultPort) -> SandboxInstall {
        SandboxInstall(port: port, path: ClaudeSandbox.managedSettingsPath,
                       content: ClaudeSandbox.managedSettings(port: port))
    }
}
