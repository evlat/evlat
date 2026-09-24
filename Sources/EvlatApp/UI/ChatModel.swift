import Foundation
import EvlatCore

/// What the balloon draws, and the one way out of it: a prompt.
///
/// Written by the controller from the chat's state (`ChatSession`) on each
/// refresh, field by field — a reply streams in at the refresh's pace and
/// nothing else in the balloon should move with it. Observed by `ChatView`
/// alone, `DetailModel`'s pattern.
@MainActor
final class ChatModel: ObservableObject {
    /// Which side the bar is on: the tail points at it.
    @Published var edge: BarPanel.Edge = .right
    @Published private(set) var messages: [ChatSession.Message] = []
    @Published private(set) var isRunning = false
    @Published private(set) var failure: ChatSession.Failure?
    /// No `claude` was found: the balloon says so instead of offering a line.
    @Published var claudeMissing = false
    /// The line being typed.
    @Published var draft = ""
    /// Counts the balloon's openings; a change takes the field's focus.
    @Published private(set) var openings = 0

    /// The prompt, trimmed. The controller turns it into `Action.send`.
    var onSend: ((String) -> Void)?

    /// Three prompts a bare `claude -p` can answer from its own folder,
    /// asking for no folder the system guards (Downloads, Desktop) and no
    /// screen — those would put a macOS permission prompt in front of the
    /// user (Kapsam Dışı). Sent as they are.
    static let suggestionKeys = ["chat.suggestion.capabilities", "chat.suggestion.memory",
                                 "chat.suggestion.disk"]
    /// Every key the balloon asks for, but the failures'.
    static let keys = ["chat.placeholder", "chat.hint", "chat.missing", "chat.working"] + suggestionKeys

    /// A failure's line. A switch, so a new reason does not compile without one.
    nonisolated static func failureKey(_ failure: ChatSession.Failure) -> String {
        switch failure {
        case .noBinary: return "chat.failure.noBinary"
        case .launch: return "chat.failure.launch"
        case .exited: return "chat.failure.exited"
        case .result: return "chat.failure.result"
        case .interrupted: return "chat.failure.interrupted"
        }
    }

    /// The process's own words under the line, when it left any.
    nonisolated static func failureDetail(_ failure: ChatSession.Failure) -> String? {
        switch failure {
        case .launch(let detail): return detail
        case .exited(_, let detail): return detail
        case .result(_, let text): return text
        case .noBinary, .interrupted: return nil
        }
    }

    /// The chat's state; `nil` is a balloon with nothing sent yet. Only what
    /// changed is written.
    func update(from chat: ChatSession?) {
        let messages = chat?.messages ?? []
        if self.messages != messages { self.messages = messages }
        let running = chat?.isRunning ?? false
        if isRunning != running { isRunning = running }
        let failure = chat?.failure
        if self.failure != failure { self.failure = failure }
    }

    /// Sends a prompt: `false` for a blank line, while a turn runs, or with
    /// no `claude` to send it to.
    @discardableResult
    func submit(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, !claudeMissing, let onSend else { return false }
        draft = ""
        onSend(prompt)
        return true
    }

    func opened() {
        openings &+= 1
    }
}
