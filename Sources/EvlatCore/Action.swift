import Foundation

/// The reverse direction of the seam (`AGENTS.md` → Architecture): what the
/// user asks of a source, where a `Signal` is what a source tells the user.
/// Built with its first real consumer, the chat.
///
/// The core decides, the shell carries it out: the chat store turns an
/// action into a `ChatSession` transition and, when that says so, a process
/// started, signalled or answered.
public enum Action: Equatable {
    /// A prompt to a chat, with the files dropped on it.
    case send(chat: String, text: String, attachments: [String])
    /// An answer to a permission request.
    case answer(request: String, decision: Decision)
    /// End the chat's running turn.
    case stop(chat: String)

    /// The permission card's three buttons (`R6`).
    public enum Decision: String, Equatable {
        case allow
        case deny
        /// Allow, and keep allowing the same kind of call in this chat.
        case allowAlways
    }
}
