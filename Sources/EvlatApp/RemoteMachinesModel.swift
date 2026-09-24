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
    }

    /// The line a finished job leaves under the buttons, and what the agents
    /// need after the write.
    struct Outcome: Equatable {
        let line: String
        let trouble: Bool
        let hints: [String]
    }

    /// The four fixed buttons. They do not read the server first (`plan.md` →
    /// Kapsam Dışı): the result line says what was there.
    enum Job: CaseIterable {
        case installHooks, removeHooks, installUsage, removeUsage

        var changes: [RemoteSettings.Change] {
            switch self {
            case .installHooks, .removeHooks: return [.hooks(.claude), .hooks(.codex)]
            case .installUsage, .removeUsage: return [.statusLine]
            }
        }

        var action: RemoteSettings.Action {
            switch self {
            case .installHooks, .installUsage: return .install
            case .removeHooks, .removeUsage: return .remove
            }
        }

        var titleKey: String {
            switch self {
            case .installHooks: return "remote.auto.hooks.install"
            case .removeHooks: return "remote.auto.hooks.remove"
            case .installUsage: return "remote.auto.usage.install"
            case .removeUsage: return "remote.auto.usage.remove"
            }
        }
    }

    enum SetupMode: Hashable { case automatic, manual }

    /// One block to paste, with the sentence above it.
    struct Block: Identifiable, Equatable {
        let id: String
        let captionKey: String
        let text: String
    }

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
    @Published var mode: SetupMode = .automatic
    /// The block whose button says "Copied", for a moment.
    @Published private(set) var copied: String?

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
                       status: status.text, advice: status.advice, tone: status.tone)
        }
        if fresh != rows { rows = fresh }
        if let selection, !fresh.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil, let first = fresh.first { selection = first.id }
        if let pending = confirmingRemoval, !fresh.contains(where: { $0.id == pending }) {
            confirmingRemoval = nil
        }
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

    // MARK: - Removing

    func askToRemove() {
        confirmingRemoval = selection
    }

    func cancelRemoval() {
        confirmingRemoval = nil
    }

    func confirmRemoval() {
        guard let id = confirmingRemoval else { return }
        confirmingRemoval = nil
        host.remove(id)
        outcomes[id] = nil
        reload()
    }

    // MARK: - Setup over ssh

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    func canRun(_ id: String) -> Bool { !busy.contains(id) && !installer.isBusy(id) }

    /// Runs `job` on the selected machine. A machine already running one
    /// refuses a second (the installer's rule, shown as disabled buttons).
    func run(_ job: Job) {
        guard let row = selectedRow, canRun(row.id) else { return }
        let id = row.id
        let started = installer.run(job.changes, job.action, machine: id, target: row.target) {
            [weak self] results in
            guard let self else { return }
            self.busy.remove(id)
            self.outcomes[id] = Self.outcome(results, job.action, in: self.lang)
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
        // The local entries' tooltips: what an agent needs after the write.
        var hints: [String] = []
        for (change, result) in results where result == .success(.written) {
            let key: String?
            switch (change, action) {
            case (.hooks(.claude), .install): key = "menu.hooks.hint.claude"
            case (.hooks(.codex), .install): key = "menu.hooks.hint.codex"
            case (.hooks(.codex), .remove): key = "menu.hooks.hint.remove"
            case (.statusLine, .install): key = "menu.usage.hint"
            case (.hooks(.claude), .remove), (.statusLine, .remove): key = nil
            }
            if let key { hints.append(L10n.t(key, in: lang)) }
        }
        return Outcome(line: line, trouble: trouble, hints: hints)
    }

    static func changeKey(_ change: RemoteSettings.Change) -> String {
        switch change {
        case .hooks(let source): return "source.\(source.rawValue)"
        case .statusLine: return "remote.change.usage"
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
        case .other: return "remote.failure.other"
        }
    }

    /// What to do about it.
    nonisolated static func adviceKey(_ failure: RemoteTunnel.Failure) -> String {
        failureKey(failure) + ".advice"
    }

    // MARK: - By hand

    /// The writers' own bytes (`RemoteSettings.manual`). The wrapper is shown
    /// as the JSON string it goes into, so it pastes as a `command` value.
    static let blocks: [Block] = {
        let manual = RemoteSettings.manual
        let wrapping = (try? JSONSerialization.data(withJSONObject: manual.wrapping,
                                                    options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? manual.wrapping
        return [
            Block(id: "claude", captionKey: "remote.manual.claude", text: manual.claudeHooks),
            Block(id: "codex", captionKey: "remote.manual.codex", text: manual.codexHooks),
            Block(id: "statusLine", captionKey: "remote.manual.statusLine", text: manual.statusLine),
            Block(id: "wrapping", captionKey: "remote.manual.wrapping", text: wrapping),
        ]
    }()

    /// Puts the block on the pasteboard; its button says so for a moment.
    func copy(_ block: Block) {
        pasteboard.clearContents()
        pasteboard.setString(block.text, forType: .string)
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
    /// (`source.*`, `summary.sessions*`, `time.*`, the local hints).
    static var keys: [String] {
        var keys = ["remote.window.title",
                    "remote.empty.title", "remote.empty.body", "remote.empty.requirement",
                    "remote.add.placeholder", "remote.add", "remote.add.duplicate",
                    "remote.environment",
                    "remote.state.stopped", "remote.state.connecting", "remote.state.connected",
                    "remote.state.connected.sessions", "remote.state.waiting", "remote.retry", "remote.retry.soon",
                    "remote.setup", "remote.setup.automatic", "remote.setup.manual", "remote.auto.body",
                    "remote.auto.busy", "remote.change.usage", "remote.result.part",
                    "remote.manual.body", "remote.manual.remove", "remote.manual.surface",
                    "remote.copy", "remote.copied",
                    "remote.remove", "remote.remove.confirm", "remote.remove.cancel", "remote.remove.do"]
        keys += [RemoteMachine.TargetProblem.empty, .option, .invalidCharacter].map(problemKey)
        keys += Job.allCases.map(\.titleKey)
        keys += blocks.map(\.captionKey)
        let failures: [RemoteTunnel.Failure] = [.authentication, .portBusy, .hostKey, .hostName, .unreachable, .other]
        keys += failures.map(failureKey) + failures.map(adviceKey)
        let results: [RemoteInstaller.Result] = [
            .success(.written), .success(.unchanged),
            .failure(.file(.unreadable)), .failure(.file(.malformed)), .failure(.file(.noDirectory)),
            .failure(.file(.changedUnderneath)), .failure(.file(.unwritable)), .failure(.unreachable),
        ]
        for action in [RemoteSettings.Action.install, .remove] {
            keys += results.map { resultKey($0, action) }
        }
        return Array(Set(keys)).sorted()
    }
}
