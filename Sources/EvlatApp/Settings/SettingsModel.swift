import AppKit
import EvlatCore

/// The settings window's state: which section is open, the
/// dots of the sections that want attention, and the few things the rows'
/// shared model does not hold — the edge, the shortcut, the next chats'
/// mode, `claude`'s place and the memory's inline confirmation.
///
/// It composes rather than repeats: the install rows are `SetupModel`'s,
/// the machines `RemoteMachinesModel`'s, the shortcut row's keys
/// `HotKeyRecorder`'s. The app is reached through `Host`, closures that are
/// the controller's writers (`AppController.settingsHost`). Main queue only.
@MainActor
final class SettingsModel: ObservableObject {
    typealias Section = SetupAttention.Section

    struct Host {
        var edge: () -> BarPanel.Edge
        var setEdge: (BarPanel.Edge) -> Void
        var isHotKeyOn: () -> Bool
        var setHotKey: (Bool) -> Void
        var hotKey: () -> HotKeyCombination
        var defaultMode: () -> PermissionMode
        var setDefaultMode: (PermissionMode) -> Void
        /// `claude`'s path, or `nil` when there is none; called back on the
        /// main queue.
        var locateClaude: (@escaping (String?) -> Void) -> Void
        /// What the chats' memory folder holds; `nil` when there is no chat
        /// store (every test that does not hand one).
        var memoryCount: () -> Int?
        var showMemory: () -> Void
        var clearMemory: () -> Void
        /// General's "Open Setup…".
        var openSetup: () -> Void = {}
        /// General's "Body": the mode in force and its three switches.
        var bodyMode: () -> BodyPresence.Mode = { .always }
        var setBodyMode: (BodyPresence.Mode) -> Void = { _ in }
        var bodyToggles: () -> BodyPresence.Toggles = { BodyPresence.Toggles() }
        var setBodyToggles: (BodyPresence.Toggles) -> Void = { _ in }
    }

    /// Where `claude` is, once looked for.
    enum Claude: Equatable {
        case looking
        case found(String)
        case missing
    }

    /// Leaving Chat stops a recording: out of sight it would take the
    /// keys typed in another section.
    @Published var section: Section = .general {
        didSet { if section != oldValue { recorder.cancel() } }
    }
    @Published private(set) var claude: Claude = .looking
    @Published private(set) var memoryCount: Int?
    /// "Clear…" was pressed: the row asks in place (no `NSAlert`).
    @Published private(set) var confirmingClear = false

    let setup: SetupModel
    let remote: RemoteMachinesModel
    let recorder: HotKeyRecorder
    private let host: Host
    let lang: String

    init(host: Host, setup: SetupModel, remote: RemoteMachinesModel, recorder: HotKeyRecorder,
         lang: String = L10n.language) {
        self.host = host
        self.setup = setup
        self.remote = remote
        self.recorder = recorder
        self.lang = lang
        memoryCount = host.memoryCount()
    }

    func t(_ key: String, _ values: [String: String] = [:]) -> String { L10n.t(key, values, in: lang) }

    /// The window opens: every section reads fresh.
    func reload() {
        setup.reload()
        remote.reload()
        memoryCount = host.memoryCount()
        confirmingClear = false
        host.locateClaude { [weak self] path in
            self?.claude = path.map(Claude.found) ?? .missing
            // The lookup reads the login shell's `PATH`, which the command
            // link's "not on your PATH" note is made from: read above, the
            // first opening had none yet.
            self?.setup.reload()
        }
    }

    /// The side list's dots: each section something in the attention list
    /// (`SetupModel.attention`, the menu's dim lines) belongs to.
    var dots: Set<Section> { Set(setup.attention.map(\.section)) }

    // MARK: - General

    var edge: BarPanel.Edge { host.edge() }

    func setEdge(_ edge: BarPanel.Edge) {
        guard edge != host.edge() else { return }
        host.setEdge(edge)
        objectWillChange.send()
    }

    var bodyMode: BodyPresence.Mode { host.bodyMode() }
    var bodyToggles: BodyPresence.Toggles { host.bodyToggles() }

    func setBodyMode(_ mode: BodyPresence.Mode) {
        guard mode != host.bodyMode() else { return }
        host.setBodyMode(mode)
        objectWillChange.send()
    }

    func setBodyToggle(_ toggle: WritableKeyPath<BodyPresence.Toggles, Bool>, on: Bool) {
        var toggles = host.bodyToggles()
        guard toggles[keyPath: toggle] != on else { return }
        toggles[keyPath: toggle] = on
        host.setBodyToggles(toggles)
        objectWillChange.send()
    }

    /// The switches shape only Smart: Always has nothing to hide, Hidden
    /// has neither the sliver nor a peek.
    var showsBodyToggles: Bool { bodyMode == .smart }

    /// Without the waiting peek, waiting is told only by the sliver's amber
    /// dot — said beside the switch, so the loss is chosen, not stumbled on.
    var showsPeekWarning: Bool { showsBodyToggles && !bodyToggles.peekWaiting }

