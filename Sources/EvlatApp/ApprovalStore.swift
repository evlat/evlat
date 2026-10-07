import Foundation
import EvlatCore

/// Terminal sessions' permission requests held for the bar
/// (`ApprovalHook`): asked, answered on the card, or let go when the
/// terminal answered first. One store for this Mac and every machine: each
/// request carries the agent that asked (`HeldRequest.source`) and the
/// machine whose listener heard it (`HeldRequest.machine`), and those
/// decide what answers it, which card shows it and where the answer goes.
///
/// Letting go is `{}` — no decision — so a request Evlat drops is never an
/// allow or a deny; the agent's own dialog decides. Main queue.
@MainActor
final class ApprovalStore {
    /// Held, oldest first. Serialized per actor by Claude Code, so a session
    /// has one per agent at most.
    private(set) var pending: [HeldRequest] = []
    /// A held question's answers so far (`AgentQuestion.Draft`), by request:
    /// they go with the request, however it goes.
    private var drafts: [String: AgentQuestion.Draft] = [:]

    /// Writes an answer to the held connection, on the listener that heard
    /// the request: this Mac's, or its machine's (`HookListener.answer`).
    var respond: (HeldRequest, LocalAPI.Response) -> Void = { _, _ in }
    var onChange: () -> Void = {}

    static let released = LocalAPI.Response(status: .ok, body: "{}")

    /// Where an answer's body is looked up: the asking agent's channel
    /// (`ApprovalChannel.body`).
    private let agents: [any Agent]

    init(agents: [any Agent]) {
        self.agents = agents
    }

    /// The answer, in the format of the agent that asked. One that names no
    /// agent this build knows is answered `{}`: no decision.
    private func body(_ decision: ChatDecision, for request: HeldRequest) -> String {
        request.source.flatMap { agents[id: $0]?.approvals?.body(decision) } ?? "{}"
    }

    func asked(_ request: HeldRequest) {
        for older in pending where ApprovalHook.supersedes(request, older) { release(older.id) }
        pending.append(request)
        if let questions = request.questions { drafts[request.id] = AgentQuestion.Draft(questions: questions) }
        onChange()
    }

    /// Any hook event, heard on `machine`'s listener (`nil`: this Mac's): a
    /// request of that machine it shows answered elsewhere is let go.
    func heard(_ event: HookEvent, machine: String?) {
        let answered = pending.filter { ApprovalHook.resolves($0, by: event, machine: machine) }
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
        let decision: ChatDecision = allow ? .allow(rules: [], directories: []) : .deny(interrupt: false)
        respond(request, LocalAPI.Response(status: .ok, body: body(decision, for: request)))
        onChange()
        return true
    }

    /// A held question's answers so far.
    func draft(_ id: String) -> AgentQuestion.Draft? { drafts[id] }

    /// An option pressed on the card. `false` when the request is no longer
    /// held.
    @discardableResult
    func choose(_ id: String, option: Int) -> Bool { edit(id) { $0.choose(option) } }

    /// A written answer ("Other…").
    @discardableResult
    func write(_ id: String, _ text: String) -> Bool { edit(id) { $0.write(text) } }

    /// Next or Send: a multi-select question as picked, or one come back to as answered.
    @discardableResult
    func commit(_ id: String) -> Bool { edit(id) { $0.commit() } }

    /// Back to the question before.
    @discardableResult
    func back(_ id: String) -> Bool { edit(id) { $0.back() } }

    /// Changes the draft, and sends it once every question is answered.
    private func edit(_ id: String, _ change: (inout AgentQuestion.Draft) -> Void) -> Bool {
        guard var draft = drafts[id], let request = pending.first(where: { $0.id == id }),
              let input = request.input else { return false }
        change(&draft)
        if let answers = draft.answers {
            pending.removeAll { $0.id == id }
            drafts[id] = nil
            respond(request, LocalAPI.Response(status: .ok,
                                               body: body(.answer(input: input, answers: answers), for: request)))
        } else {
            drafts[id] = draft
        }
        onChange()
        return true
    }

    /// The held requests `which` picks let go: the agent that asked was
    /// switched off, on this Mac or on its machine, so no card will answer
    /// them. `{}`, as for one answered elsewhere.
    func release(where which: (HeldRequest) -> Bool) {
        let going = pending.filter(which)
        guard !going.isEmpty else { return }
        going.map(\.id).forEach(release)
        onChange()
    }

    /// The request a session's card speaks for: the oldest held from that
    /// session on that machine (`nil`: this Mac). A machine's request never
    /// shows on this Mac's row of the same id, nor the other way round.
    func request(forSession session: String, machine: String?) -> HeldRequest? {
        pending.first { $0.sessionID == session && $0.machine == machine }
    }

    private func release(_ id: String) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        drafts[id] = nil
        respond(request, Self.released)
    }
}
