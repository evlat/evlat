import Foundation
import EvlatCore

/// The Codex CLI as the chat bubble's backend: `codex app-server` per turn,
/// JSON-RPC over its stdio (`AppServerStream`) — duplex. The server asks its
/// permissions on the same channel it streams on, and Stop is a request on
/// that channel too: SIGINT would end the server before it says the turn
/// ended.
///
/// The protocol was measured on codex-cli 0.156.1, whose help calls the
/// app-server "experimental"; a turn reporting another version is said in
/// Settings and the diagnostics (`measuredVersion`).
struct CodexChat: ChatBackend {
    let id = AgentID("codex")

    let executable = "codex"

    let modes = CodexMode.allCases.map(\.chatMode)

    let offered = CodexMode.offered.map(\.chatMode)

    let standardMode = CodexMode.standard.chatMode

    /// "Always" is this command again for the rest of the session
    /// (`acceptForSession`, measured: another command asked again). Codex
    /// keeps its own memory under its home, so there is no shared folder.
    let caps = ChatCapabilities(asks: true, alwaysOption: .thisCommand, resume: true, memory: false,
                                transport: .duplex)

    /// `turn/interrupt`: measured, `turn/completed` with `interrupted` came
    /// 40 ms later.
    let stopPlan = ChatStopPlan.inBand

    let measuredVersion: String? = AppServerStream.measuredVersion

    let noteKey: String? = "settings.chat.backend.codex.note"

    /// The server alone; everything the turn is — its thread, its mode, its
    /// prompt — goes over stdin, the first line now and the rest as the
    /// server answers (`AppServerStream`). The task variable reaches the
    /// user's own hooks, which the server runs (measured): the turn's events
    /// are left off the bar as an Evlat errand.
    func turn(_ spec: TurnSpec, ctx: TurnContext) -> TurnLaunch {
        TurnLaunch(arguments: ["app-server"], input: [AppServerStream.initialize],
                   environment: [TurnLaunch.taskVariable: spec.chatID], directory: spec.directory)
    }

    func parser(for spec: TurnSpec) -> any ChatParser { AppServerStream(spec: spec) }

    func encode(_ decision: ChatDecision, for request: ChatRequest) -> ChatReply {
        .line(AppServerStream.answer(decision, to: request.callID))
    }
}

/// How much a Codex chat's turn does without asking: its approval policy and
/// its sandbox, paired (`thread/start`, `thread/resume`).
enum CodexMode: String, CaseIterable {
    /// Reads, and asks before any change (measured: a write in the
    /// read-only sandbox came back as a request).
    case readOnly
    /// Writes in the chat's folder; what reaches outside it asks.
    case workspace
    /// No sandbox and nothing asked. Asked before it is picked, for one
    /// chat; never a default.
    case fullAccess

    static let standard: CodexMode = .workspace

    /// The new chats' defaults, the recommended one first.
    static let offered: [CodexMode] = [.workspace, .readOnly]

    /// `AskForApproval`.
    var approvalPolicy: String { self == .fullAccess ? "never" : "on-request" }

    /// `SandboxMode`.
    var sandbox: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspace: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    var chatMode: ChatMode {
        ChatMode(id: rawValue, nameKey: "chat.mode.codex." + rawValue,
                 asksBeforePicking: self == .fullAccess, mayBeDefault: self != .fullAccess)
    }
}
