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
    /// A held question's answers so far (`AskQuestion.Draft`), by request:
    /// they go with the request, however it goes.
    private var drafts: [String: AskQuestion.Draft] = [:]

    /// Writes an answer to the held connection (`HookListener.answer`).
    var respond: (String, LocalAPI.Response) -> Void = { _, _ in }
    var onChange: () -> Void = {}

    static let released = LocalAPI.Response(status: .ok, body: "{}")

    func asked(_ request: PermissionHook.Request) {
        for older in pending where ApprovalHook.supersedes(request, older) { release(older.id) }
        pending.append(request)
        if let questions = request.questions { drafts[request.id] = AskQuestion.Draft(questions: questions) }
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
        drafts[id] = nil
        onChange()
    }

    /// The user's press. `false` when the request is no longer held: a press
    /// on a card that went stale sends nothing. A question is not allowed
    /// bare — that answers nothing (`AskQuestion`) — only denied or answered.
    @discardableResult
    func answer(_ id: String, allow: Bool) -> Bool {
        guard let request = pending.first(where: { $0.id == id }), !(allow && request.questions != nil) else {
            return false
        }
        pending.removeAll { $0.id == id }
        drafts[id] = nil
        // Allow once: no rule, no folder, no mode is ever kept from the bar.
        let decision: PermissionHook.Decision = allow ? .allow(rules: [], directories: []) : .deny(interrupt: false)
        respond(id, LocalAPI.Response(status: .ok, body: PermissionHook.body(decision)))
        onChange()
        return true
    }

    /// A held question's answers so far.
    func draft(_ id: String) -> AskQuestion.Draft? { drafts[id] }

    /// An option pressed on the card. `false` when the request is no longer
    /// held.
    @discardableResult
    func choose(_ id: String, option: Int) -> Bool { edit(id) { $0.choose(option) } }

    /// A written answer ("Other…").
    @discardableResult
    func write(_ id: String, _ text: String) -> Bool { edit(id) { $0.write(text) } }

    /// A multi-select question's Next or Send.
    @discardableResult
    func commit(_ id: String) -> Bool { edit(id) { $0.commit() } }

    /// Back to the question before.
    @discardableResult
    func back(_ id: String) -> Bool { edit(id) { $0.back() } }

    /// Changes the draft, and sends it once every question is answered.
    private func edit(_ id: String, _ change: (inout AskQuestion.Draft) -> Void) -> Bool {
        guard var draft = drafts[id], let request = pending.first(where: { $0.id == id }),
              let input = request.input else { return false }
        change(&draft)
        if let answers = draft.answers {
            pending.removeAll { $0.id == id }
            drafts[id] = nil
            respond(id, LocalAPI.Response(status: .ok,
                                          body: PermissionHook.body(.answer(input: input, answers: answers))))
        } else {
            drafts[id] = draft
        }
        onChange()
        return true
    }

    /// Every held request let go: the agent that asked was switched off,
    /// so no card will answer it. `{}`, as for one answered elsewhere.
    func releaseAll() {
        guard !pending.isEmpty else { return }
        pending.map(\.id).forEach(release)
        onChange()
    }

    /// The request a session's card speaks for: the oldest held.
    func request(forSession session: String) -> PermissionHook.Request? {
        pending.first { $0.sessionID == session }
    }

    private func release(_ id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        drafts[id] = nil
        respond(id, Self.released)
    }
}
