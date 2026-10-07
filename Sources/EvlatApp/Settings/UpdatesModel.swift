import Foundation
import EvlatCore
import EvlatAgents

/// The update window's state, apart from its view: what an older copy left
/// that this one cannot hear — this Mac's agents and the servers — each with
/// its one press, and "Update all".
///
/// It installs nothing of its own. A row's press is its card's in Settings:
/// this Mac's through the setup rows (`SetupModel.perform`, so
/// `AgentIntegration`), a server's through its machine's job
/// (`RemoteMachinesModel.update`, `RemoteSettings.Change.agent`). The rules
/// that say what is old are the cards' too; this model only keeps which rows
/// it showed and what their presses left.
///
/// Automatic updates (`updates.automatic`) run through it too, unseen: at
/// launch this Mac's old agents (`keepAgentsCurrent`), and each server as it
/// connects (`keepMachineCurrent`), with the automatic write
/// (`AgentIntegration.automaticScope`). The window is asked for
/// (`onNeedsUser`) only when something is left to the user
/// (`SetupTrigger.opensResults`), and opens on those results.
///
/// **Main queue only**, like the models behind `Host`.
@MainActor
final class UpdatesModel: ObservableObject {
    /// What the window needs from the app (`AppController.updatesHost`).
    struct Host {
        /// This Mac's cards as last read (`SetupModel.rows`).
        var agentRows: () -> [SetupRow]
        /// An agent card's press (`SetupModel.perform`); its row is read
        /// again after.
        var updateAgent: (AgentID) -> Void
        var machines: () -> [Machine]
        /// A machine's press: `false` when it did not start (no reading,
        /// another job there). `done` hears it once, on the main queue.
        var updateMachine: (String, @escaping (MachineResult) -> Void) -> Bool
        /// Reads them again from their files: at each opening. A press reads
        /// its own row again.
        var reloadAgents: () -> Void = {}
        /// `updates.automatic` as written, `nil` while never written; and
        /// its writer.
        var automatic: () -> Bool? = { nil }
        var setAutomatic: (Bool) -> Void = { _ in }
        /// Automatic updates' write for an agent here
        /// (`AgentIntegration.keepCurrent`); its row is read again after.
        var keepAgent: (AgentID) -> Void = { _ in }
        /// Automatic updates' job for a machine: `updateMachine`'s, with
        /// the automatic write for each agent.
        var keepMachine: (String, @escaping (MachineResult) -> Void) -> Bool = { _, _ in false }
        /// An agent switched on here still holds the bytes from before the
        /// socket (`AgentIntegration.predatesSocket`): the paragraph says
        /// why they went silent.
        var predatesSocket: () -> Bool = { false }
    }

    /// A machine as the window reads it: its tunnel, and from its newest
    /// reading what an older copy wrote there.
    struct Machine: Equatable {
        let id: String
        let name: String
        let state: RemoteTunnel.State?
        /// The agents switched on there whose hooks are old
        /// (`RemoteMachinesModel.outdatedAgents`); `nil` before a reading.
        let outdated: [AgentID]?
        /// Its `evlat` command is an older copy's.
        var commandOld = false
    }

    /// What a machine's press left.
    struct MachineResult: Equatable {
        /// The job's own line when something was refused; `nil` when all
        /// went in.
        let failure: String?
        /// The agents it wrote.
        let agents: [AgentID]
    }

    enum Tone: Equatable { case neutral, step, trouble }

    /// One line under a row's name.
    struct Line: Equatable, Hashable {
        let text: String
        let tone: Tone
    }

    enum State: Equatable {
        case needsUpdate
        case updating
        /// Written; the lines say what follows (a step, the bar's cards).
        case updated
        /// Refused; the line says why. "Try again".
        case failed(String)
        /// Nothing old there (any more): updated elsewhere, or a machine that
        /// connected and read current.
        case current
        /// A machine whose tunnel is not up yet: read once it connects.
        case notConnected
        /// Connected, its reading not in yet.
        case checking
        /// A machine whose channel could not be made: the short reason, and
        /// what to do about it behind "Why?".
        case channelFailed(String, advice: String?)
    }

    enum Kind: Equatable, Hashable {
        case agent(AgentID), machine(String)
    }

    struct Row: Identifiable, Equatable {
        let kind: Kind
        let name: String
        let state: State
        let lines: [Line]

