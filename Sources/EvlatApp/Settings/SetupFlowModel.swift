import AppKit
import Combine
import EvlatCore
import EvlatAgents

/// The setup's state: which of the four steps is on and what its two writing
/// moments do — "Connect" on the first step, "Finish" on the last. The bar's
/// place, its visibility and the sound are written the moment they are chosen
/// (the bar answers to its place at once; its visibility only shows once the
/// panel is gone — the body stays out while the setup is open), so a press of
/// "Back" or the end of the flow has nothing of theirs left to write.
///
/// It composes rather than repeats, like `SettingsModel`: the rows are a
/// `SetupModel` of its own (its queue is this flow's, never the settings
/// window's) and every write goes through the settings' `Host` — the
/// controller's writers.
///
/// Going back never undoes anything: the rows read their state again and what
/// was connected shows as such. "Connect" writes exactly the agents that are
/// checked and turns off the ones that are not; "Not now" writes only that
/// choice. Main queue only.
@MainActor
final class SetupFlowModel: ObservableObject {
    /// The raw value is `EVLAT_SETUP`'s.
    enum Step: String, CaseIterable, Comparable {
        case agents, connected, bar, finish

        static func < (a: Step, b: Step) -> Bool { a.index < b.index }

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// The first step's items — one per agent in the catalogue — and the last
    /// step's: what "Connect" and "Finish" may write.
    static let agentItems = Set(Agents.all.ids.map(SetupItem.agent))
    static let finishItems: Set<SetupItem> = [.commandLink, .loginItem]

    /// One agent's tile on the first step.
    struct Tile: Identifiable, Equatable {
        enum Mood: Equatable {
            /// Set up already: drawn done, not to be touched.
            case done
            /// A switch: checked, it is written (or updated) by "Connect".
            case choice
            /// Neither written nor switchable: the agent's files cannot be read.
            case dim
        }

        enum Tone: Equatable { case plain, ok, caution }

        let source: AgentID
        let item: SetupItem
        let name: String
        let mood: Mood
        let selected: Bool
        let note: String?
        let tone: Tone

        var id: AgentID { source }
    }

    /// What the second step heard: the session the first event came from,
    /// by its folder, when the event named one.
    struct Heard: Equatable {
        let session: String?
    }

    /// One connected agent's row on the second step.
    struct Listening: Identifiable, Equatable {
        let source: AgentID
        let name: String
        let heard: Bool
        /// What it waits for, or what was heard.
        let line: String

        var id: AgentID { source }
    }

    /// A last-step row that is a switch.
    struct Switch: Equatable {
        let on: Bool
        /// Not Evlat's to touch (another program's file): the switch is
        /// drawn as it is and takes no press.
        let enabled: Bool
    }

    @Published private(set) var step: Step = .agents
    /// The agents written on this visit: the second step asks after exactly
    /// these. A row that was already connected, or whose write was refused,
    /// is not here.
    @Published private(set) var connected: Set<AgentID> = []
    /// The first event each connected agent sent since "Connect".
    @Published private(set) var heardFrom: [AgentID: Heard] = [:]
    /// Open sessions per agent, read when a step is entered.
    @Published private(set) var openSessions: [AgentID: Int] = [:]
    /// Whether another app's window is over the bar's edge, read once on
    /// entering the bar step and when the edge changes; `nil` says nothing.
    @Published private(set) var edgeCovered: Bool?
    /// Something was already connected when the flow opened: the first step
    /// reads as the user's connections, not as a welcome.
    @Published private(set) var reopened = false
    /// The last step's "Update automatically".
    @Published var autoUpdate = false
    /// Set-up items of the last step turned off: "Finish" takes them out.
    @Published private(set) var removals: Set<SetupItem> = []

    let setup: SetupModel
    /// Written by the controller when the language changes; the view
    /// observes it and draws again.
    @Published private(set) var lang: String
    /// Opens an install page, in the browser behind the app in front: the
    /// panel keeps the keyboard and stays out. A test holds it still.
    var openPage: (URL) -> Void = { BesidePanel.openBehind($0) }

