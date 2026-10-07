import Foundation
import EvlatCore

/// Claude Code as the chat bubble's backend: a `claude -p` process per turn
/// (`ClaudeInvocation`), its stream-json stdout (`ChatStream`), and its
/// permissions through an inline `PermissionRequest` hook posted to the
/// listener's socket (`PermissionHook`) — one way.
struct ClaudeChat: ChatBackend {
    let id = AgentID("claude")

    let executable = "claude"

    let modes = PermissionMode.allCases.map(\.chatMode)

    let offered = PermissionMode.offered.map(\.chatMode)

    let standardMode = PermissionMode.standard.chatMode

    /// Stored before each backend had its own key; it cannot move.
    let modeKey = "chat.permissionMode"

    /// Written before each backend had its own file; it cannot move, and an
    /// older build reads and rewrites it whole.
    let indexFile = "chats.json"

    let caps = ChatCapabilities(asks: true, alwaysOption: .rules, resume: true, memory: true, transport: .oneWay)

    /// SIGINT, the documented way ("To end the turn instead, send SIGINT").
    let stopPlan = ChatStopPlan.signal

    /// Answered 200 with no redirect (2026-10-04).
    let installPage = URL(string: "https://claude.com/product/claude-code")

    func turn(_ spec: TurnSpec, ctx: TurnContext) -> TurnLaunch {
        ClaudeInvocation.turn(chatID: spec.chatID, sessionID: spec.sessionID, resume: spec.resume,
                              prompt: spec.prompt, attachments: spec.attachments, directory: spec.directory,
                              addDirectories: spec.addDirectories, allowedTools: spec.allowedTools,
                              mode: PermissionMode(rawValue: spec.mode.id) ?? .standard)
            .asking(PermissionHook.Endpoint(socket: ctx.socket, token: ctx.token), memoryDirectory: ctx.memoryDirectory)
            .launch
    }

    func parser(for spec: TurnSpec) -> any ChatParser { ChatStream() }

    /// The hook's body, as the card holds it. A question's input is not
    /// carried: the bubble's card answers allow or deny.
    func request(json: [String: Any], token: String) -> ChatRequest? {
        guard let held = HeldRequest(json: json, token: token) else { return nil }
        return ChatRequest(id: held.id, token: held.token, tool: held.tool, subject: held.subject,
                           command: held.command, rules: held.rules, directories: held.directories,
                           replyTarget: .listener)
    }

    func encode(_ decision: ChatDecision, for request: ChatRequest) -> ChatReply {
        .http(Data(PermissionHook.body(decision).utf8))
    }
}