        var id: Kind { kind }

        /// "Update" or "Try again"; `nil` when the row has nothing to press.
        var action: Action? {
            switch state {
            case .needsUpdate: return .update
            case .failed: return .retry
            default: return nil
            }
        }

        /// What "Why?" opens.
        var advice: String? {
            if case .channelFailed(_, let advice) = state { return advice }
            return nil
        }
    }

    enum Action: Equatable { case update, retry }

    @Published private(set) var agents: [Row] = []
    @Published private(set) var machines: [Row] = []
    /// The rows whose "Why?" is open.
    @Published private(set) var expanded: Set<Kind> = []
    /// The row whose press runs now; every button waits for it.
    @Published private(set) var running: Kind?
    /// "Update all" was pressed: the footer says Done from then on.
    @Published private(set) var pressedAll = false
    /// The footer's box, "Keep these up to date automatically": checked
    /// when the window opens.
    @Published private(set) var keepCurrent = true
    /// The window shows what automatic updates did, not what is old.
    @Published private(set) var results = false

    private let host: Host
    private(set) var lang: String
    /// Later and Done: the window closes (`AppController.openUpdates`).
    var close: () -> Void = {}
    /// Each opening, once its rows are chosen: the window places itself
    /// afresh (`UpdatesWindow.make`).
    var onStart: () -> Void = {}
    /// Which rows the window shows, fixed when it opened: a row that turns
    /// green stays, to say so.
    private var agentIDs: [AgentID] = []
    private var machineIDs: [String] = []
    /// What a press left, until the next press of that row.
    private var pressed: [Kind: State] = [:]
    /// The rows a press updated, for their lines.
    private var updatedAgents: [Kind: [AgentID]] = [:]
    /// "Update all"'s rows still to run, in order.
    private var queue: [Kind] = []
    private var pressedAny = false
    /// The box is the setting itself (automatic updates were on when the
    /// window opened, or "Update all" turned them on): it writes at once.
    /// Otherwise it is a choice "Update all" writes.
    private(set) var boxIsSwitch = false
    /// The paragraph's cause, read at each opening.
    private var socketCause = false
    /// The rows automatic updates run, with their write.
    private var automaticKinds: Set<Kind> = []
    /// The rows already reported (`onNeedsUser`): each is told once.
    private var reported: Set<Kind> = []
    /// The next opening shows the results as they are (`opened`).
    private var holdsResults = false
    /// Automatic updates left something to the user: the window opens on
    /// the results (`AppController`).
    var onNeedsUser: () -> Void = {}
    /// The window is on screen: a server's automatic update joins what it
    /// shows rather than starting a set of its own.
    var isShown: () -> Bool = { false }

    init(host: Host, lang: String = L10n.language) {
        self.host = host
        self.lang = lang
    }

    func t(_ key: String, _ values: [String: String] = [:]) -> String {
        L10n.t(key, values, in: lang)
    }

    // MARK: - Opening

    /// The window opens: its rows are chosen afresh — this Mac's agents
    /// switched on whose hooks an older copy wrote (the `hooksOutdated`
    /// rule: a usage line alone is not asked for), and every machine that
    /// is not known to be current (not connected yet, its channel refused,
    /// or old) — and every earlier press forgotten but a machine's job still
    /// running, which keeps its row and holds the buttons until it answers.
    func start() {
        host.reloadAgents()
        agentIDs = outdatedAgents()
        machineIDs = host.machines().filter { machine in
            Self.state(of: machine, in: lang) != .current || running == .machine(machine.id)
        }.map(\.id)
        pressed = running.map { [$0: .updating] } ?? [:]
        updatedAgents = [:]
        queue = []
        expanded = []
        pressedAll = false
        pressedAny = false
        results = false
        holdsResults = false
        reported = []
        automaticKinds = []
        // Checked unless the user turned automatic updates off.
        let stored = host.automatic()
        boxIsSwitch = stored == true
        keepCurrent = stored ?? true
        socketCause = host.predatesSocket()
        refresh()
        onStart()
    }

    /// The window's opening: afresh, or on automatic updates' results when
    /// they asked for it.
    func opened() {
        guard holdsResults else { return start() }
        holdsResults = false
        refresh()
        onStart()
    }

