import Foundation
import EvlatCore

/// OpenCode. It has no hooks file to merge into and no documented event
/// stream Evlat can read from outside: it loads a plugin from a folder it
/// scans, so the unit is one file of Evlat's own (`OpenCodePlugin`) that
/// posts what a session is doing to Evlat's socket, and
/// `OpenCodeHookAdapter` says what that means.
///
/// The plugin runs inside OpenCode's own process, wherever that is — a
/// terminal's, the desktop app's, or the shared background service 2.x starts
/// — and one file serves both version lines, which name their events
/// differently.
struct OpenCode: Agent {
    let id = AgentID("opencode")

    /// Its config, data and per-project folders, any of which says it is
    /// here; the plugin folder itself is made by the install.
    let presence = [".config/opencode", ".local/share/opencode", ".opencode"]

    let hooks = HookChannel(
        paths: [OpenCodePlugin.route],
        events: OpenCodeHookAdapter.events,
        canonical: OpenCodeHookAdapter.canonical)

    /// The plugin file, in a folder OpenCode scans on every start; the folder
    /// is made only for an OpenCode that is on this Mac.
    let integration = AgentIntegration.Parts.ownedFile(
        .init(file: OpenCodePlugin.file, opensDirectory: true))

    /// OpenCode reports no quota.
    let statusLineUsage: StatusLineUsage? = nil

    let approvals: (any ApprovalChannel)? = nil

    let display = AgentDisplay(nameKey: "source.opencode", outline: Self.outline)

    /// The lines the events were measured on (1.18, 1.19, 2.0): OpenCode's
    /// plugin events are not a published contract and it releases often.
    let measuredVersions = ["1.18", "1.19", "2.0"]

    func providers(_ context: ProviderContext) -> [Provider] { [] }
}