    private let settings: SettingsModel.Host
    private let close: () -> Void
    /// The rows' changes, passed on: the step views observe this model, not
    /// the `SetupModel` under it, and a view whose inputs are the same
    /// reference is not drawn again by a change it does not observe.
    private var forwarding: AnyCancellable?
    /// The first run offers "Update automatically" on and writes what it
    /// shows; a reopened flow starts from what is set and writes a change.
    private var firstRun = false
    private var autoUpdateStart = false

    init(settings: SettingsModel.Host, setup: SetupModel, close: @escaping () -> Void,
         lang: String = L10n.language) {
        self.settings = settings
        self.setup = setup
        self.close = close
        self.lang = lang
        forwarding = setup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func t(_ key: String, _ values: [String: String] = [:]) -> String { L10n.t(key, values, in: lang) }

    func languageChanged(to language: String) {
        guard language != lang else { return }
        lang = language
        setup.languageChanged(to: language)
    }

    /// The flow opens (or opens again) at `step`: every row read fresh, the
    /// queue back to its defaults, nothing remembered from the last visit.
    /// `firstRun` is the setup that opened by itself for someone who has set
    /// nothing up (`AppController.openSetupAtLaunch`).
    func start(at step: Step = .agents, firstRun: Bool = false) {
        self.firstRun = firstRun
        connected = []
        heardFrom = [:]
        removals = []
        setup.reload()
        if let open = setup.manualOpen { setup.toggleManual(open) }
        // Everything there is to write, but "Open at login": that one is
        // off unless turned on, and so is an agent the user switched off.
        setup.queued = Set(setup.rows.filter { $0.action?.installs == true && $0.item != .loginItem && $0.enabled }
            .map(\.item))
        reopened = agentRows.contains { $0.status == .installed || $0.status == .outdated }
        // `EVLAT_SETUP=connected` opens the step for looking: what is set up
        // stands in for what this visit would have written.
        if step == .connected {
            connected = Set(agentRows.filter { $0.status == .installed }.compactMap(\.item.agent))
        }
        autoUpdateStart = firstRun ? true : currentAutoUpdate
        autoUpdate = autoUpdateStart
        readOpenSessions()
        edgeCovered = nil
        self.step = step
        // Opened onto the step (a look at it): the bar may have just come
        // on screen, and a window just ordered front is in the window list
        // after one turn like a moved one (measured: 0 of 40 reads right
        // away, 40 of 40 after one main-queue hop).
        if step == .bar { readEdgeCoverSoon() }
    }

    /// The panel closed: what only the second step holds goes, so nothing
    /// listens, and nothing turns in a panel nobody sees. Back to the first
    /// step, for the next time it opens.
    func panelClosed() {
        connected = []
        heardFrom = [:]
        step = .agents
    }

    // MARK: - Moving

    /// The ×: the panel folds into the mascot and nothing is written (what
    /// "Connect" and the switches wrote already stands).
    func dismiss() { close() }

    var showsBack: Bool { step != .agents }

    /// "Not now" is the first step's, and only while "Connect" has something
    /// to write.
    var showsSkip: Bool { step == .agents && !pendingWrites.isEmpty }

    /// The agents "Connect" would write now.
    var pendingWrites: [SetupItem] { setup.queuedWrites(only: Self.agentItems) }

    /// The primary button's title: what it does.
    var primaryKey: String {
        switch step {
        case .agents:
            let writes = pendingWrites
            if writes.isEmpty { return "setup.flow.continue" }
            return writes.allSatisfy { setup.row($0)?.action == .update } ? "setup.flow.update" : "setup.flow.connect"
        case .finish: return "setup.flow.finish"
        case .connected, .bar: return "setup.flow.continue"
        }
    }

    /// The primary button: "Connect" writes and moves on, "Finish" writes
    /// and closes, the rest move on.
    func primary() {
        switch step {
        case .agents:
            // A refused write stays on its tile, which says so.
            guard connect() else { return objectWillChange.send() }
            move(to: after(.agents))
        case .finish:
            finish()
        case .connected, .bar:
            move(to: after(step))
        }
    }

    /// "Not now": the next step, only the choice of agents written.
    func skip() {
        guard showsSkip else { return }
        chooseAgents()
        move(to: after(.agents))
    }

    /// "‹ Back": undoes nothing (the rows show what is set up).
    func back() {
        guard showsBack else { return }
        move(to: before(step))
    }

    /// The second step is only for agents this visit connected.
    private func after(_ step: Step) -> Step {
        var next = Step.allCases[min(step.index + 1, Step.allCases.count - 1)]
        if next == .connected && connected.isEmpty { next = .bar }
        return next
    }

    private func before(_ step: Step) -> Step {
        var previous = Step.allCases[max(step.index - 1, 0)]
        if previous == .connected && connected.isEmpty { previous = .agents }
        return previous
    }

    private func move(to target: Step) {
        guard target != step else { return }
        setup.reload()
        readOpenSessions()
        if target == .bar { readEdgeCover() }
        step = target
    }

    // MARK: - Agents

    private var agentRows: [SetupRow] { setup.rows.filter { Self.agentItems.contains($0.item) } }

    /// The agents found on this Mac, in the catalogue's order; one that is
    /// not here is never drawn.
    var tiles: [Tile] {
        agentRows.filter { $0.status != .notFound }.compactMap { row in
            guard let source = row.item.agent else { return nil }
            let count = openSessions[source] ?? 0
            func tile(_ mood: Tile.Mood, selected: Bool, _ note: String?, _ tone: Tile.Tone = .plain) -> Tile {
                Tile(source: source, item: row.item, name: row.name, mood: mood, selected: selected, note: note, tone: tone)
            }
            if row.status == .installed {
                // Written, and left unfollowed on purpose: not "Connected".
                if !row.enabled { return tile(.dim, selected: false, t("setup.flow.tile.off")) }
                return tile(.done, selected: true, t("setup.flow.tile.connected"), .ok)
            }
            guard row.action?.installs == true else {
                return tile(.dim, selected: false, t(row.status.key))
            }
            let note: String?
            let tone: Tile.Tone
            if row.failure != nil {
                note = t("setup.flow.tile.failed")
                tone = .caution
            } else if row.status == .outdated {
                note = t("setup.flow.tile.outdated")
                tone = .caution
            } else {
                note = count > 0 ? Self.sessionsText(count, t) : nil
                tone = .plain
            }
            return tile(.choice, selected: isQueued(row.item), note, tone)
        }
    }

    /// The same count the bar's summary says: "3 sessions".
    static func sessionsText(_ count: Int, _ t: (String, [String: String]) -> String) -> String {
        count == 1 ? t(SummaryLine.sessionsOneKey, [:]) : t(SummaryLine.sessionsKey, ["count": String(count)])
    }

    /// Every open session on the bar: the first step's sentence counts the
    /// rings it points at.
    var openSessionTotal: Int { openSessions.values.reduce(0, +) }

    func isQueued(_ item: SetupItem) -> Bool { setup.queued.contains(item) }

    func setQueued(_ item: SetupItem, _ on: Bool) {
        if on { setup.queued.insert(item) } else { setup.queued.remove(item) }
    }

    /// A last-step switch: while there is something to write it is the
    /// queue; once it is set up, off marks it for "Finish" to take out.
    func setSwitch(_ item: SetupItem, _ on: Bool) {
        guard setup.row(item)?.action == .remove else { return setQueued(item, on) }
        if on { removals.remove(item) } else { removals.insert(item) }
    }

    /// Where an agent that is not here is read about, for the first step
    /// when none is found.
    var installLinks: [ChatModel.InstallLink] { ChatModel.installLinks }

    func openInstallPage(_ link: ChatModel.InstallLink) { openPage(link.url) }

    /// "Connect": the choice of agents, then every checked write; the agents
    /// that now read as connected are the second step's. `false` when a write
    /// was refused.
    private func connect() -> Bool {
        chooseAgents()
        let writes = pendingWrites
        setup.applyQueue(only: Self.agentItems)
        var refused = false
        for item in writes {
            guard let source = item.agent else { continue }
            if setup.row(item)?.status == .installed { connected.insert(source) } else { refused = true }
        }
        return !refused
    }

    /// "Which agents do you use?" answered: a tile that offered its switch
    /// turns the agent on or off with it. A tile with nothing to write offered
    /// no choice and keeps the agent as it is. Only a change is written
    /// (`AppController.setEnabled`), so pressing on with what was found keeps
    /// the live default.
    private func chooseAgents() {
        for row in agentRows where row.action?.installs == true {
            guard let source = row.item.agent else { continue }
            let on = setup.queued.contains(row.item)
            if on != row.enabled { setup.choose(source, on) }
        }
    }

    private func readOpenSessions() { openSessions = settings.openSessions() }

    // MARK: - Connected

    /// The connected agents' rows, in the catalogue's order.
    var listening: [Listening] {
        agentRows.compactMap { row -> Listening? in
            guard let source = row.item.agent, connected.contains(source) else { return nil }
            let heard = heardFrom[source] != nil
            return Listening(source: source, name: row.name, heard: heard,
                             line: heard ? heardText(source) : ask(source))
        }
    }

    /// Every connected agent was heard.
    var allHeard: Bool { !connected.isEmpty && connected.allSatisfy { heardFrom[$0] != nil } }

    /// One event from this Mac's listener (`AppController.handleHookEvent`).
    /// Only the first from an agent this visit connected counts, and not
    /// Evlat's own chat turns, whose events carry a task.
    func heard(_ event: HookEvent) {
        guard connected.contains(event.source), event.taskID == nil, heardFrom[event.source] == nil else { return }
        let folder = event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        heardFrom[event.source] = Heard(session: folder.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 })
    }