    /// This Mac's agents switched on whose hooks an older copy wrote (the
    /// `hooksOutdated` rule: a usage line alone is not asked for).
    private func outdatedAgents() -> [AgentID] {
        host.agentRows().compactMap { row in
            guard let source = row.item.agent, row.enabled, row.hooksStatus == .outdated else { return nil }
            return source
        }
    }

    // MARK: - Automatic updates

    /// A new set of results, nothing in it yet but a machine's job still
    /// running, which joins it and reports when it answers.
    private func beginResults() {
        agentIDs = []
        machineIDs = []
        if case .machine(let id)? = running { machineIDs = [id] }
        pressed = running.map { [$0: .updating] } ?? [:]
        updatedAgents = [:]
        queue = []
        expanded = []
        automaticKinds = []
        results = true
        pressedAll = true
        pressedAny = true
        reported = []
        holdsResults = false
        boxIsSwitch = true
        keepCurrent = host.automatic() ?? false
    }

    /// At launch: this Mac's old agents, each with the automatic write.
    func keepAgentsCurrent() {
        guard running == nil else { return }
        host.reloadAgents()
        beginResults()
        agentIDs = outdatedAgents()
        let kinds = agentIDs.map(Kind.agent)
        automaticKinds.formUnion(kinds)
        queue = kinds
        refresh()
        next()
        report()
    }

    /// A server connected and read old: its automatic update, into the
    /// window's rows while it is shown, into the results being made, else
    /// a set of its own. `true` when its job runs or waits its turn.
    @discardableResult
    func keepMachineCurrent(_ id: String) -> Bool {
        let kind = Kind.machine(id)
        guard running != kind, !queue.contains(kind) else { return true }
        if !isShown(), !results || (running == nil && queue.isEmpty) { beginResults() }
        if !machineIDs.contains(id) { machineIDs.append(id) }
        automaticKinds.insert(kind)
        pressed[kind] = nil
        queue.append(kind)
        refresh()
        next()
        let going = running == kind || queue.contains(kind)
        if !going, pressed[kind] == nil { machineIDs.removeAll { $0 == id } }
        refresh()
        report()
        return going
    }

    /// What automatic updates left to the user, asked for once nothing
    /// runs: each row needing the user is told once.
    private func report() {
        guard results, running == nil, queue.isEmpty, !isShown() else { return }
        let left = rows.filter { row in
            if case .failed = row.state { return true }
            return row.lines.contains { $0.tone == .step }
        }.map(\.kind)
        let failed = rows.contains { if case .failed = $0.state { return true } else { return false } }
        guard SetupTrigger.opensResults(failed: failed, stepLeft: stepCount > 0),
              !Set(left).isSubset(of: reported) else { return }
        reported.formUnion(left)
        holdsResults = true
        onNeedsUser()
    }

    /// The setting changed elsewhere (Settings) while the window is shown:
    /// the box follows it, and on it is the switch.
    func automaticChanged(_ on: Bool) {
        keepCurrent = on
        if on { boxIsSwitch = true }
        objectWillChange.send()
    }

    /// The rows that leave a step to the user.
    private var stepCount: Int {
        rows.filter { $0.lines.contains { $0.tone == .step } }.count
    }

    // MARK: - Words

    var title: String { t(results ? "updates.auto.title" : "updates.title") }

