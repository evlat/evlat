import AppKit
import EvlatCore

/// The setup window's state: which of
/// the six steps is on, what the setup's two pressing buttons write, and
/// the still mascot at the top.
///
/// It composes rather than repeats, like `SettingsModel`: the rows are a
/// `SetupModel` of its own (its queue is this window's, never the settings
/// window's), the chat step's shortcut and modes go through the settings'
/// `Host` — the controller's writers — and the recorder is the one recorder.
///
/// Going back never undoes anything: the rows read their state again and
/// what was set up shows a ✓. Only two buttons write — "Install" on the
/// sessions step, "Finish" on the optional one — and each writes exactly
/// the lines listed above it (R3). Main queue only.
@MainActor
final class SetupFlowModel: ObservableObject {
    /// The raw value is `EVLAT_SETUP`'s.
    enum Step: String, CaseIterable, Comparable {
        case hello, edge, sessions, chat, optional, done

        static func < (a: Step, b: Step) -> Bool { a.index < b.index }

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// A line of the last step's summary.
    struct SummaryLine: Equatable, Hashable {
        enum Mark { case done, pending, skipped }
        let mark: Mark
        let text: String
    }

    /// The sessions step's items, and the optional step's: what "Install"
    /// and "Finish" may write.
    static let sessionItems: Set<SetupItem> = [.claudeHooks, .usageRelay, .codexHooks]
    static let optionalItems: Set<SetupItem> = [.commandLink, .loginItem]

    @Published private(set) var step: Step = .hello
    /// Bumped for each blink: choosing an edge, arriving at the edge step
    /// and at the last one. The mascot blinks on a change of it, never on
    /// its own — an idle window draws nothing.
    @Published private(set) var blinks = 0
    /// "Install" was pressed on this visit: the hint about open sessions.
    @Published private(set) var installed = false
    @Published private(set) var claude: SettingsModel.Claude = .looking

    let setup: SetupModel
    let recorder: HotKeyRecorder
    /// The setup's own mascot: its gaze is the chosen edge's and nothing
    /// moves it — no `GazeTracker`, no clip.
    let mascot = MascotModel()
    let lang: String
    private let settings: SettingsModel.Host
    private let close: () -> Void

    init(settings: SettingsModel.Host, setup: SetupModel, recorder: HotKeyRecorder,
         close: @escaping () -> Void, lang: String = L10n.language) {
        self.settings = settings
        self.setup = setup
        self.recorder = recorder
        self.close = close
        self.lang = lang
    }

    func t(_ key: String, _ values: [String: String] = [:]) -> String { L10n.t(key, values, in: lang) }

    /// The window opens (or opens again) at `step`: every row read fresh,
    /// the queue back to its defaults, `claude` looked for.
    func start(at step: Step = .hello) {
        recorder.cancel()
        installed = false
        setup.reload()
        if let open = setup.manualOpen { setup.toggleManual(open) }
        // Everything there is to write, but "Open at login": that one is
        // off unless turned on (R5).
        setup.queued = Set(setup.rows.filter { $0.action?.installs == true && $0.item != .loginItem }.map(\.item))
        look()
        self.step = step
        if step == .edge || step == .done { blinks += 1 }
        settings.locateClaude { [weak self] path in
            self?.claude = path.map(SettingsModel.Claude.found) ?? .missing
            // The login `PATH` for the command link's note (`SettingsModel.reload`).
            self?.setup.reload()
        }
    }

    // MARK: - Moving

    var showsBack: Bool { step != .hello && step != .done }
    var showsSkip: Bool { step != .hello && step != .done }

    /// The primary button's title.
    var primaryKey: String {
        switch step {
        case .hello: return "setup.flow.start"
        case .sessions: return installConsent.isEmpty ? "setup.flow.continue" : "setup.flow.install"
        case .optional: return "setup.flow.finish"
        case .done: return "setup.flow.close"
        case .edge, .chat: return "setup.flow.continue"
        }
    }

    /// The primary button: "Install" writes and stays; "Finish" writes and
    /// moves on; "Close" closes; the rest move on.
    func primary() {
        switch step {
        case .sessions where !installConsent.isEmpty:
            setup.applyQueue(only: Self.sessionItems)
            installed = true
        case .optional:
            setup.applyQueue(only: Self.optionalItems)
            move(to: .done)
        case .done:
            close()
        default:
            move(to: Self.after(step))
        }
    }

    /// The stage's close button: the setup goes, whatever step it is on,
    /// with nothing more written.
    func dismiss() {
        close()
    }

    /// "Not now": the next step, nothing written.
    func skip() {
        guard showsSkip else { return }
        move(to: Self.after(step))
    }

    /// "‹ Back": undoes nothing (the rows show what is set up).
    func back() {
        guard showsBack, let previous = Step.allCases.last(where: { $0 < step }) else { return }
        move(to: previous)
    }

    /// A passed dot.
    func canGo(to target: Step) -> Bool { target < step && step != .done }

    func go(to target: Step) {
        guard canGo(to: target) else { return }
        move(to: target)
    }

    private static func after(_ step: Step) -> Step {
        Step.allCases.first { $0 > step } ?? .done
    }

    private func move(to target: Step) {
        guard target != step else { return }
        recorder.cancel()
        setup.reload()
        step = target
        if target == .edge || target == .done { blinks += 1 }
    }

    // MARK: - Edge

    var edge: BarPanel.Edge { settings.edge() }

    /// Applied to the bar at once (the controller's writer), the mascot
    /// turning to it with one blink.
    func chooseEdge(_ edge: BarPanel.Edge) {
        guard edge != settings.edge() else { return }
        settings.setEdge(edge)
        look()
        blinks += 1
        objectWillChange.send()
    }