    /// What a connected agent waits for: the agent's own line where the
    /// catalogue has one (`setup.flow.proof.<agent>`), else the general one
    /// by whether a session of it is open.
    private func ask(_ source: AgentID) -> String {
        let own = Self.proofKey(source)
        if L10n.catalog.tables[Catalog.source]?[own] != nil { return t(own) }
        return t((openSessions[source] ?? 0) > 0 ? "setup.flow.connected.ask.open" : "setup.flow.connected.ask.none")
    }

    /// What was heard, without a suffix on a name: Turkish, among others,
    /// would have to decline it.
    private func heardText(_ source: AgentID) -> String {
        guard let session = heardFrom[source]?.session else { return t("setup.flow.connected.heard") }
        return t("setup.flow.connected.heard.from", ["name": session])
    }

    static func proofKey(_ source: AgentID) -> String { "setup.flow.proof.\(source.rawValue)" }

    // MARK: - Bar

    var edge: BarPanel.Edge { settings.edge() }

    /// Applied to the bar at once (the controller's writer); the sentence
    /// about the edge is read again, for it is another edge now.
    func chooseEdge(_ edge: BarPanel.Edge) {
        guard edge != settings.edge() else { return }
        settings.setEdge(edge)
        readEdgeCoverSoon()
    }

