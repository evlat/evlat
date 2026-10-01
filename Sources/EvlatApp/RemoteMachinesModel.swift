import AppKit
import EvlatCore

/// The remote machines window's state, apart from its view: the machines and
/// what their tunnels say, the target being typed and why it was refused, the
/// setup jobs and their result lines, the removal being confirmed, and the
/// blocks to paste by hand.
///
/// Everything the user reads is decided here, from the catalogue, so the
/// window's rules are tested without drawing it. The app is reached through
/// `Host` — closures, so a test can hand a recorder — and never through a
/// type this file would have to know.
///
/// **Main queue only**, like the controller behind `Host` and the installer.
@MainActor
final class RemoteMachinesModel: ObservableObject {
    /// What the window needs from the app (`AppController.remoteMachinesHost`).
    struct Host {
        var machines: () -> [RemoteMachine]
        var state: (String) -> RemoteTunnel.State?
        /// Rows per machine id, dimmed ones included.
        var sessionCounts: () -> [String: Int]
        /// Opens the tunnel and stores the machine (unless `isStored` is
        /// false). A target already there answers with that machine.
        var add: (String) -> Result<RemoteMachine, RemoteMachine.TargetProblem>
        var remove: (String) -> Void
        /// `false` when the machines came from `EVLAT_MACHINES`: then nothing
        /// added or removed here outlives the process.
        var isStored: () -> Bool
        /// The machine's signal key (`RemoteTunnels.signalKey(of:)`): what
        /// the command's install writes on the server.
        var signalKey: (String) -> String?
        /// The socket of the machine's tunnel master, while one runs
        /// (`RemoteTunnels.controlPath(of:)`): the jobs ride it.
        var controlPath: (String) -> String? = { _ in nil }
        /// "Enter Password…": an interactive try now (`RemoteTunnels.retryByUser`).
        var retryByUser: (String) -> Void = { _ in }
        /// The machine is known to want a password (`RemoteTunnels.asksForPassword`).
        var asksForPassword: (String) -> Bool = { _ in false }
        /// A card's switch: the machine's agents as `EnabledAgents` stores
        /// them (`AppController.setMachineAgents`).
        var setAgents: (String, [String]?) -> Void = { _, _ in }
    }