    /// The gaze is the edge's, and it moves only here.
    private func look() {
        let gaze = CGSize(width: settings.edge().isLeft ? -1 : 1, height: 0)
        if mascot.gaze != gaze { mascot.gaze = gaze }
    }

    // MARK: - Rows and what they write

    /// The sessions step's rows, in the setup model's order.
    var sessionRows: [SetupRow] { setup.rows.filter { Self.sessionItems.contains($0.item) } }

    func isQueued(_ item: SetupItem) -> Bool { setup.queued.contains(item) }

    func setQueued(_ item: SetupItem, _ on: Bool) {
        if on { setup.queued.insert(item) } else { setup.queued.remove(item) }
    }

    /// Above "Install": what it writes, one line per file.
    var installConsent: [String] { setup.queueConsent(only: Self.sessionItems) }
    /// Above "Finish".
    var finishConsent: [String] { setup.queueConsent(only: Self.optionalItems) }

    // MARK: - Chat

    var showsModes: Bool {
        if case .found = claude { return true }
        return false
    }

    var mode: PermissionMode { settings.defaultMode() }

    /// The next chats' mode; an open chat keeps its own.
    func setMode(_ mode: PermissionMode) {
        settings.setDefaultMode(mode)
        objectWillChange.send()
    }

    var isHotKeyOn: Bool { settings.isHotKeyOn() }
    var hotKey: HotKeyCombination { settings.hotKey() }

    func toggleRecording() {
        if recorder.isRecording { recorder.cancel() } else { recorder.start() }
        objectWillChange.send()
    }

    // MARK: - Done

    /// What the setup leaves behind, read from the rows as they are now.
    var summary: [SummaryLine] {
        var lines = [SummaryLine(mark: .done, text: t(edge.isLeft ? "setup.flow.summary.left" : "setup.flow.summary.right"))]
        for item in [SetupItem.claudeHooks, .usageRelay, .codexHooks] {
            guard let row = setup.row(item) else { continue }
            let name = t("setup.flow.summary.\(item.rawValue)")
            if row.status == .installed || row.status == .outdated {
                lines.append(SummaryLine(mark: .done, text: name))
            } else if setup.manualOpen == item {
                lines.append(SummaryLine(mark: .pending, text: t("setup.flow.summary.manual", ["item": name])))
            } else if item != .usageRelay {
                lines.append(SummaryLine(mark: .skipped, text: t("setup.flow.summary.skipped", ["item": name])))
            }
        }
        if isHotKeyOn {
            let chat = showsModes
                ? t("setup.flow.summary.chat.mode", ["key": hotKey.title, "mode": t(Self.modeSummaryKey(mode))])
                : t("setup.flow.summary.chat", ["key": hotKey.title])
            lines.append(SummaryLine(mark: .done, text: chat))
        }
        if setup.row(.loginItem)?.status == .installed {
            lines.append(SummaryLine(mark: .done, text: t("setup.flow.summary.login")))
        }
        if setup.row(.commandLink)?.status == .installed {
            lines.append(SummaryLine(mark: .done, text: t("setup.flow.summary.command")))
        } else if setup.manualOpen == .commandLink {
            lines.append(SummaryLine(mark: .pending, text: t("setup.flow.summary.command.manual")))
        }
        return lines
    }

    static func modeSummaryKey(_ mode: PermissionMode) -> String { "setup.flow.summary.mode.\(mode.rawValue)" }

    // MARK: - The window's keys

    /// ← and → choose the edge on its step; the recorder takes every key
    /// while it records (before this).
    func handleKey(_ event: NSEvent) -> Bool {
        if recorder.handle(event) { return true }
        guard step == .edge,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 123: chooseEdge(.left); return true
        case 124: chooseEdge(.right); return true
        default: return false
        }
    }

    /// The window closed or lost the keyboard: a recording stops.
    func windowClosed() { recorder.cancel() }

    // MARK: - Catalogue

    static func titleKey(_ step: Step) -> String { "setup.flow.\(step.rawValue).title" }

    static let keys: [String] = Step.allCases.map(titleKey) + [
        "setup.window.title", "setup.flow.back", "setup.flow.skip", "setup.flow.step",
        "setup.flow.start", "setup.flow.continue", "setup.flow.install", "setup.flow.finish", "setup.flow.close",
        "setup.flow.manual.waiting",
        "setup.flow.hello.body", "setup.flow.hello.note",
        "setup.flow.edge.body", "setup.flow.edge.left", "setup.flow.edge.right",
        "setup.flow.sessions.body", "setup.flow.sessions.none", "setup.flow.sessions.hint",
        "setup.flow.chat.body", "setup.flow.chat.hotkey.detail",
        "setup.flow.remote", "setup.flow.remote.detail", "setup.flow.remote.later",
        "setup.flow.done.note",
        "setup.flow.summary.left", "setup.flow.summary.right",
        "setup.flow.summary.claudeHooks", "setup.flow.summary.usageRelay", "setup.flow.summary.codexHooks",
        "setup.flow.summary.manual", "setup.flow.summary.skipped",
        "setup.flow.summary.chat", "setup.flow.summary.chat.mode",
        "setup.flow.summary.login", "setup.flow.summary.command", "setup.flow.summary.command.manual",
        "settings.general.setup", "settings.general.setup.detail", "settings.general.setup.open",
        "setup.story.close", "setup.story.demo.1", "setup.story.demo.2", "setup.story.demo.3",
        "setup.story.chat.file", "setup.story.chat.prompt",
    ] + [PermissionMode.auto, .acceptEdits, .ask].map(modeSummaryKey)
}
