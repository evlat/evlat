import Foundation
import EvlatCore

/// OpenCode's permission, held on the card. OpenCode runs no hook command
/// that could be installed for it, so the request comes from the plugin
/// itself (`OpenCodePlugin`): it opens a second, held request on this path
/// when a permission is asked, and applies the answer through OpenCode's own
/// API from inside the process. `installs` is empty for that reason — the
/// unit is the plugin file, not a group in a settings file.
///
/// Measured (1.18.34, 1.19.0, 2.0.22, 2.0.27, the desktop app's server):
///
/// - A request held 370 s is answered and applied; OpenCode does not expire
///   the permission meanwhile. Answering from the plugin closes the TUI's
///   own dialog.
/// - An answer from anywhere else (the TUI, the desktop app) fires
///   `permission.replied`, which is how the plugin learns to let go; an
///   interrupt with a permission pending fires none, so a card outliving its
///   turn is `ApprovalHook.resolves`' to drop.
/// - Allow once is `once` and Deny is `reject`; `always` would write a rule
///   into the user's OpenCode, which no press on the bar ever does.
///
/// The plugin applies only the two answers below. `{}`, a refusal, a closed
/// connection and the time running out are no decision: OpenCode's own
/// dialog stays and decides, as with Evlat closed.
struct OpenCodeApprovals: ApprovalChannel {
    /// Under the approvals' prefix, one path per agent.
    static let route = ApprovalHook.path + "/opencode"

    /// Ten minutes, as Claude's: the plugin's request is bounded by it.
    static let timeoutSeconds = 600

    /// The answer is one object with one key, and two values the plugin
    /// reads. Anything else in a body is not an answer.
    static let field = "decision"
    static let allow = "once"
    static let deny = "reject"

    /// A question is answered in OpenCode: the card has no typed way to
    /// give it (1.x offers none from a plugin), so it is a wait for words.
    func isQuestion(_ tool: String) -> Bool { tool == AskQuestion.tool }

    /// The plugin's body, through the adapter and read as Claude's is: the
    /// shapes are the same once canonical. No question, rule or folder is
    /// kept — the answer can carry none — and a question is refused here
    /// as well, so a card never offers a bare Allow for one.
    func request(json: [String: Any]) -> HeldRequest? {
        guard let read = HeldRequest(json: OpenCodeHookAdapter.canonical(json), token: nil),
              !isQuestion(read.tool) else { return nil }
        return HeldRequest(id: read.id, token: nil, tool: read.tool, subject: read.subject, command: read.command,
                           sessionID: read.sessionID, cwd: read.cwd, subagent: read.subagent)
    }

    /// Allow once or Deny; a question's answer is none.
    func body(_ decision: ChatDecision) -> String {
        let word: String
        switch decision {
        case .allow, .allowForSession: word = Self.allow
        case .deny: word = Self.deny
        case .answer: return "{}"
        }
        let data = (try? JSONSerialization.data(withJSONObject: [Self.field: word], options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    let path = Self.route
    let timeout = Self.timeoutSeconds
    let installs: Set<HookTarget> = []
}