    /// How a line reads at a glance. The window colours it; no icon.
    enum Tone: Equatable { case neutral, good, trouble }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let target: String
        let status: String
        /// What to do about a failure, `nil` when there is none.
        let advice: String?
        let tone: Tone
        /// The row offers "Enter Password…": the tunnel waits for the user,
        /// or a password is what it lacks.
        var enterPassword = false
    }

    /// The line a finished job leaves under the buttons, and what the agents
    /// need after the write.
    struct Outcome: Equatable {
        let line: String
        let trouble: Bool
        let hints: [String]
    }

    /// An agent card's button: the agent as one unit (`RemoteSettings.Change.agent`),
    /// its one file in one write. It does not read the server first: the
    /// result line says what was there.
    enum Job: Hashable {
        case install(AgentSource), remove(AgentSource)

        var source: AgentSource {
            switch self {
            case .install(let source), .remove(let source): return source
            }
        }

        var changes: [RemoteSettings.Change] { [.agent(source)] }

        var action: RemoteSettings.Action {
            switch self {
            case .install: return .install
            case .remove: return .remove
            }
        }
    }

    /// The rows under an open machine: a card per agent, then the command.
    enum Item: Hashable {
        case agent(AgentSource), command
    }

    /// A machine's settings files and command as last read over `ssh`
    /// (`RemoteInstaller.read`). None until the row is opened or checked.
    enum Reading: Equatable {
        case reading
        case read(RemoteSettings.Reading)
        case unreachable
    }

    /// The rows under an open machine, in the local rows' values.
    struct Items: Equatable {
        /// Each agent's unit; `notFound` when the server does not have it.
        let agents: [AgentSource: SetupStatus]
        let command: SetupStatus
        /// The command is Evlat's, but a new login shell on the server does
        /// not find it: `~/.local/bin` is not on its `PATH`. `nil` when it
        /// is, when there is no command, or when no shell answered — then
        /// the row says what it said before the check.
        var offPath: RemotePath.Status? = nil

        static let unknown = Items(agents: Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, .unknown) }),
                                   command: .unknown)
    }

    /// One block to paste, with the sentence above it. `shown` is what the
    /// window draws — the key's block hides the key — and `text` what Copy
    /// puts on the pasteboard.
    struct Block: Identifiable, Equatable {
        let id: String
        let captionKey: String
        let text: String
        let shown: String

        init(id: String, captionKey: String, text: String, shown: String? = nil) {
            self.id = id
            self.captionKey = captionKey
            self.text = text
            self.shown = shown ?? text
        }

        /// Drawn masked (the machine's key): its copy is marked concealed.
        var isSecret: Bool { shown != text }
    }

    /// nspasteboard.org's markers: clipboard managers keep no history of a
    /// copy that carries them (Universal Clipboard is not asked).
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @Published private(set) var rows: [Row] = []
    @Published var selection: String?
    /// The target field. Typing clears a refusal: the line was about what
    /// the field held.
    @Published var draft = "" {
        didSet { if problem != nil, draft != oldValue { problem = nil } }
    }
    @Published private(set) var problem: String?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published private(set) var confirmingRemoval: String?
    /// The machine whose rows are open under it; one at a time, none at
    /// first (the settings section's rows open on a click).
    @Published private(set) var expanded: String?
    /// The row a running job writes, by machine: its spinner.
    @Published private(set) var working: [String: Item] = [:]
    /// The agent whose switch was turned off while Evlat's parts are on
    /// the server, by machine: its card asks first (this Mac's rule).
    @Published private(set) var turningOff: [String: AgentSource] = [:]
    /// The block whose button says "Copied", for a moment.
    @Published private(set) var copied: String?
    @Published private(set) var readings: [String: Reading] = [:]

    private let host: Host
    private let installer: RemoteInstaller
    private let pasteboard: NSPasteboard
    private let now: () -> Date
    let lang: String
    private var copyToken = 0

    init(host: Host, installer: RemoteInstaller, pasteboard: NSPasteboard = .general,
         now: @escaping () -> Date = Date.init, lang: String = L10n.language) {
        self.host = host
        self.installer = installer
        self.pasteboard = pasteboard
        self.now = now
        self.lang = lang
        reload()
    }

    var isStored: Bool { host.isStored() }

    var selectedRow: Row? { rows.first { $0.id == selection } }

    func t(_ key: String, _ values: [String: String] = [:]) -> String {
        L10n.t(key, values, in: lang)
    }

    /// Re-reads the machines and their tunnels. Called while the window is
    /// on screen at every refresh: written only when a line reads
    /// differently, so an unchanged second redraws nothing.
    func reload() {
        let counts = host.sessionCounts()
        let date = now()
        let fresh = host.machines().map { machine -> Row in
            let status = Self.status(host.state(machine.id), sessions: counts[machine.id] ?? 0,
                                     now: date, in: lang, target: machine.target)
            return Row(id: machine.id, name: machine.name, target: machine.target,
                       status: status.text, advice: status.advice, tone: status.tone,
                       enterPassword: Self.offersPassword(host.state(machine.id)))
        }
        if fresh != rows { rows = fresh }
        if let selection, !fresh.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil, let first = fresh.first { selection = first.id }
        turningOff = turningOff.filter { id, _ in fresh.contains { $0.id == id } }
        if let pending = confirmingRemoval, !fresh.contains(where: { $0.id == pending }) {
            confirmingRemoval = nil
        }
        if let expanded, !fresh.contains(where: { $0.id == expanded }) { self.expanded = nil }
        let gone = readings.keys.filter { id in !fresh.contains { $0.id == id } }
        for id in gone { readings[id] = nil }
    }

    // MARK: - Adding

    /// The field's target, trimmed at its edges; refused with a line under
    /// the field, or added and selected. A target already in the list is
    /// refused too, and that machine is shown instead.
    func add() {
        let target = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = RemoteMachine.validate(target: target) {
            self.problem = t(Self.problemKey(problem))
            return
        }
        if let existing = host.machines().first(where: { $0.target == target }) {
            problem = t("remote.add.duplicate", ["name": existing.name])
            selection = existing.id
            return
        }
        switch host.add(target) {
        case .success(let machine):
            draft = ""
            problem = nil
            confirmingRemoval = nil
            reload()
            selection = machine.id
        case .failure(let refused):
            problem = t(Self.problemKey(refused))
        }
    }

    static func problemKey(_ problem: RemoteMachine.TargetProblem) -> String {
        switch problem {
        case .empty: return "remote.add.empty"
        case .option: return "remote.add.option"
        case .invalidCharacter: return "remote.add.invalidCharacter"
        }
    }

    /// "Enter Password…" on a row: the window asks at once.
    func enterPassword(_ id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        host.retryByUser(id)
        reload()
    }

    static func offersPassword(_ state: RemoteTunnel.State?) -> Bool {
        state?.wantsPassword ?? false
    }

    /// A password server with no tunnel up: the setup buttons cannot reach
    /// it (they ride the tunnel's master), so the row says to connect first.
    /// A running `ssh` is not enough: at a prompt its master socket is not
    /// open yet; "connected" comes after the login, when it is. A tunnel
    /// up without a master (a socket path too long, another's live socket)
    /// is not asked to connect again — no press would change it; the
    /// buttons run and their own login's refusal is what the row says.
    func needsConnectionFirst(_ id: String) -> Bool {
        guard host.asksForPassword(id) else { return false }
        return host.state(id)?.isConnected != true
    }

    // MARK: - Removing

    func askToRemove() {
        confirmingRemoval = selection
    }

    /// A machine row's own "Remove…".
    func askToRemove(_ id: String) {
        selection = id
        confirmingRemoval = id
    }

    // MARK: - Opening a machine

    /// A click on a machine's row: its rows open under it and the machine
    /// is read once (`open`); a second click closes them. The jobs act on
    /// the open one.
    func toggle(_ id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if expanded == id {
            expanded = nil
            return
        }
        expanded = id
        selection = id
        if confirmingRemoval != id { confirmingRemoval = nil }
        open(id)
    }

    /// A row's button: `action` on `item` of machine `id`, under its lock.
    func perform(_ item: Item, _ action: RemoteSettings.Action, on id: String) {
        guard rows.contains(where: { $0.id == id }), canRun(id) else { return }
        selection = id
        switch item {
        case .agent(let source): run(action == .install ? .install(source) : .remove(source))
        case .command: runCommand(action)
        }
        if busy.contains(id) { working[id] = item }
    }

    func cancelRemoval() {
        confirmingRemoval = nil
    }

    func confirmRemoval() {
        guard let id = confirmingRemoval else { return }
        confirmingRemoval = nil
        host.remove(id)
        outcomes[id] = nil
        readings[id] = nil
        if expanded == id { expanded = nil }
        reload()
    }

    // MARK: - Setup over ssh

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    func canRun(_ id: String) -> Bool { !busy.contains(id) && !installer.isBusy(id) }

    /// Runs `job` on the selected machine. A machine already running one
    /// refuses a second (the installer's rule, shown as disabled buttons).
    func run(_ job: Job) {
        guard let row = selectedRow else { return }
        run(job.changes, job.action, machine: row.id)
    }

    /// `then` hears the job's line once it is drawn: a turn-off waits for
    /// its removal there.
    private func run(_ changes: [RemoteSettings.Change], _ action: RemoteSettings.Action, machine id: String,
                     then: ((Outcome) -> Void)? = nil) {
        guard let row = rows.first(where: { $0.id == id }), canRun(id) else { return }
        let started = installer.run(changes, action, machine: id, target: row.target,
                                    controlPath: host.controlPath(id)) {
            [weak self] results in
            guard let self else { return }
            self.busy.remove(id)
            self.working[id] = nil
            let outcome = Self.outcome(results, action, in: self.lang)
            self.outcomes[id] = outcome
            then?(outcome)
            self.reread(id)
        }
        guard started else { return }
        busy.insert(id)
        outcomes[id] = nil
    }

    /// One part per file, "Claude Code: installed · Codex: not installed (no
    /// folder)"; a server that could not be reached is said once. A missing
    /// folder is not trouble — that agent is simply not on the server.
    static func outcome(_ results: [(RemoteSettings.Change, RemoteInstaller.Result)],
                        _ action: RemoteSettings.Action, in lang: String) -> Outcome {
        if !results.isEmpty, results.allSatisfy({ $0.1 == .failure(.unreachable) }) {
            return Outcome(line: L10n.t(resultKey(.failure(.unreachable), action), in: lang),
                           trouble: true, hints: [])
        }
        let line = results.map { change, result in
            L10n.t("remote.result.part", ["change": L10n.t(changeKey(change), in: lang),
                                          "result": L10n.t(resultKey(result, action), in: lang)], in: lang)
        }.joined(separator: " · ")
        let trouble = results.contains { _, result in
            if case .failure(let failure) = result { return failure != .file(.noDirectory) }
            return false
        }
        // What an agent needs after the write. An agent with something to
        // say has its own line (`remote.hint.<action>.<agent>`); one with
        // nothing measured — Antigravity — has none.
        var hints: [String] = []
        for (change, result) in results where result == .success(.written) {
            switch change {
            case .hooks(let source), .agent(let source):
                if let hint = hint("remote.hint.\(action == .install ? "install" : "remove").\(source.rawValue)", in: lang) {
                    hints.append(hint)
                }
                if case .agent = change, action == .install, RemoteSettings.relays(source) {
                    hints.append(usageHint(source, in: lang))
                }
            case .statusLine where action == .install:
                if let source = AgentSource.allCases.first(where: RemoteSettings.relays) {
                    hints.append(usageHint(source, in: lang))
                }
            case .statusLine, .pathLine:
                break
            }
        }
        return Outcome(line: line, trouble: trouble, hints: hints)
    }

    /// The catalogue's line for `key`, when the agent has one.
    private static func hint(_ key: String, in lang: String) -> String? {
        L10n.catalog.tables[Catalog.source]?[key] != nil ? L10n.t(key, in: lang) : nil
    }

    private static func usageHint(_ source: AgentSource, in lang: String) -> String {
        L10n.t("remote.hint.usage", ["agent": L10n.t("source.\(source.rawValue)", in: lang)], in: lang)
    }

    // MARK: - Reading the server

    /// The row was opened: the machine is read once, in one `ssh` call.
    func open(_ id: String) { read(id) }

    /// "I ran it, check": the same read again. It writes nothing.
    func check(_ id: String) { read(id) }

    /// A job finished: what was read is stale — a block made from it would
    /// be refused — so the machine is read once more (one `ssh` call), and
    /// its rows say what the write left instead of "unknown".
    private func reread(_ id: String) {
        readings[id] = nil
        read(id)
    }

    /// Under the machine's lock: while a job runs there the read is skipped,
    /// not waited for — the job's own line says what it did.
    private func read(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let started = installer.read(machine: id, target: row.target, controlPath: host.controlPath(id)) { [weak self] result in
            guard let self, self.readings[id] == .reading else { return }
            switch result {
            case .success(let reading): self.readings[id] = .read(reading)
            case .failure: self.readings[id] = .unreachable
            }
        }
        if started { readings[id] = .reading }
    }

    /// The rows' states; unknown until a read answered.
    func items(for id: String) -> Items {
        guard case .read(let reading)? = readings[id] else { return .unknown }
        return Self.items(reading)
    }

    /// A card per agent, by this Mac's unit rule (`Reading.unit`): a folder
    /// that is missing is an agent not on the server.
    static func items(_ reading: RemoteSettings.Reading) -> Items {
        let agents = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, status(reading.unit($0))) })

        let command: SetupStatus
        var offPath: RemotePath.Status?
        switch reading.command {
        case .missing: command = .missing
        case .foreign: command = .foreign
        case .installed:
            command = reading.command.isCurrent ? .installed : .outdated
            if let path = reading.path, path.onPath == false { offPath = path }
        }
        return Items(agents: agents, command: command, offPath: offPath)
    }

    static func status(_ unit: RemoteSettings.Found<AgentIntegration.State>) -> SetupStatus {
        switch unit {
        case .noDirectory: return .notFound
        case .unreadable: return .unknown
        case .state(let state):
            switch state.status {
            case .current: return .installed
            case .outdated: return .outdated
            case .missing: return .missing
            }
        }
    }

    /// The startup file whose Evlat `PATH` line a removal of the command
    /// takes with it — what its consent names; `nil` when there is none.
    func pathLineToRemove(for id: String) -> String? {
        guard case .read(let reading)? = readings[id], case .installed = reading.command,
              let path = reading.path, path.added else { return nil }
        return path.file
    }

    /// "Add to PATH": Evlat's line into the startup file the read chose,
    /// under the machine's lock, then the machine is read again.
    func addToPath(_ id: String) {
        guard let file = items(for: id).offPath?.file else { return }
        selection = id
        run([.pathLine(file)], .install, machine: id)
        if busy.contains(id) { working[id] = .command }
    }

    /// Every row's block in one, from the machine's last reading
    /// (`RemoteSettings.combinedScript`), for the agents switched on; none
    /// without a reading, a key, or anything to write. It carries the key:
    /// drawn masked, copied concealed.
    func combinedBlock(for id: String) -> Block? {
        guard case .read(let reading)? = readings[id], let key = host.signalKey(id),
              let text = RemoteSettings.combinedScript(reading, key: key, agents: enabledAgents(of: id))
        else { return nil }
        return Block(id: "combined", captionKey: "remote.combined.whole", text: text,
                     shown: text.replacingOccurrences(of: key, with: Self.mask))
    }

    // MARK: - The agents' cards

    /// The machine's last reading; `nil` until one answered.
    private func lastReading(_ id: String) -> RemoteSettings.Reading? {
        guard case .read(let reading)? = readings[id] else { return nil }
        return reading
    }

    /// Whether the server has the agent, as last read; before a reading,
    /// every agent might be there.
    private func isPresent(_ source: AgentSource, on id: String) -> Bool {
        lastReading(id).map { $0.unit(source) != .noDirectory } ?? true
    }

    /// The machine's switches: never changed, every agent the server has
    /// (`EnabledAgents`' live answer, asked of the reading).
    func enabledAgents(of id: String) -> Set<AgentSource> {
        let stored = host.machines().first { $0.id == id }?.agents
        return EnabledAgents.resolve(stored: stored, isPresent: { self.isPresent($0, on: id) })
    }

    /// Each agent's card on the machine, drawn by this Mac's card view:
    /// one state for the unit, its one file on the server
    /// (`devbox:~/.claude/settings.json`), its parts and its switch.
    func agentRows(for id: String) -> [SetupRow] {
        guard let row = rows.first(where: { $0.id == id }) else { return [] }
        let reading = lastReading(id)
        let enabled = enabledAgents(of: id)
        return AgentSource.allCases.map { source in
            var card = Self.agentRow(source, unit: reading?.unit(source), target: row.target, in: lang)
            card.enabled = enabled.contains(source)
            return card
        }
    }

    /// One card from the unit as read; `nil` (no reading yet) is unknown.
    static func agentRow(_ source: AgentSource, unit: RemoteSettings.Found<AgentIntegration.State>?,
                         target: String, in lang: String) -> SetupRow {
        let file = "\(target):~/\(source.settingsPath)"
        let status = unit.map { Self.status($0) } ?? .unknown
        guard case .state(let state)? = unit else {
            return SetupRow(item: .agent(source), status: status, name: L10n.t("source.\(source.rawValue)", in: lang),
                            detail: file, note: nil, failure: nil)
        }
        let note = state.relay == .modified ? L10n.t("setup.agent.usageModified", in: lang) : nil
        var card = SetupRow(item: .agent(source), status: status, name: L10n.t("source.\(source.rawValue)", in: lang),
                            detail: file, note: note, failure: nil)
        // A server has no approval hook: the part is the hooks alone.
        card.parts = [SetupPart(name: L10n.t("setup.agent.part.hooks", in: lang), file: file,
                                status: partStatus(state.hooks))]
        if let relay = state.relay {
            card.parts.append(SetupPart(name: L10n.t("setup.agent.part.usage", in: lang), file: file,
                                        status: relay == .modified ? .foreign
                                            : relay == .current ? .installed : .missing))
        }
        card.removesRelay = state.relay == .current
        return card
    }

    private static func partStatus(_ hooks: HookSettings.State) -> SetupStatus {
        switch hooks {
        case .current: return .installed
        case .outdated: return .outdated
        case .missing: return .missing
        }
    }

    /// A card's switch: on at once; off at once unless Evlat's parts are on
    /// the server — then the card asks whether they go too.
    func setEnabled(_ source: AgentSource, _ on: Bool, on id: String) {
        turningOff[id] = nil
        if !on, let status = agentRows(for: id).first(where: { $0.item == .agent(source) })?.status,
           status == .installed || status == .outdated {
            turningOff[id] = source
            return
        }
        applyEnabled(source, on, on: id)
    }

    /// The question's answer. `remove`: the agent's parts go first, and the
    /// switch goes off only once the server took them out — a refused
    /// removal leaves the agent on, its card saying why.
    func confirmTurnOff(remove: Bool, on id: String) {
        guard let source = turningOff[id] else { return }
        turningOff[id] = nil
        guard remove else { return applyEnabled(source, false, on: id) }
        guard canRun(id) else { return }
        selection = id
        run(Job.remove(source).changes, .remove, machine: id) { [weak self] outcome in
            guard !outcome.trouble else { return }
            self?.applyEnabled(source, false, on: id)
        }
        if busy.contains(id) { working[id] = .agent(source) }
    }

    func cancelTurnOff(on id: String) { turningOff[id] = nil }

    private func applyEnabled(_ source: AgentSource, _ on: Bool, on id: String) {
        let stored = host.machines().first { $0.id == id }?.agents
        guard let value = EnabledAgents.changing(source, to: on, stored: stored,
                                                 isPresent: { self.isPresent($0, on: id) }) else { return }
        host.setAgents(id, value)
        objectWillChange.send()
    }

    /// What a card's press writes on the server, one line for its one file
    /// (this Mac's wording); and that the user's status line is wrapped
    /// when the usage line goes in.
    func consent(_ source: AgentSource, _ action: SetupAction, on id: String) -> [String] {
        guard let row = rows.first(where: { $0.id == id }),
              case .state(let state)? = lastReading(id)?.unit(source) else { return [] }
        var what: [String] = []
        if action.installs {
            if state.hooks != .current { what.append("setup.consent.what.hooks") }
            if state.installsRelay { what.append("setup.consent.what.usage") }
        } else {
            if state.hooks != .missing { what.append("setup.consent.what.hooks.remove") }
            if state.relay == .current { what.append("setup.consent.what.usage.remove") }
        }
        guard !what.isEmpty else { return [] }
        var lines = [t("setup.consent.line", ["file": "\(row.target):~/\(source.settingsPath)",
                                              "what": what.map { t($0) }.joined(separator: t("setup.consent.and"))])]
        if action.installs && state.installsRelay { lines.append(t("setup.consent.wraps")) }
        return lines
    }

    /// The card's "Remove the usage line": its file alone.
    func relayRemovalConsent(_ source: AgentSource, on id: String) -> [String] {
        guard let row = rows.first(where: { $0.id == id }), RemoteSettings.relays(source) else { return [] }
        return [t("setup.consent.line", ["file": "\(row.target):~/\(RemoteSettings.Change.statusLine.path)",
                                         "what": t("setup.consent.what.usage.remove")])]
    }

    func removeRelay(_ source: AgentSource, on id: String) {
        guard RemoteSettings.relays(source), canRun(id) else { return }
        selection = id
        run([.statusLine], .remove, machine: id)
        if busy.contains(id) { working[id] = .agent(source) }
    }

    /// The card's block to paste: the bytes the server's writer would
    /// write into an empty file (no approval hook), and the usage line
    /// where the server gets one.
    static func manual(_ source: AgentSource, in lang: String) -> SetupManual {
        let manual = RemoteSettings.manual
        let relay = RemoteSettings.relays(source)
        var removal = L10n.t("remote.manual.remove", ["marker": manual.marker], in: lang)
        if relay { removal += " " + L10n.t("setup.manual.remove.usage", in: lang) }
        return SetupManual(text: manual.hooks(for: source), wrapping: relay ? wrappingValue : nil,
                           removal: removal, statusLine: relay ? manual.statusLine : nil,
                           lead: L10n.t("remote.manual.agent", ["file": "~/" + source.settingsPath], in: lang),
                           statusLineLead: L10n.t("remote.manual.statusLine", in: lang),
                           wrappingLead: L10n.t("remote.manual.wrapping",
                                                ["placeholder": RemoteSettings.Manual.placeholder], in: lang))
    }

    /// The wrapper shown as the JSON string it goes into, so it pastes as
    /// a `command` value.
    static let wrappingValue: String = {
        let wrapping = RemoteSettings.manual.wrapping
        return (try? JSONSerialization.data(withJSONObject: wrapping, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? wrapping
    }()

    // MARK: - The command line

    /// Installs or removes the server's `evlat` on the selected machine,
    /// under the machine's one lock; the line it leaves is the same line.
    func runCommand(_ action: RemoteSettings.Action) {
        guard let row = selectedRow, canRun(row.id), let key = host.signalKey(row.id) else { return }
        let id = row.id
        // The line the consent named, read with it: none on an install.
        let pathLine = action == .remove ? pathLineToRemove(for: id) : nil
        let started = installer.runCommand(action, key: key, pathLine: pathLine, machine: id, target: row.target,
                                           controlPath: host.controlPath(id)) {
            [weak self] result, path in
            guard let self else { return }
            self.busy.remove(id)
            self.working[id] = nil
            self.outcomes[id] = Self.commandOutcome(result, action, path: path, in: self.lang)
            self.reread(id)
        }
        guard started else { return }
        busy.insert(id)
        outcomes[id] = nil
    }

    /// What was done; after an install, `curl` missing (the command then
    /// sends nothing) and how to try it. Whether a new login shell finds it
    /// is the row's to say, from the read that follows (`RemotePath`). A
    /// removal that took Evlat's `PATH` line says so after the command's
    /// line (`path`).
    static func commandOutcome(_ result: RemoteInstaller.CommandResult, _ action: RemoteSettings.Action,
                               path: RemoteInstaller.Result? = nil, in lang: String) -> Outcome {
        var line = L10n.t(commandResultKey(result, action), in: lang)
        guard case .success(let report) = result else { return Outcome(line: line, trouble: true, hints: []) }
        if let path {
            let part = outcome([(.pathLine(""), path)], action, in: lang)
            line += " " + part.line
            if part.trouble { return Outcome(line: line, trouble: true, hints: []) }
        }
        guard action == .install else { return Outcome(line: line, trouble: false, hints: []) }
        var hints: [String] = []
        if !report.curl { hints.append(L10n.t("remote.command.noCurl", in: lang)) }
        hints.append(L10n.t("remote.command.try", in: lang))
        return Outcome(line: line, trouble: !report.curl, hints: hints)
    }

    static func commandResultKey(_ result: RemoteInstaller.CommandResult, _ action: RemoteSettings.Action) -> String {
        switch (result, action) {
        case (.success(let report), .install):
            return report.wrote ? "remote.command.result.installed" : "remote.command.result.current"
        case (.success(let report), .remove):
            return report.wrote ? "remote.command.result.removed" : "remote.command.result.absent"
        case (.failure(.foreign), .install): return "remote.command.result.foreign"
        case (.failure(.foreign), .remove): return "remote.command.result.foreign.remove"
        case (.failure(.unwritable), _): return "remote.command.result.unwritable"
        case (.failure(.unreachable), _): return "remote.command.result.unreachable"
        }
    }

    /// The three blocks for the machine's key; none without one. The key's
    /// block draws the key as dots — a shared screen must not show it — and
    /// copies the real line.
    func commandBlocks(for id: String) -> [Block] {
        guard let key = host.signalKey(id) else { return [] }
        let manual = RemoteCommand.manual(key: key)
        let mask = Self.mask
        return [
            Block(id: "command.script", captionKey: "remote.command.manual.script", text: manual.script),
            Block(id: "command.key", captionKey: "remote.command.manual.key", text: manual.key,
                  shown: manual.key.replacingOccurrences(of: key, with: mask)),
            Block(id: "command.remove", captionKey: "remote.command.manual.remove", text: manual.remove),
        ]
    }

    /// The PATH line to paste into the startup file the read chose.
    static let pathBlock = Block(id: "command.path", captionKey: "settings.remote.path.manual", text: RemotePath.line)

    /// How a key is drawn.
    static let mask = String(repeating: "•", count: 16)

    static func changeKey(_ change: RemoteSettings.Change) -> String {
        switch change {
        case .hooks(let source), .agent(let source): return "source.\(source.rawValue)"
        case .statusLine: return "remote.change.usage"
        case .pathLine: return "remote.change.path"
        }
    }

    /// A switch, not a string built from the case: a new failure does not
    /// compile until it has a line.
    static func resultKey(_ result: RemoteInstaller.Result, _ action: RemoteSettings.Action) -> String {
        switch result {
        case .success(.written): return action == .install ? "remote.result.installed" : "remote.result.removed"
        case .success(.unchanged): return action == .install ? "remote.result.current" : "remote.result.absent"
        case .failure(.file(let failure)):
            switch failure {
            case .unreadable: return "remote.result.unreadable"
            case .malformed: return "remote.result.malformed"
            case .noDirectory: return "remote.result.noDirectory"
            case .changedUnderneath: return "remote.result.changedUnderneath"
            case .unwritable: return "remote.result.unwritable"
            }
        case .failure(.unreachable): return "remote.result.unreachable"
        }
    }

    // MARK: - Status

    /// A machine's line: "connected · 2 sessions", "connecting…", or what
    /// went wrong and when the next try is — with what to do about it.
    static func status(_ state: RemoteTunnel.State?, sessions: Int, now: Date, in lang: String,
                       target: String = "") -> (text: String, advice: String?, tone: Tone) {
        switch state {
        case nil, .stopped?:
            return (L10n.t("remote.state.stopped", in: lang), nil, .neutral)
        case .connecting?:
            return (L10n.t("remote.state.connecting", in: lang), nil, .neutral)
        case .connected?:
            guard sessions > 0 else { return (L10n.t("remote.state.connected", in: lang), nil, .good) }
            let count = sessions == 1
                ? L10n.t(SummaryLine.sessionsOneKey, in: lang)
                : L10n.t(SummaryLine.sessionsKey, ["count": String(sessions)], in: lang)
            return (L10n.t("remote.state.connected.sessions", ["sessions": count], in: lang), nil, .good)
        case .waiting(let retryAt, let failure)?:
            let left = retryAt.timeIntervalSince(now)
            let retry = left < 60
                ? L10n.t("remote.retry.soon", in: lang)
                : L10n.t("remote.retry", ["time": StatusLine.duration(left, in: lang)], in: lang)
            let text = L10n.t("remote.state.waiting",
                              ["failure": L10n.t(failureKey(failure), in: lang), "retry": retry], in: lang)
            return (text, L10n.t(adviceKey(failure), ["target": target], in: lang), .trouble)
        case .needsUser(let rejected)?:
            let key = rejected ? "remote.state.passwordRefused" : "remote.state.needsPassword"
            return (L10n.t(key, in: lang), L10n.t(key + ".advice", in: lang), .trouble)
        }
    }

    /// What went wrong, short: also the menu's line under its entry.
    nonisolated static func failureKey(_ failure: RemoteTunnel.Failure) -> String {
        switch failure {
        case .authentication: return "remote.failure.authentication"
        case .portBusy: return "remote.failure.portBusy"
        case .hostKey: return "remote.failure.hostKey"
        case .hostName: return "remote.failure.hostName"
        case .unreachable: return "remote.failure.unreachable"
        case .passwordNeeded: return "remote.failure.passwordNeeded"
        case .other: return "remote.failure.other"
        }
    }

    /// What to do about it.
    nonisolated static func adviceKey(_ failure: RemoteTunnel.Failure) -> String {
        failureKey(failure) + ".advice"
    }

    // MARK: - By hand

    /// Puts the block on the pasteboard; its button says so for a moment.
    func copy(_ block: Block) {
        pasteboard.clearContents()
        pasteboard.setString(block.text, forType: .string)
        // The key block is a secret: marked so clipboard managers that honour
        // nspasteboard.org's convention skip it and keep no history of it.
        if block.isSecret {
            pasteboard.setData(Data(), forType: Self.concealedType)
            pasteboard.setData(Data(), forType: Self.transientType)
        }
        copied = block.id
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copyToken == token else { return }
            self.copied = nil
        }
    }

    // MARK: - Catalogue

    /// Every key this window asks for, besides the ones it borrows
    /// (`source.*`, `summary.sessions*`, `time.*`).
    static var keys: [String] {
        var keys = ["remote.hint.install.claude", "remote.hint.install.codex", "remote.hint.remove.codex",
                    "remote.hint.usage", "remote.status.notFound", "remote.manual.agent", "remote.manual.statusLine",
                    "remote.manual.wrapping",
                    "remote.empty.title", "remote.empty.body", "remote.empty.requirement",
                    "remote.add.placeholder", "remote.add", "remote.add.duplicate",
                    "remote.environment",
                    "remote.state.stopped", "remote.state.connecting", "remote.state.connected",
                    "remote.state.connected.sessions", "remote.state.waiting", "remote.retry", "remote.retry.soon",
                    "remote.change.usage", "remote.change.path", "remote.result.part",
                    "remote.manual.remove", "remote.manual.surface",
                    "remote.copy", "remote.copied",
                    "remote.remove", "remote.remove.confirm", "remote.remove.cancel", "remote.remove.do",
                    "remote.command.noCurl", "remote.command.try",
                    "remote.command.manual.script", "remote.command.manual.key", "remote.command.manual.remove",
                    "remote.items.title", "remote.items.body", "remote.item.command",
                    "remote.reading", "remote.reading.failed", "remote.reading.connectFirst",
                    "remote.state.needsPassword", "remote.state.needsPassword.advice",
                    "remote.state.passwordRefused", "remote.state.passwordRefused.advice", "remote.enterPassword",
                    "remote.combined", "remote.combined.hint", "remote.combined.title", "remote.combined.body",
                    "remote.combined.whole", "remote.combined.check", "remote.combined.checkNote"]
        keys += [RemoteMachine.TargetProblem.empty, .option, .invalidCharacter].map(problemKey)
        let failures: [RemoteTunnel.Failure] = [.authentication, .portBusy, .hostKey, .hostName, .unreachable,
                                                .passwordNeeded, .other]
        keys += failures.map(failureKey) + failures.map(adviceKey)
        let results: [RemoteInstaller.Result] = [
            .success(.written), .success(.unchanged),
            .failure(.file(.unreadable)), .failure(.file(.malformed)), .failure(.file(.noDirectory)),
            .failure(.file(.changedUnderneath)), .failure(.file(.unwritable)), .failure(.unreachable),
        ]
        let commandResults: [RemoteInstaller.CommandResult] = [
            .success(.init(wrote: true, curl: true)), .success(.init(wrote: false, curl: true)),
            .failure(.foreign), .failure(.unwritable), .failure(.unreachable),
        ]
        for action in [RemoteSettings.Action.install, .remove] {
            keys += results.map { resultKey($0, action) }
            keys += commandResults.map { commandResultKey($0, action) }
        }
        return Array(Set(keys)).sorted()
    }
}