    /// Always visible or Smart hide; another body mode, set in Settings, is
    /// neither selected nor kept from being picked.
    var visibility: BodyPresence.Mode { settings.bodyMode() }

    func chooseVisibility(_ mode: BodyPresence.Mode) {
        guard mode != settings.bodyMode() else { return }
        settings.setBodyMode(mode)
        objectWillChange.send()
    }

    private func readEdgeCover() { edgeCovered = settings.edgeCovered() }

    /// The bar moved by another way than this step's choice (the menu's
    /// edge, a screen): the sentence is read again if it is on screen.
    func barMoved() {
        guard step == .bar else { return }
        readEdgeCoverSoon()
    }

    /// The sentence is read once, one turn of the run loop from now, and says
    /// nothing meanwhile: the window list carries a moved bar's new bounds
    /// only after that turn (measured with a panel moved in its own process:
    /// none of 40 reads right after the move had them, 60 of 60 after one
    /// main-queue hop), and a read before it is of the edge the bar just
    /// left. One read, not a poll; asked again while one waits, it is that
    /// one.
    private func readEdgeCoverSoon() {
        edgeCovered = nil
        guard !coverRead else { return }
        coverRead = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coverRead = false
                if self.step == .bar { self.readEdgeCover() }
            }
        }
    }

    private var coverRead = false

    // MARK: - Finish

    /// The sound row is one switch for the two moments that wait on the user.
    var soundOn: Bool { settings.soundOn(.approval) && settings.soundOn(.answer) }

    func setSound(_ on: Bool) {
        guard on != soundOn else { return }
        settings.setSoundOn(on, .approval)
        settings.setSoundOn(on, .answer)
        objectWillChange.send()
    }

    /// The ▶: the tone a permission asks with.
    func previewSound() { settings.preview(.approval) }

    /// The login item and the command link: the switch is the queue while
    /// there is something to write, what "Finish" leaves of it once it is
    /// set up, and a still picture when it is not Evlat's to touch (another
    /// program's file at the link's path).
    func toggle(_ item: SetupItem) -> Switch? {
        guard let row = setup.row(item) else { return nil }
        switch row.action {
        case .install?, .update?: return Switch(on: isQueued(item), enabled: true)
        case .remove?: return Switch(on: !removals.contains(item), enabled: true)
        case nil: return Switch(on: row.status == .installed, enabled: false)
        }
    }

    /// With an updater, "Update automatically" is its install switch and the
    /// parts' one together; without (a development build, a second Evlat)
    /// only the parts'.
    var offersUpdater: Bool { settings.hasUpdater() }

    private var currentAutoUpdate: Bool {
        settings.hasUpdater() ? settings.automaticallyUpdates() && settings.keepsPartsCurrent()
                              : settings.keepsPartsCurrent()
    }

    /// "Finish": the login item and the link as checked, then the automatic
    /// updates as the row shows them — always on a first run (nothing stored
    /// reads as off, so the shown value is what makes it so), else only a
    /// change, so a mixed state is not closed without being asked.
    private func finish() {
        setup.applyQueue(only: Self.finishItems)
        // Settings' own press: the row's action, which for a set-up row is
        // taking it out.
        for item in removals where setup.row(item)?.action == .remove { setup.perform(item) }
        removals = []
        if firstRun || autoUpdate != autoUpdateStart {
            if settings.hasUpdater() { settings.setAutomaticallyUpdates(autoUpdate) }
            settings.setKeepsPartsCurrent(autoUpdate)
            firstRun = false
            autoUpdateStart = autoUpdate
        }
        close()
    }

    // MARK: - Catalogue

    static let keys: [String] = [
        "setup.flow.close", "setup.flow.who", "setup.flow.progress",
        "setup.flow.back", "setup.flow.skip", "setup.flow.connect", "setup.flow.update",
        "setup.flow.continue", "setup.flow.finish",
        "setup.flow.agents.title", "setup.flow.agents.title.again",
        "setup.flow.agents.text", "setup.flow.agents.text.one", "setup.flow.agents.text.none",
        "setup.flow.agents.text.again",
        "setup.flow.agents.note", "setup.flow.agents.note.done",
        "setup.flow.agents.none.title", "setup.flow.agents.none.text", "setup.flow.agents.none.note",
        "setup.flow.agents.install",
        "setup.flow.tile.connected", "setup.flow.tile.off", "setup.flow.tile.outdated", "setup.flow.tile.failed",
        "setup.flow.connected.title", "setup.flow.connected.title.heard",
        "setup.flow.connected.text", "setup.flow.connected.text.heard",
        "setup.flow.connected.ask.open", "setup.flow.connected.ask.none",
        "setup.flow.connected.heard", "setup.flow.connected.heard.from",
        "setup.flow.bar.title", "setup.flow.bar.place", "setup.flow.bar.visibility",
        "setup.flow.bar.left", "setup.flow.bar.right", "setup.flow.bar.always", "setup.flow.bar.smart",
        "setup.flow.bar.hint.smart", "setup.flow.bar.hint.covered",
        "setup.flow.finish.title", "setup.flow.finish.sound", "setup.flow.finish.sound.play",
        "setup.flow.finish.login", "setup.flow.finish.update", "setup.flow.finish.update.detail",
        "setup.flow.finish.update.detail.parts", "setup.flow.finish.command", "setup.flow.finish.command.detail",
        "setup.flow.finish.note",
        SummaryLine.sessionsKey, SummaryLine.sessionsOneKey,
        "setup.flow.manual.waiting",
        "settings.general.setup", "settings.general.setup.detail", "settings.general.setup.open",
    ] + Agents.all.ids.map(proofKey).filter { L10n.catalog.tables[Catalog.source]?[$0] != nil }
}
