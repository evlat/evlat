import AppKit
import EvlatCore
import EvlatAgents

/// The settings window's state: which section is open, the
/// dots of the sections that want attention, and the few things the rows'
/// shared model does not hold — the edge, the shortcut, the next chats'
/// mode, the chat program's place and the memory's inline confirmation.
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
        /// General's "Screen": the connected screens (main first), the
        /// pinned one with its name (`nil` is the main screen), and its writer.
        var displays: () -> [BarDisplay] = { [] }
        var display: () -> (id: String, name: String)? = { nil }
        var setDisplay: (String?) -> Void = { _ in }
        /// General's "Language": the table chosen (`nil` is the system's),
        /// its writer, and what the system's alone would draw in.
        var language: () -> String? = { nil }
        var setLanguage: (String?) -> Void = { _ in }
        var systemLanguage: () -> String = { L10n.catalog.resolve(preferred: Locale.preferredLanguages) }
        var isHotKeyOn: () -> Bool
        var setHotKey: (Bool) -> Void
        var hotKey: () -> HotKeyCombination
        /// Every backend a chat can run on, in the catalogue's order.
        var chatBackends: () -> [any ChatBackend] = { Agents.chatBackends }
        /// The new chats' backend: its modes and its program's name.
        var chatBackend: () -> any ChatBackend = { Agents.chatBackends[0] }
        var setChatBackend: (AgentID) -> Void = { _ in }
        /// The selected backend's mode for new chats, and its writer.
        var defaultMode: () -> ChatMode
        var setDefaultMode: (ChatMode) -> Void
        /// A backend's program's path, or `nil` when there is none; called
        /// back on the main queue.
        var locateBackend: (AgentID, @escaping (String?) -> Void) -> Void
        /// The version a backend's last turn reported, if one did.
        var chatVersion: (AgentID) -> String? = { _ in nil }
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
        /// Agents' "Git branch": when a session's branch is drawn.
        var branchDisplay: () -> BranchDisplay = { .auto }
        var setBranchDisplay: (BranchDisplay) -> Void = { _ in }
        /// General's "Waiting reminder": minutes, 0 is off.
        var nudgeMinutes: () -> Int = { 0 }
        var setNudgeMinutes: (Int) -> Void = { _ in }
        /// Mascot → Sounds: who speaks, the characters installed, each
        /// moment's switch and Evlat's tone for it, the ▶ and the volume.
        var voice: () -> SoundVoice = { .evlat }
        var setVoice: (SoundVoice) -> Void = { _ in }
        var packs: () -> [SoundPack] = { [] }
        var voicePack: () -> SoundPack? = { nil }
        var nudgeScope: () -> NudgeScope = { .waits }
        var setNudgeScope: (NudgeScope) -> Void = { _ in }
        var soundOn: (SoundMoment) -> Bool = { _ in false }
        var setSoundOn: (Bool, SoundMoment) -> Void = { _, _ in }
        var tone: (SoundMoment) -> AlertSound = { $0.defaultTone }
        var setTone: (AlertSound, SoundMoment) -> Void = { _, _ in }
        var canSpeak: (SoundMoment) -> Bool = { _ in true }
        var preview: (SoundMoment) -> Void = { _ in }
        var soundVolume: () -> Double = { 1 }
        var setSoundVolume: (Double) -> Void = { _ in }
        /// macOS's alert sounds, offered after Evlat's own.
        var systemSounds: () -> [String] = { AlertSound.installedSystemNames }
        /// The characters sheet; `nil` with no home or in an isolated
        /// process, which download nothing.
        var packBrowser: () -> SoundPackBrowser? = { nil }
        /// Usage's switch: leave out what was not seen for the hour.
        var hidesStaleUsage: () -> Bool = { false }
        var setHidesStaleUsage: (Bool) -> Void = { _ in }
        var nudgeNotify: () -> Bool = { false }
        /// Turning it on asks macOS; the completion says whether it is on.
        var setNudgeNotify: (Bool, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
        /// Whether Evlat's notifications are off in System Settings.
        var notificationsDenied: (@escaping (Bool) -> Void) -> Void = { $0(false) }
        /// The sandbox listener's state (`AppController.sandboxState`).
        var sandboxState: () -> SandboxState = { .off }
    }

    /// The sandbox listener as the status line tells it.
    enum SandboxState: Equatable {
        /// This process has no sandbox listener (`SandboxListener.port`).
        case off
        case starting
        /// Another program holds the port.
        case taken(UInt16)
        /// Listening; the sandboxes heard since launch, by name, sorted.
        case listening(UInt16, heard: [String])
    }

    /// Where the chat backend's program is, once looked for.
    enum Location: Equatable {
        case looking
        case found(String)
        case missing
    }

    /// Leaving Chat stops a recording: out of sight it would take the
    /// keys typed in another section.
    @Published var section: Section = .general {
        didSet { if section != oldValue { recorder.cancel() } }
    }
    /// Where each chat backend's program is, by its id; one not asked yet
    /// is `.looking`.
    @Published private(set) var locations: [AgentID: Location] = [:]
    @Published private(set) var memoryCount: Int?
    /// "Clear…" was pressed: the row asks in place (no `NSAlert`).
    @Published private(set) var confirmingClear = false
    /// Evlat's notifications are off in System Settings: the reminder's
    /// notification row says so and links there.
    @Published private(set) var notificationsDenied = false
    /// The sandbox listener's state; written only when it changes, since a
    /// hook can change it at event rate (`follow`).
    @Published private(set) var sandboxState: SandboxState = .off

    let setup: SetupModel
    let remote: RemoteMachinesModel
    let recorder: HotKeyRecorder
    private let host: Host
    /// The language the window draws in; the controller writes it when the
    /// choice changes (`languageChanged(to:)`), and every row reads it again.
    @Published private(set) var lang: String

    init(host: Host, setup: SetupModel, remote: RemoteMachinesModel, recorder: HotKeyRecorder,
         lang: String = L10n.language) {
        self.host = host
        self.setup = setup
        self.remote = remote
        self.recorder = recorder
        self.lang = lang
        memoryCount = host.memoryCount()
        sandboxState = host.sandboxState()
    }

    func t(_ key: String, _ values: [String: String] = [:]) -> String { L10n.t(key, values, in: lang) }

    /// The text's language changed: the composed models make their lines
    /// again, and the window — observing `lang` — draws them.
    func languageChanged(to language: String) {
        guard language != lang else { return }
        lang = language
        setup.languageChanged(to: language)
        remote.languageChanged(to: language)
    }

    /// The window opens: every section reads fresh.
    func reload() {
        setup.reload()
        remote.reload()
        memoryCount = host.memoryCount()
        confirmingClear = false
        followSandbox()
        host.notificationsDenied { [weak self] in self?.notificationsDenied = $0 }
        for backend in host.chatBackends() {
            let id = backend.id
            host.locateBackend(id) { [weak self] path in
                self?.locations[id] = path.map(Location.found) ?? .missing
                // The lookup reads the login shell's `PATH`, which the command
                // link's "not on your PATH" note is made from: read above, the
                // first opening had none yet.
                self?.setup.reload()
            }
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

    /// One entry of the screen picker. `id` `nil` is the main screen.
    struct DisplayChoice: Equatable, Identifiable {
        let id: String?
        let title: String
    }

    /// The screen row is shown only when there is a choice: more than one
    /// screen, or a pinned one that is unplugged. One screen is no choice.
    var showsDisplay: Bool {
        host.displays().count > 1 || (host.display().map { pin in
            !host.displays().contains { $0.id == pin.id }
        } ?? false)
    }

    /// The main screen, each connected one by name (a repeated name
    /// numbered), and the pinned one while it is unplugged — said so, and
    /// still selected, so the picker never shows a choice that is not stored.
    var displayChoices: [DisplayChoice] {
        let connected = host.displays()
        var choices = [DisplayChoice(id: nil, title: t("settings.general.display.main"))]
        choices += zip(connected, BarDisplay.titles(connected)).map { DisplayChoice(id: $0.id, title: $1) }
        if let pin = host.display(), !connected.contains(where: { $0.id == pin.id }) {
            choices.append(DisplayChoice(id: pin.id, title: t("settings.general.display.missing", ["name": pin.name])))
        }
        return choices
    }

    var display: String? { host.display()?.id }

    /// "Language": the system's first, named with what it resolves to now,
    /// then every table by its own name, sorted as names are.
    struct LanguageOption: Equatable, Identifiable {
        /// `nil`: the system's.
        let id: String?
        let title: String
    }

    var languageOptions: [LanguageOption] {
        let catalog = L10n.catalog
        let tables = catalog.available
            .map { LanguageOption(id: $0, title: catalog.name(of: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let system = t("settings.general.language.system", ["language": catalog.name(of: host.systemLanguage())])
        return [LanguageOption(id: nil, title: system)] + tables
    }

    var language: String? { host.language() }

    func setLanguage(_ language: String?) {
        guard language != host.language() else { return }
        host.setLanguage(language)
        objectWillChange.send()
    }

    func setDisplay(_ id: String?) {
        guard id != host.display()?.id else { return }
        host.setDisplay(id)
        objectWillChange.send()
    }

    /// Whether the bar, where it is now — the pinned screen if connected,
    /// else the main one — sits on a seam between two screens.
    var displayOnSeam: Bool {
        let connected = host.displays()
        guard let screen = BarDisplay.chosen(display, among: connected) else { return false }
        return BarDisplay.hasNeighbour(beyond: edge, of: screen, among: connected)
    }

    /// A screen came or went: the row lists what is connected now.
    func screensChanged() { objectWillChange.send() }

    var branchDisplay: BranchDisplay { host.branchDisplay() }

    func setBranchDisplay(_ display: BranchDisplay) {
        guard display != host.branchDisplay() else { return }
        host.setBranchDisplay(display)
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

    var nudgeMinutes: Int { host.nudgeMinutes() }

    func setNudgeMinutes(_ minutes: Int) {
        guard minutes != host.nudgeMinutes() else { return }
        host.setNudgeMinutes(minutes)
        objectWillChange.send()
    }

    /// The notification rests while waits are not reminded of.
    var reminds: Bool { nudgeMinutes != 0 }

    /// "After {n} min" or "Off".
    func nudgeTitle(_ minutes: Int) -> String {
        minutes == 0 ? t("settings.general.nudge.off")
                     : t("settings.general.nudge.minutes", ["n": String(minutes)])
    }

    var nudgeScope: NudgeScope { host.nudgeScope() }

    func setNudgeScope(_ scope: NudgeScope) {
        guard scope != host.nudgeScope() else { return }
        host.setNudgeScope(scope)
        objectWillChange.send()
    }

    // MARK: - Mascot → Sounds

    var voice: SoundVoice { host.voice() }

    func setVoice(_ voice: SoundVoice) {
        guard voice != host.voice() else { return }
        host.setVoice(voice)
        objectWillChange.send()
    }

    struct VoiceOption: Hashable, Identifiable {
        let voice: SoundVoice
        let title: String
        var id: String { voice.stored }
    }

    /// The characters installed, by name; Evlat itself is the menu's first
    /// line, apart.
    var characterOptions: [VoiceOption] {
        host.packs().map { VoiceOption(voice: .pack($0.name), title: $0.displayName) }
    }

    /// The speaking character, `nil` for Evlat (or a character gone).
    var voicePack: SoundPack? { host.voicePack() }

    var voiceTitle: String { voicePack?.displayName ?? t("settings.mascot.voice.evlat") }

    var voiceDetail: String {
        voicePack == nil ? t("settings.mascot.voice.evlat.detail") : t("settings.mascot.voice.pack.detail")
    }

    func soundOn(_ moment: SoundMoment) -> Bool { host.soundOn(moment) }

    func setSoundOn(_ on: Bool, for moment: SoundMoment) {
        guard on != host.soundOn(moment) else { return }
        host.setSoundOn(on, moment)
        objectWillChange.send()
    }

    func tone(_ moment: SoundMoment) -> AlertSound { host.tone(moment) }

    func setTone(_ tone: AlertSound, for moment: SoundMoment) {
        host.setTone(tone, moment)
        objectWillChange.send()
    }

    func canSpeak(_ moment: SoundMoment) -> Bool { host.canSpeak(moment) }

    func preview(_ moment: SoundMoment) { host.preview(moment) }

    struct ToneOption: Hashable, Identifiable {
        let tone: AlertSound
        let title: String
        var id: String { tone.stored ?? title }
    }

    /// Evlat's tones, then macOS's.
    var toneOptions: (evlat: [ToneOption], system: [ToneOption]) {
        (EvlatSound.allCases.map { ToneOption(tone: .evlat($0), title: t($0.nameKey)) },
         host.systemSounds().map { ToneOption(tone: .system($0), title: $0) })
    }

    /// Under a character's row: one of its lines and how many more, so it
    /// reads as a voice with lines, not one sound. A line the manifest gives
    /// no words for is only counted.
    func lineText(_ moment: SoundMoment) -> String? {
        guard let pack = voicePack else { return nil }
        let lines = pack.sounds[moment.category] ?? []
        guard !lines.isEmpty else { return t("settings.mascot.noLine") }
        guard let said = lines.first(where: \.hasLabel) else {
            return t("settings.mascot.lines", ["count": String(lines.count)])
        }
        return lines.count == 1 ? t("settings.mascot.line.one", ["line": said.label])
                                : t("settings.mascot.line", ["line": said.label, "count": String(lines.count - 1)])
    }

    var soundVolume: Double { host.soundVolume() }

    func setSoundVolume(_ volume: Double) {
        host.setSoundVolume(volume)
        objectWillChange.send()
    }

    var packBrowser: SoundPackBrowser? { host.packBrowser() }

    var hidesStaleUsage: Bool { host.hidesStaleUsage() }

    func setHidesStaleUsage(_ on: Bool) {
        guard on != host.hidesStaleUsage() else { return }
        host.setHidesStaleUsage(on)
        objectWillChange.send()
    }

    var nudgeNotify: Bool { host.nudgeNotify() }

    /// A refusal leaves the switch off and the row pointing at System Settings.
    func setNudgeNotify(_ on: Bool) {
        guard on != host.nudgeNotify() else { return }
        host.setNudgeNotify(on) { [weak self] result in
            guard let self else { return }
            self.notificationsDenied = on && !result
            self.objectWillChange.send()
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The switches shape only Smart: Always has nothing to hide, Hidden
    /// has neither the sliver nor a peek.
    var showsBodyToggles: Bool { bodyMode == .smart }

    /// Without the waiting peek, waiting is told only by the sliver's amber
    /// dot, or with the sliver off by nothing on the edge — said beside the
    /// switch, so the loss is chosen, not stumbled on.
    var showsPeekWarning: Bool { showsBodyToggles && !bodyToggles.peekWaiting }

    /// With the sliver off too there is no amber dot to fall back on, and
    /// Smart leaves the tray icon plain: the warning must say nothing is left.
    var peekWarningKey: String {
        bodyToggles.sliver ? "settings.general.body.peekWaiting.off"
                           : "settings.general.body.peekWaiting.off.bare"
    }

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

    /// Where the selected backend's program is.
    var backend: Location { locations[host.chatBackend().id] ?? .looking }

    /// One backend in the picker: its mark (by id), name and where its
    /// program is.
    struct BackendChoice: Identifiable, Equatable {
        let id: AgentID
        let name: String
        let location: Location
        /// It carries a note (`ChatBackend.noteKey`): an experimental
        /// protocol, marked beside its name.
        let experimental: Bool

        var isFound: Bool {
            if case .found = location { return true }
            return false
        }

        /// The path under the name, `~/…`; `nil` until found.
        var path: String? {
            if case .found(let path) = location { return SettingsModel.tilde(path) }
            return nil
        }
    }

    var backendChoices: [BackendChoice] {
        host.chatBackends().map { backend in
            BackendChoice(id: backend.id, name: t(backend.id.agent.display.nameKey),
                          location: locations[backend.id] ?? .looking, experimental: backend.noteKey != nil)
        }
    }

    var selectedBackend: AgentID { host.chatBackend().id }

    /// A choice with two or more programs found, or with one found while
    /// the chosen one's is not — the way back to it; else the picker is a
    /// plain row.
    var picksBackend: Bool {
        let choices = backendChoices
        let found = choices.filter(\.isFound).count
        let chosenFound = choices.first { $0.id == selectedBackend }?.isFound ?? false
        return found > 1 || (found == 1 && !chosenFound)
    }

    /// Only a backend whose program is here can be picked.
    func setBackend(_ id: AgentID) {
        guard id != host.chatBackend().id, backendChoices.first(where: { $0.id == id })?.isFound == true else { return }
        host.setChatBackend(id)
        objectWillChange.send()
    }

    /// The selected backend's own line (an experimental protocol).
    var backendNote: String? { host.chatBackend().noteKey.map { t($0) } }

    /// The selected backend's last turn reported another version than its
    /// chat was checked against; `nil` when it did not, or none has said.
    var versionWarning: String? {
        let backend = host.chatBackend()
        guard let measured = backend.measuredVersion, let seen = host.chatVersion(backend.id),
              seen != measured else { return nil }
        return t("settings.chat.backend.version", ["agent": t(backend.id.agent.display.nameKey),
                                                   "version": seen, "measured": measured])
    }

    /// The modes are offered only when there is a program to run them.
    var showsModes: Bool {
        if case .found = backend { return true }
        return false
    }

    var mode: ChatMode { host.defaultMode() }

    /// The new chats' modes on offer, recommended first.
    var offeredModes: [ChatMode] { host.chatBackend().offered }
    /// The one marked recommended.
    var standardMode: ChatMode { host.chatBackend().standardMode }
    /// Whether the backend's workspace chats share a memory folder.
    var hasMemory: Bool { host.chatBackend().caps.memory }

    /// The backend's line under the modes: found where, missing, or still
    /// being looked for.
    var backendLine: String {
        Self.backendLine(backend, program: t(host.chatBackend().id.agent.display.nameKey), t)
    }

    static func backendLine(_ location: Location, program: String,
                            _ t: (String, [String: String]) -> String) -> String {
        switch location {
        case .found(let path): return t("settings.chat.backend.found", ["agent": program, "path": tilde(path)])
        case .missing: return t("settings.chat.backend.missing", ["agent": program])
        case .looking: return t("settings.chat.backend.looking", ["agent": program])
        }
    }

    /// The next chats' mode; an open chat keeps its own (`setDefaultMode`).
    func setMode(_ mode: ChatMode) {
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
        followSandbox()
    }

    // MARK: - Docker sandboxes

    private func followSandbox() {
        let state = host.sandboxState()
        if state != sandboxState { sandboxState = state }
    }

    /// The status line's text.
    var sandboxStatusLine: String {
        switch sandboxState {
        case .off: return t("settings.sandbox.status.off")
        case .starting: return t("settings.sandbox.status.starting")
        case .taken(let port): return t("settings.sandbox.status.taken", ["port": String(port)])
        case .listening(let port, let heard) where heard.isEmpty:
            return t("settings.sandbox.status.quiet", ["port": String(port)])
        case .listening(let port, let heard):
            return t("settings.sandbox.status.heard", ["port": String(port), "names": heard.joined(separator: ", ")])
        }
    }

    // MARK: - Catalogue

    static func titleKey(_ section: Section) -> String { "settings.section.\(section.rawValue)" }

    /// `~/…` for a path under the home.
    nonisolated static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static let keys: [String] = Section.allCases.map(titleKey) + [
        "settings.window.title",
        "settings.general.language", "settings.general.language.detail", "settings.general.language.system",
        "language.name",
        "settings.general.bar", "settings.general.edge", "settings.general.edge.detail",
        "settings.general.edge.left", "settings.general.edge.right", "settings.general.start",
        "settings.general.display", "settings.general.display.detail", "settings.general.display.main",
        "settings.general.display.missing", "settings.general.display.seam",
        "settings.general.body", "settings.general.body.detail", "settings.general.body.always",
        "settings.general.body.smart", "settings.general.body.hidden",
        "settings.general.body.sliver", "settings.general.body.sliver.detail",
        "settings.general.body.peekWaiting", "settings.general.body.peekWaiting.detail",
        "settings.general.body.peekWaiting.off", "settings.general.body.peekWaiting.off.bare",
        "settings.general.body.peekDone", "settings.general.body.peekDone.detail",
        "settings.general.nudge.off", "settings.general.nudge.minutes",
        "settings.general.nudge.notify.denied", "settings.general.nudge.notify.open",
        "settings.mascot.sounds", "settings.mascot.voice", "settings.mascot.voice.evlat",
        "settings.mascot.voice.evlat.detail", "settings.mascot.voice.pack.detail",
        "settings.mascot.voice.characters", "settings.mascot.voice.more",
        "settings.mascot.line", "settings.mascot.line.one", "settings.mascot.lines", "settings.mascot.noLine",
        "settings.mascot.play", "settings.mascot.tones.system", "settings.mascot.volume",
        "settings.mascot.sounds.note", "settings.mascot.sounds.note.pack",
        "settings.mascot.remind.group", "settings.mascot.remind", "settings.mascot.remind.note",
        "settings.mascot.remind.waits", "settings.mascot.remind.waits.detail",
        "settings.mascot.remind.all", "settings.mascot.remind.all.detail",
        "notify.finished.title", "notify.finished.body", "notify.failed.title", "notify.failed.body",
        "settings.mascot.notify", "settings.mascot.notify.detail",
        "packs.title", "packs.intro", "packs.search", "packs.failed", "packs.retry", "packs.install",
        "packs.use", "packs.inUse", "packs.remove", "packs.remove.help", "packs.count", "packs.installed", "packs.unplayable", "packs.unplayable.help",
        "packs.note", "packs.done", "packs.error",
        "settings.agents.group", "settings.agents.note", "settings.usage.bar",
        "settings.sandbox.group", "settings.sandbox.status", "settings.sandbox.status.off", "settings.sandbox.status.starting",
        "settings.sandbox.status.taken", "settings.sandbox.status.quiet", "settings.sandbox.status.heard",
        "remote.copy", "remote.copied",
        "settings.usage.hideStale", "settings.usage.hideStale.detail",
        "settings.chat.open", "settings.chat.hotkey", "settings.chat.hotkey.detail",
        "settings.chat.hotkey.change", "settings.chat.hotkey.cancel", "settings.chat.hotkey.recording",
        "settings.chat.hotkey.off",
        "settings.chat.modes", "settings.chat.modes.note", "settings.chat.modes.recommended",
        "settings.chat.backend.found", "settings.chat.backend.missing", "settings.chat.backend.looking",
        "settings.chat.with", "settings.chat.with.note", "settings.chat.backend.notFound",
        "settings.chat.backend.foundShort", "settings.chat.backend.experimental", "settings.chat.backend.version",
        "settings.agents.chat",
        "settings.chat.memory", "settings.chat.memory.title", "settings.chat.memory.count",
        "settings.chat.memory.one", "settings.chat.memory.empty", "settings.chat.memory.show",
        "settings.chat.memory.clear", "settings.chat.memory.confirm", "settings.chat.memory.confirm.detail",
        "settings.chat.memory.cancel", "settings.chat.memory.do",
        "settings.command.title", "settings.command.examples", "settings.command.watch",
        "settings.command.watch.detail", "settings.command.signal", "settings.command.signal.detail",
        "settings.command.note",
        "settings.attention",
        "settings.remote.machines", "settings.remote.note", "settings.remote.open", "settings.remote.closed",
        "settings.remote.command.detail",
        "settings.remote.retry", "settings.remote.close",
        "settings.remote.what.command", "settings.remote.what.command.remove",
        "settings.remote.what.key", "settings.remote.what.key.remove",
        "settings.remote.path.status", "settings.remote.path.note", "settings.remote.path.stillOff",
        "settings.remote.path.add", "settings.remote.what.path", "settings.remote.what.path.remove",
        "settings.remote.path.manual", "settings.remote.path.manual.remove",
    ] + Agents.chatBackends.compactMap(\.noteKey)
        + EvlatSound.allCases.map(\.nameKey)
        + SoundMoment.allCases.map(\.nameKey)
}
