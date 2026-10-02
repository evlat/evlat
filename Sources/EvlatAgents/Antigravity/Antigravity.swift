import Foundation
import EvlatCore

/// Antigravity: its app, its IDE and the `agy` CLI share one hook system
/// (`AntigravityHookAdapter`) and a hooks file of their own shape
/// (`AntigravityHooks`). Its CLI alone has a status line.
struct Antigravity: Agent {
    let id = AgentID("antigravity")

    /// The app's and the CLI's own folders — not the hooks file's:
    /// `~/.gemini` belongs to Gemini CLI as well.
    let presence = [".gemini/antigravity", ".gemini/antigravity-cli"]

    /// All five events it has (measured, CLI 1.2.14 and app 2.18.1). None
    /// asks the user anything, so an Antigravity row never waits. Its body
    /// names no event, so the command says it in a header. Its finish names
    /// no reply, only its transcript, which is read on this Mac.
    let hooks = HookChannel(
        paths: [RouteTable.installedPrefix + "/antigravity"],
        events: ["PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation", "Stop"],
        eventInHeader: true,
        canonical: AntigravityHookAdapter.canonical,
        finish: { json, roots in
            guard json["hook_event_name"] as? String == "Stop",
                  let path = json["transcriptPath"] as? String else { return nil }
            return AntigravityTranscript.lastReply(at: path, roots: roots)
        },
        finishRoots: AntigravityTranscript.roots)

    /// The hooks folder is shared by the app, the IDE and the CLI
    /// (documented; seen as `{}`) and its presence does not say Antigravity
    /// is installed, so the install makes it. The status line is the CLI's
    /// own settings — the app and the IDE have none — and the relay alone
    /// asks for the CLI's own line too (measured, `agy` 1.2.14). A server
    /// gets no relay: it has not been measured there.
    let integration = AgentIntegration.Parts(
        hooksFile: ".gemini/config/hooks.json",
        format: AntigravityHooksFormat(),
        opensHooksDirectory: true,
        relay: AgentIntegration.Relay(file: ".gemini/antigravity-cli/settings.json",
                                      requires: ".gemini/antigravity-cli", stacksWithDefault: true))

    /// Its `quota` holds two pools of the same two lengths: `gemini-*` and
    /// `3p-*` (the other vendors' models it offers). Only Gemini's is drawn
    /// — the bar has room for one more group of two windows
    /// (`UsageBlockModel.maxLines`) — so `3p-*` stays unrecognized. The
    /// group is named for that pool; "Gemini" also sorts after Claude and
    /// Codex (`Snapshot`'s order), so the bar's cap drops it first.
    /// Undocumented, so `.derived`.
    let statusLineUsage: StatusLineUsage? = StatusLineUsage(
        path: "/usage/antigravity", providerID: "antigravity-usage", group: "Gemini", fidelity: .derived,
        root: "quota",
        windows: [.init("gemini-5h", minutes: 300), .init("gemini-weekly", minutes: 10080)],
        reading: .remainingFraction)

    let approvals: (any ApprovalChannel)? = nil

    let display = AgentDisplay(nameKey: "source.antigravity")

    func providers(_ context: ProviderContext) -> [Provider] { [] }
}

/// Antigravity's name-keyed hooks file, as a `HooksFormat`.
struct AntigravityHooksFormat: HooksFormat {
    func state(of settings: [String: Any], hooks: HookChannel) -> HookSettings.State {
        AntigravityHooks.state(of: settings, hooks: hooks)
    }

    func installing(into settings: [String: Any], hooks: HookChannel) -> [String: Any] {
        AntigravityHooks.installing(into: settings, hooks: hooks)
    }

    func removing(from settings: [String: Any], hooks: HookChannel) -> [String: Any] {
        AntigravityHooks.removing(from: settings, hooks: hooks)
    }
}