    var body: String {
        guard results else { return t(socketCause ? "updates.body" : "updates.body.general") }
        if rows.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
            return t("updates.auto.body.failed")
        }
        switch stepCount {
        case 0: return t("updates.auto.body")
        case 1: return t("updates.auto.body.step")
        default: return t("updates.auto.body.steps")
        }
    }

    /// The box's second line: what it will do, or where it is turned off.
    var keepDetail: String { t(boxIsSwitch ? "updates.keep.on" : "updates.keep.detail") }

    /// The box pressed: the setting at once while it is the switch.
    func setKeepCurrent(_ on: Bool) {
        keepCurrent = on
        if boxIsSwitch { host.setAutomatic(on) }
    }

    /// This Mac's files were written (Settings' press or this window's):
    /// read them again.
    func agentsChanged() {
        host.reloadAgents()
        refresh()
    }

    // MARK: - Reading

    /// Every row read again: called while the window is on screen as the
    /// tunnels move, and after each press. Written only when a row reads
    /// differently.
    func refresh() {
        let cards = Dictionary(host.agentRows().compactMap { row in row.item.agent.map { ($0, row) } },
                               uniquingKeysWith: { first, _ in first })
        let agents = agentIDs.compactMap { source -> Row? in
            cards[source].flatMap { agentRow($0, source) }
        }
        let byID = Dictionary(host.machines().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let machines = machineIDs.compactMap { id in byID[id].map(machineRow) }
        if agents != self.agents { self.agents = agents }
        if machines != self.machines { self.machines = machines }
    }

    /// `nil` once the agent is no longer this window's: its hooks taken
    /// out, unreadable, switched off — Settings says what it is.
    private func agentRow(_ card: SetupRow, _ source: AgentID) -> Row? {
        let kind = Kind.agent(source)
        let state: State
        if let done = pressed[kind] {
            state = done
        } else if !card.enabled {
            return nil
        } else if card.hooksStatus == .outdated {
            state = card.failure.map(State.failed) ?? .needsUpdate
        } else if card.hooksStatus == .installed {
            state = .current
        } else {
            return nil
        }
        var lines: [Line]
        switch state {
        case .failed(let text): lines = [Line(text: text, tone: .trouble)]
        case .updated:
            // What the agent needs now, where it has something to say: a
            // step to take, or how its sessions take the change.
            if let step = hint("updates.step.\(source.rawValue)") {
                lines = [Line(text: step, tone: .step)]
            } else if let after = hint("updates.after.\(source.rawValue)") {
                lines = [Line(text: after, tone: .neutral)]
            } else {
                lines = [Line(text: card.detail, tone: .neutral)]
            }
        default: lines = [Line(text: card.detail, tone: .neutral)]
        }
        return Row(kind: kind, name: card.name, state: state, lines: lines)
    }

    private func machineRow(_ machine: Machine) -> Row {
        let kind = Kind.machine(machine.id)
        let read = Self.state(of: machine, in: lang)
        var state = read
        if let done = pressed[kind] {
            // A press's outcome stands while the machine is still there to
            // act on; a tunnel that went down says so instead.
            switch read {
            case .notConnected, .channelFailed: if done == .updating { state = done }
            default: state = done
            }
        }
        var lines: [Line]
        switch state {
        case .needsUpdate, .updating:
            // "connected · Claude Code, evlat command": what the press moves.
            let what = (machine.outdated ?? []).map { t($0.agent.display.nameKey) }
                + (machine.commandOld ? [t("remote.item.command")] : [])
            lines = [Line(text: ([t("remote.state.connected")] + [what.joined(separator: ", ")])
                .filter { !$0.isEmpty }.joined(separator: " · "), tone: .neutral)]
        case .updated:
            let written = updatedAgents[kind] ?? []
            lines = []
            if written.contains(where: { LocalHooks.approvals(of: $0.agent, on: .server) != nil }) {
                lines.append(Line(text: t("updates.machine.approvals"), tone: .neutral))
            }
            lines += written.compactMap { source in hint("updates.step.\(source.rawValue)") }
                .map { Line(text: $0, tone: .step) }
            if lines.isEmpty { lines = [Line(text: t("remote.state.connected"), tone: .neutral)] }
        case .failed(let text): lines = [Line(text: text, tone: .trouble)]
        case .current, .checking: lines = [Line(text: t("remote.state.connected"), tone: .neutral)]
        case .notConnected: lines = [Line(text: t("updates.machine.notConnected"), tone: .neutral)]
        case .channelFailed(let text, _): lines = [Line(text: text, tone: .trouble)]
        }
        return Row(kind: kind, name: machine.name, state: state, lines: lines)
    }

    /// A machine's state as read, before any press: its tunnel's, and once
    /// connected what its reading says.
    static func state(of machine: Machine, in lang: String) -> State {
        switch machine.state {
        case nil, .stopped?, .connecting?:
            return .notConnected
        case .connected?:
            guard let outdated = machine.outdated else { return .checking }
            return outdated.isEmpty && !machine.commandOld ? .current : .needsUpdate
        case .waiting(_, let failure)?:
            return .channelFailed(L10n.t(RemoteMachinesModel.failureKey(failure), in: lang),
                                  advice: L10n.t(RemoteMachinesModel.adviceKey(failure), in: lang))
        case .needsUser(let rejected)?:
            let key = rejected ? "remote.state.passwordRefused" : "remote.state.needsPassword"
            return .channelFailed(L10n.t(key, in: lang), advice: L10n.t(key + ".advice", in: lang))
        }
    }

    /// The catalogue's line for `key`, when the agent has one.
    private func hint(_ key: String) -> String? {
        RemoteMachinesModel.hint(key, in: lang)
    }

    // MARK: - Pressing

    var rows: [Row] { agents + machines }

    /// "Update all" is offered while a row has something to press.
    var canUpdateAll: Bool { running == nil && rows.contains { $0.action != nil } }

    /// The footer's Done: once "Update all" was pressed, or once single
    /// presses left nothing old.
    var isDone: Bool {
        pressedAll || (pressedAny && running == nil && !rows.contains { $0.state == .needsUpdate })
    }

    /// A row's own button.
    func press(_ kind: Kind) {
        guard running == nil, rows.first(where: { $0.kind == kind })?.action != nil else { return }
        pressedAny = true
        run(kind)
    }

    /// Every row with a button, one after another: this Mac's first, then
    /// the servers, each in the window's order. A machine's job is waited
    /// for before the next starts.
    func updateAll() {
        guard canUpdateAll else { return }
        if !boxIsSwitch, keepCurrent {
            host.setAutomatic(true)
            boxIsSwitch = true
        }
        pressedAll = true
        pressedAny = true
        queue = rows.filter { $0.action != nil }.map(\.kind)
        next()
    }

    private func next() {
        guard running == nil else { return }
        while !queue.isEmpty {
            let kind = queue.removeFirst()
            // A row that moved since (updated in Settings, disconnected) is
            // left as it now reads (`agentsChanged`, `refresh`).
            guard rows.first(where: { $0.kind == kind })?.action != nil else { continue }
            run(kind)
            if running != nil { return }
        }
    }

    private func run(_ kind: Kind) {
        switch kind {
        case .agent(let source):
            pressed[kind] = .updating
            if automaticKinds.contains(kind) { host.keepAgent(source) } else { host.updateAgent(source) }
            let card = host.agentRows().first { $0.item == .agent(source) }
            if let failure = card?.failure {
                pressed[kind] = .failed(failure)
            } else if card?.hooksStatus == .installed {
                pressed[kind] = .updated
            } else {
                pressed[kind] = nil
            }
            refresh()
            next()
        case .machine(let id):
            running = kind
            pressed[kind] = .updating
            let update = automaticKinds.contains(kind) ? host.keepMachine : host.updateMachine
            let started = update(id) { [weak self] result in
                guard let self else { return }
                // A reopening in between kept this job as running; anything
                // else running is not this one's to end.
                if self.running == kind { self.running = nil }
                if let failure = result.failure {
                    self.pressed[kind] = .failed(failure)
                } else {
                    self.pressed[kind] = .updated
                    self.updatedAgents[kind] = result.agents
                }
                self.refresh()
                self.next()
                self.report()
            }
            if !started {
                if running == kind { running = nil }
                if pressed[kind] == .updating { pressed[kind] = nil }
            }
            refresh()
        }
    }

    /// "Why?": the row's advice opens under it, or closes.
    func toggleWhy(_ kind: Kind) {
        if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
    }

    /// Every line is made in `lang` as it is read: a new language reads again.
    func languageChanged(to language: String) {
        guard language != lang else { return }
        lang = language
        // A refused press keeps its line: it was the job's.
        host.reloadAgents()
        refresh()
        objectWillChange.send()
    }

    // MARK: - Catalogue

    /// Every key the window asks for, besides the ones it borrows
    /// (`remote.*`, `setup.*`, the agents' names) and an agent's own lines
    /// (`updates.step.<agent>`, `updates.after.<agent>`), asked for only when
    /// the catalogue has them.
    static let keys = ["updates.window.title", "updates.title", "updates.body", "updates.body.general",
                       "updates.auto.title", "updates.auto.body", "updates.auto.body.step", "updates.auto.body.steps",
                       "updates.auto.body.failed", "updates.keep", "updates.keep.detail", "updates.keep.on",
                       "updates.section.mac", "updates.section.servers", "updates.later", "updates.all", "updates.done",
                       "updates.updating", "updates.updated", "updates.current", "updates.retry", "updates.why",
                       "updates.checking", "updates.machine.notConnected", "updates.machine.approvals",
                       "updates.commandNotRun"]
}