    // MARK: - Chat

    var isHotKeyOn: Bool { host.isHotKeyOn() }
    var hotKey: HotKeyCombination { host.hotKey() }

    func setHotKey(on: Bool) {
        if recorder.isRecording { recorder.cancel() }
        host.setHotKey(on)
        // A refused registration is a dot on this section.
        setup.reload()
        objectWillChange.send()
    }

    /// "Change" / "Cancel" beside the shortcut.
    func toggleRecording() {
        if recorder.isRecording { recorder.cancel() } else { recorder.start() }
        objectWillChange.send()
    }

    /// The modes are offered only when there is a `claude` to run them.
    var showsModes: Bool {
        if case .found = claude { return true }
        return false
    }

    var mode: PermissionMode { host.defaultMode() }

    /// The next chats' mode; an open chat keeps its own (`setDefaultMode`).
    func setMode(_ mode: PermissionMode) {
        host.setDefaultMode(mode)
        objectWillChange.send()
    }

    func showMemory() { host.showMemory() }

    func openSetup() { host.openSetup() }

    func askToClear() {
        guard (memoryCount ?? 0) > 0 else { return }
        confirmingClear = true
    }

    func cancelClear() { confirmingClear = false }

    /// Only after "Clear…" asked: nothing is removed by one press.
    func confirmClear() {
        guard confirmingClear else { return }
        confirmingClear = false
        host.clearMemory()
        memoryCount = host.memoryCount()
    }

    // MARK: - The window's keys

    /// Esc: an open question is answered first ("no"), then the window
    /// closes. A recording takes Esc before this (`AppKeyWindow`).
    func cancelInside() -> Bool {
        if confirmingClear { confirmingClear = false; return true }
        if remote.confirmingRemoval != nil { remote.cancelRemoval(); return true }
        return false
    }

    /// The window closed or lost the keyboard to another app.
    func windowClosed() {
        recorder.cancel()
        remote.cancelRemoval()
        confirmingClear = false
    }

    /// Called at each refresh while the window is on screen: the machines'
    /// lines follow their tunnels, and a machine going down is a dot.
    func follow() {
        remote.reload()
        setup.reloadIfMachinesChanged()
    }

    // MARK: - Catalogue

    static func titleKey(_ section: Section) -> String { "settings.section.\(section.rawValue)" }

    /// `~/…` for a path under the home.
    nonisolated static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static let keys: [String] = Section.allCases.map(titleKey) + [
        "settings.window.title",
        "settings.general.bar", "settings.general.edge", "settings.general.edge.detail",
        "settings.general.edge.left", "settings.general.edge.right", "settings.general.start",
        "settings.general.body", "settings.general.body.detail", "settings.general.body.always",
        "settings.general.body.smart", "settings.general.body.hidden",
        "settings.general.body.sliver", "settings.general.body.sliver.detail",
        "settings.general.body.peekWaiting", "settings.general.body.peekWaiting.detail",
        "settings.general.body.peekWaiting.off",
        "settings.general.body.peekDone", "settings.general.body.peekDone.detail",
        "settings.sessions.agents", "settings.sessions.agents.note", "settings.sessions.usage",
        "settings.sessions.none",
        "settings.chat.open", "settings.chat.hotkey", "settings.chat.hotkey.detail",
        "settings.chat.hotkey.change", "settings.chat.hotkey.cancel", "settings.chat.hotkey.recording",
        "settings.chat.hotkey.off",
        "settings.chat.modes", "settings.chat.modes.note", "settings.chat.modes.recommended",
        "settings.chat.claude.found", "settings.chat.claude.missing", "settings.chat.claude.looking",
        "settings.chat.memory", "settings.chat.memory.title", "settings.chat.memory.count",
        "settings.chat.memory.one", "settings.chat.memory.empty", "settings.chat.memory.show",
        "settings.chat.memory.clear", "settings.chat.memory.confirm", "settings.chat.memory.confirm.detail",
        "settings.chat.memory.cancel", "settings.chat.memory.do",
        "settings.command.title", "settings.command.examples", "settings.command.watch",
        "settings.command.watch.detail", "settings.command.signal", "settings.command.signal.detail",
        "settings.command.note",
        "settings.attention",
        "settings.remote.machines", "settings.remote.note", "settings.remote.open", "settings.remote.closed",
        "settings.remote.usage.detail", "settings.remote.command.detail",
        "settings.remote.retry", "settings.remote.close",
        "settings.remote.what.command", "settings.remote.what.command.remove",
        "settings.remote.what.key", "settings.remote.what.key.remove",
        "settings.remote.path.status", "settings.remote.path.note", "settings.remote.path.stillOff",
        "settings.remote.path.add", "settings.remote.what.path", "settings.remote.what.path.remove",
        "settings.remote.path.manual", "settings.remote.path.manual.remove",
    ]
}
