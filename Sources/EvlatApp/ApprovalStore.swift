import Foundation
import EvlatCore

/// Terminal sessions' permission requests held for the bar
/// (`ApprovalHook`): asked, answered on the card, or let go when the
/// terminal answered first.
///
/// Letting go is `{}` — no decision — so a request Evlat drops is never an
/// allow or a deny; Claude Code's own dialog decides. Main queue.
@MainActor
final class ApprovalStore {
    /// Held, oldest first. Serialized per actor by Claude Code, so a session
    /// has one per agent at most.
    private(set) var pending: [PermissionHook.Request] = []

    /// Writes an answer to the held connection (`HookListener.answer`).
    var respond: (String, LocalAPI.Response) -> Void = { _, _ in }
    var onChange: () -> Void = {}

    static let released = LocalAPI.Response(status: .ok, body: "{}")

    func asked(_ request: PermissionHook.Request) {
        for older in pending where ApprovalHook.supersedes(request, older) { release(older.id) }
        pending.append(request)
        onChange()
    }

    /// Any hook event: a request it shows answered elsewhere is let go.
    func heard(_ event: HookEvent) {
        let answered = pending.filter { ApprovalHook.resolves($0, by: event) }
        guard !answered.isEmpty else { return }
        answered.forEach { release($0.id) }
        onChange()
    }

    /// The connection closed first: "No" or Esc in the terminal, or the
    /// hook's time ran out.
    func abandoned(_ id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        onChange()
    }

    /// The user's press. `false` when the request is no longer held: a press
    /// on a card that went stale sends nothing.
    @discardableResult
    func answer(_ id: String, allow: Bool) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        pending.removeAll { $0.id == id }
        // Allow once: no rule, no folder, no mode is ever kept from the bar.
        let decision: PermissionHook.Decision = allow ? .allow(rules: [], directories: []) : .deny(interrupt: false)
        respond(id, LocalAPI.Response(status: .ok, body: PermissionHook.body(decision)))
        onChange()
        return true
    }

    /// The request a session's card speaks for: the oldest held.
    func request(forSession session: String) -> PermissionHook.Request? {
        pending.first { $0.sessionID == session }
    }

    private func release(_ id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        respond(id, Self.released)
    }
}
