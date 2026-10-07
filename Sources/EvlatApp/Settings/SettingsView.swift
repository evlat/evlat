import AppKit
import SwiftUI
import EvlatCore
import EvlatAgents

/// The settings window: the
/// six sections on the left, a dot on the ones that want attention; the
/// open section on the right under its title.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup: SetupModel

    init(model: SettingsModel) {
        self.model = model
        self.setup = model.setup
    }

    static let size = CGSize(width: 740, height: 480)
    static let minimumSize = CGSize(width: 660, height: 400)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, dots: Set(setup.attention.map(\.section)))
                .frame(width: 190)
            Rectangle().fill(SettingsPalette.sideLine).frame(width: 1)
            VStack(spacing: 0) {
                Text(model.t(SettingsModel.titleKey(model.section)))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(SettingsPalette.paneLine).frame(height: 1)
                ScrollView {
                    // 24 between groups: a group's note is its last line, and at 14
                    // the next group's heading read as the note's.
                    VStack(alignment: .leading, spacing: 24) { section }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(model.section)
            }
            .background(SettingsPalette.pane)
        }
        .ignoresSafeArea()
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // A new language builds the window's views again: a menu-style
        // picker or a view with nothing observed to change keeps the old
        // words otherwise. The open section is the model's, so it stays.
        .id(model.lang)
    }

    @ViewBuilder private var section: some View {
        switch model.section {
        case .general: GeneralSection(model: model, setup: setup)
        case .mascot: MascotSection(model: model)
        case .agents: AgentsSection(model: model, setup: setup)
        case .usage: UsageSection(model: model)
        case .chat: ChatSection(model: model, recorder: model.recorder, setup: setup)
        case .commandLine: CommandSection(model: model, setup: setup)
        case .remote: RemoteSection(model: model.remote, settings: model)
        case .sandboxes: SandboxSection(model: model)
        }
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    let dots: Set<SettingsModel.Section>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsModel.Section.allCases, id: \.self) { section in
                let on = model.section == section
                Button { model.section = section } label: {
                    HStack(spacing: 6) {
                        Text(model.t(SettingsModel.titleKey(section)))
                            .font(.system(size: 13))
                            .foregroundStyle(on ? SettingsPalette.selectedInk : SettingsPalette.ink)
                        Spacer(minLength: 4)
                        if dots.contains(section) {
                            Circle().fill(SettingsPalette.dot).frame(width: 6, height: 6)
                                .accessibilityLabel(model.t("settings.attention"))
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? SettingsPalette.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        // Under the traffic lights, as the design draws them.
        .padding(.top, 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsPalette.side)
    }
}

// MARK: - General

private struct GeneralSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        SettingsGroup(title: model.t("settings.general.bar")) {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.general.edge"), detail: model.t("settings.general.edge.detail"))
                    Picker("", selection: Binding(get: { model.edge }, set: { model.setEdge($0) })) {
                        Text(model.t("settings.general.edge.left")).tag(BarPanel.Edge.left)
                        Text(model.t("settings.general.edge.right")).tag(BarPanel.Edge.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(model.t("settings.general.edge"))
                }
            }
            if model.showsDisplay {
                DisplayRow(model: model)
            }
            BodyRows(model: model)
        }
        if let row = setup.row(.loginItem) {
            SettingsGroup(title: model.t("settings.general.start")) {
                LoginRow(row: row, setup: setup)
            }
        }
        // Sparkle's row only where its updater offers it; Evlat's own parts
        // in every copy.
        SettingsGroup(title: model.t("settings.general.updates")) {
            if model.hasUpdater {
                RowBox {
                    HStack(spacing: 10) {
                        RowTitle(name: model.t("settings.general.autoUpdate"),
                                 detail: model.t("settings.general.autoUpdate.detail"))
                        Toggle("", isOn: Binding(get: { model.automaticallyUpdates },
                                                 set: { model.setAutomaticallyUpdates($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .accessibilityLabel(model.t("settings.general.autoUpdate"))
                    }
                }
            }
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.general.keepParts"),
                             detail: model.t("settings.general.keepParts.detail"))
                    Toggle("", isOn: Binding(get: { model.keepsPartsCurrent },
                                             set: { model.setKeepsPartsCurrent($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(model.t("settings.general.keepParts"))
                }
            }
        }
        SettingsGroup(title: model.t("settings.general.setup")) {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.general.setup"), detail: model.t("settings.general.setup.detail"))
                    Button(model.t("settings.general.setup.open")) { model.openSetup() }
                        .buttonStyle(SmallButtonStyle())
                }
            }
        }
        SettingsGroup(title: model.t("settings.general.language")) {
            LanguageRow(model: model)
        }
    }
}

/// "Language": the system's, or one of the tables by its own name. Evlat's
/// own text follows at once (`AppController.setLanguage`).
private struct LanguageRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.language"),
                         detail: model.t("settings.general.language.detail"))
                Picker("", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(model.languageOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.general.language"))
            }
        }
    }
}

/// "Screen": the main screen or one pinned by name. Shown only when
/// there is a choice (`SettingsModel.showsDisplay`).
private struct DisplayRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.display"), detail: model.t("settings.general.display.detail"))
                Picker("", selection: Binding(get: { model.display }, set: { model.setDisplay($0) })) {
                    ForEach(model.displayChoices) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.general.display"))
            }
            // A seam needs two screens, so this row is always there for it.
            if model.displayOnSeam {
                Text(model.t("settings.general.display.seam"))
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Body": how much of the bar stays out, and under Smart and Tucked a line
/// saying which, the three switches that shape it, and a note when waiting
/// loses its peek.
private struct BodyRows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.body"), detail: model.t("settings.general.body.detail"))
                Picker("", selection: Binding(get: { model.bodyMode }, set: { model.setBodyMode($0) })) {
                    Text(model.t("settings.general.body.always")).tag(BodyPresence.Mode.always)
                    Text(model.t("settings.general.body.smart")).tag(BodyPresence.Mode.smart)
                    Text(model.t("settings.general.body.tucked")).tag(BodyPresence.Mode.tucked)
                    Text(model.t("settings.general.body.hidden")).tag(BodyPresence.Mode.hidden)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.general.body"))
            }
            if let key = model.bodyModeDetailKey {
                Text(model.t(key))
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if model.showsBodyToggles {
            toggle(\.sliver, "settings.general.body.sliver")
            toggle(\.peekWaiting, "settings.general.body.peekWaiting")
            toggle(\.peekDone, "settings.general.body.peekDone")
        }
    }

    private func toggle(_ path: WritableKeyPath<BodyPresence.Toggles, Bool>, _ key: String) -> some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t(key), detail: model.t(key + ".detail"))
                Toggle("", isOn: Binding(get: { model.bodyToggles[keyPath: path] },
                                         set: { model.setBodyToggle(path, on: $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(model.t(key))
            }
            if path == \.peekWaiting && model.showsPeekWarning {
                Text(model.t(model.peekWarningKey))
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Mascot

/// Who speaks and when (mockups 1–3): the voice first — Evlat's tones or a
/// character's lines — then a switch per moment, the reminder last.
private struct MascotSection: View {
    @ObservedObject var model: SettingsModel
    @State private var showsCharacters = false

    var body: some View {
        SettingsGroup(title: model.t("settings.mascot.sounds"),
                      note: model.t(model.voicePack == nil ? "settings.mascot.sounds.note"
                                                           : "settings.mascot.sounds.note.pack")) {
            VoiceRow(model: model, showsCharacters: $showsCharacters)
            ForEach(SoundMoment.allCases, id: \.self) { MomentRow(model: model, moment: $0) }
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.mascot.volume"))
                    Slider(value: Binding(get: { model.soundVolume }, set: { model.setSoundVolume($0) }), in: 0...1)
                        .controlSize(.small)
                        .frame(width: 160)
                        .accessibilityLabel(model.t("settings.mascot.volume"))
                }
            }
        }
        SettingsGroup(title: model.t("settings.mascot.remind.group"), note: model.t("settings.mascot.remind.note")) {
            RemindRows(model: model)
        }
        .sheet(isPresented: $showsCharacters) {
            if let browser = model.packBrowser {
                SoundPackBrowserView(browser: browser, t: { model.t($0, $1) }, close: {
                    showsCharacters = false
                    model.objectWillChange.send()
                })
            }
        }
    }
}

/// "Who speaks?": Evlat, the characters installed, and the way to more.
private struct VoiceRow: View {
    @ObservedObject var model: SettingsModel
    @Binding var showsCharacters: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let pack = model.voicePack {
                VoiceInitial(name: pack.displayName, key: pack.name)
            } else {
                EvlatMark()
            }
            RowTitle(name: model.t("settings.mascot.voice"), detail: model.voiceDetail)
            Menu(model.voiceTitle) {
                Button { model.setVoice(.evlat) } label: {
                    if model.voicePack == nil { Label(model.t("settings.mascot.voice.evlat"), systemImage: "checkmark") }
                    else { Text(model.t("settings.mascot.voice.evlat")) }
                }
                let characters = model.characterOptions
                if !characters.isEmpty {
                    Section(model.t("settings.mascot.voice.characters")) {
                        ForEach(characters) { option in
                            Button { model.setVoice(option.voice) } label: {
                                if model.voice == option.voice { Label(option.title, systemImage: "checkmark") }
                                else { Text(option.title) }
                            }
                        }
                    }
                }
                if model.packBrowser != nil {
                    Divider()
                    Button(model.t("settings.mascot.voice.more")) { showsCharacters = true }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.key))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsPalette.keyLine))
            .accessibilityLabel(model.t("settings.mascot.voice"))
        }
        .padding(12)
        .background(SettingsPalette.serverRows)
    }
}

/// Evlat's own mark beside "Who speaks?": the cube's face.
private struct EvlatMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(SettingsPalette.selected)
            RoundedRectangle(cornerRadius: 5).fill(SettingsPalette.selectedInk).frame(width: 18, height: 18)
            HStack(spacing: 3) {
                Capsule().fill(SettingsPalette.selected).frame(width: 2.4, height: 7)
                Capsule().fill(SettingsPalette.selected).frame(width: 2.4, height: 7)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// One moment: its name (and, for a character, one of its lines), Evlat's
/// tone where Evlat speaks, ▶, and the switch.
private struct MomentRow: View {
    @ObservedObject var model: SettingsModel
    let moment: SoundMoment

    var body: some View {
        let speaks = model.canSpeak(moment)
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t(moment.nameKey), detail: model.lineText(moment))
                    .opacity(model.soundOn(moment) && speaks ? 1 : 0.6)
                if model.voicePack == nil {
                    ToneMenu(model: model, moment: moment)
                }
                PlayButton(label: model.t("settings.mascot.play"), enabled: speaks) { model.preview(moment) }
                Toggle("", isOn: Binding(get: { model.soundOn(moment) }, set: { model.setSoundOn($0, for: moment) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!speaks)
                    .accessibilityLabel(model.t(moment.nameKey))
            }
        }
    }
}

/// Evlat's tone for a moment: its nine sounds, macOS's in a submenu so the
/// list stays short. Choosing one plays it.
private struct ToneMenu: View {
    @ObservedObject var model: SettingsModel
    let moment: SoundMoment

    var body: some View {
        let options = model.toneOptions
        let current = model.tone(moment)
        let title = (options.evlat + options.system).first { $0.tone == current }?.title ?? ""
        Menu(title) {
            ForEach(options.evlat) { option in item(option, current) }
            if !options.system.isEmpty {
                Divider()
                Menu(model.t("settings.mascot.tones.system")) {
                    ForEach(options.system) { option in item(option, current) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(minWidth: 96, alignment: .leading)
        .accessibilityLabel(model.t(moment.nameKey))
    }

    @ViewBuilder private func item(_ option: SettingsModel.ToneOption, _ current: AlertSound) -> some View {
        Button { model.setTone(option.tone, for: moment) } label: {
            if option.tone == current { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
        }
    }
}

/// "If you don't answer": after how long a wait speaks once more, and a
/// notification with it. The notification rests while the reminder is off.
private struct RemindRows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.mascot.remind"))
                Picker("", selection: Binding(get: { model.nudgeMinutes }, set: { model.setNudgeMinutes($0) })) {
                    ForEach(AppController.nudgeChoices, id: \.self) { minutes in
                        Text(model.nudgeTitle(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.mascot.remind"))
            }
        }
        // What it covers, each with what it means (the chat modes' radio).
        ForEach([NudgeScope.waits, .all], id: \.self) { scope in
            ChoiceRow(title: model.t("settings.mascot.remind." + scope.rawValue),
                      detail: model.t("settings.mascot.remind." + scope.rawValue + ".detail"),
                      selected: model.nudgeScope == scope) { model.setNudgeScope(scope) }
                .disabled(!model.reminds)
                .opacity(model.reminds ? 1 : 0.5)
        }
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.mascot.notify"), detail: model.t("settings.mascot.notify.detail"))
                Toggle("", isOn: Binding(get: { model.nudgeNotify }, set: { model.setNudgeNotify($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!model.reminds)
                    .accessibilityLabel(model.t("settings.mascot.notify"))
            }
            if model.notificationsDenied {
                HStack(spacing: 10) {
                    Text(model.t("settings.general.nudge.notify.denied"))
                        .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(model.t("settings.general.nudge.notify.open")) { model.openNotificationSettings() }
                        .buttonStyle(SmallButtonStyle())
                }
            }
        }
    }
}

/// "Open at login": a switch, what turning it writes beside it (R3), the
/// copy that opens.
private struct LoginRow: View {
    let row: SetupRow
    @ObservedObject var setup: SetupModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: row.name, detail: row.detail)
                Toggle("", isOn: Binding(get: { row.status == .installed }, set: { _ in setup.perform(.loginItem) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(row.action == nil)
                    .accessibilityLabel(row.name)
            }
            if let action = row.action {
                ConsentLines(lines: setup.consent(.loginItem, action))
            }
            if let note = row.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let failure = row.failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
            }
        }
    }
}

// MARK: - Agents

/// A card for every agent in the catalogue: found or not, one state and
/// one button each; and the git branch, which is the sessions'.
private struct AgentsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        let agents = setup.rows.filter { $0.item.agent != nil }
        if !agents.isEmpty {
            SettingsGroup(title: model.t("settings.agents.group"), note: model.t("settings.agents.note")) {
                ForEach(agents) { row in
                    SetupRowView(row: row, model: setup, link: sandboxLink(row))
                }
            }
        }
        SettingsGroup(title: model.t("settings.sessions.branch"), note: model.t("settings.sessions.branch.note")) {
            BranchRow(model: model)
        }
    }

    /// The sandboxes' agent's card, while `sbx` is here and not watched:
    /// one line to Sandboxes.
    private func sandboxLink(_ row: SetupRow) -> (text: String, action: () -> Void)? {
        guard row.item.agent == Agents.sandboxAgent, row.enabled, model.offersSandboxes else { return nil }
        return (model.t("settings.sandboxes.discover"), { model.section = .sandboxes })
    }
}

// MARK: - Usage

/// What the bar's usage block leaves out. The windows' order is not chosen
/// here yet: the block draws them in its own order.
private struct UsageSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup(title: model.t("settings.usage.bar")) {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.usage.hideStale"),
                             detail: model.t("settings.usage.hideStale.detail"))
                    Toggle("", isOn: Binding(get: { model.hidesStaleUsage }, set: { model.setHidesStaleUsage($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(model.t("settings.usage.hideStale"))
                }
            }
        }
    }
}

/// "Git branch": one choice, and under its name a line that says what the
/// chosen one does — the three are told apart by what they show, not by
/// their names.
private struct BranchRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.sessions.branch.show"),
                         detail: model.t(Self.detailKey(model.branchDisplay)))
                Picker("", selection: Binding(get: { model.branchDisplay }, set: { model.setBranchDisplay($0) })) {
                    Text(model.t("settings.sessions.branch.off")).tag(BranchDisplay.off)
                    Text(model.t("settings.sessions.branch.auto")).tag(BranchDisplay.auto)
                    Text(model.t("settings.sessions.branch.on")).tag(BranchDisplay.on)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.sessions.branch.show"))
            }
        }
    }

    static func detailKey(_ display: BranchDisplay) -> String {
        switch display {
        case .off: return "settings.sessions.branch.off.detail"
        case .auto: return "settings.sessions.branch.auto.detail"
        case .on: return "settings.sessions.branch.on.detail"
        }
    }
}

// MARK: - Chat

private struct ChatSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: HotKeyRecorder
    @ObservedObject var setup: SetupModel

    var body: some View {
        // The switch, in a group of its own; off, everything under it is
        // dim and takes no press.
        SettingsRows {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.chat.enabled"), detail: model.t("settings.chat.enabled.detail"))
                    Toggle("", isOn: Binding(get: { model.isChatEnabled }, set: { model.setChatEnabled($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(model.t("settings.chat.enabled"))
                }
            }
        }
        Group { options }
            .disabled(!model.isChatEnabled)
            .opacity(model.isChatEnabled ? 1 : 0.45)
    }

    @ViewBuilder private var options: some View {
        SettingsGroup(title: model.t("settings.chat.open")) {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.chat.hotkey"), detail: model.t("settings.chat.hotkey.detail"))
                    KeyCap(text: recorder.isRecording ? model.t("settings.chat.hotkey.recording")
                                                      : model.hotKey.title,
                           recording: recorder.isRecording, off: !model.isHotKeyOn)
                    Button(model.t(recorder.isRecording ? "settings.chat.hotkey.cancel" : "settings.chat.hotkey.change")) {
                        model.toggleRecording()
                    }
                    .buttonStyle(SmallButtonStyle())
                    Toggle("", isOn: Binding(get: { model.isHotKeyOn }, set: { model.setHotKey(on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(model.t("settings.chat.hotkey"))
                }
                if let line = recorder.text(in: model.lang) {
                    Text(line.0).font(.system(size: 11.5))
                        .foregroundStyle(line.trouble ? SettingsPalette.wait : SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if setup.attention.contains(.hotKeyUnregistered) {
                    Text(model.t("setup.attention.hotKey")).font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.wait)
                } else if !model.isHotKeyOn && model.isChatEnabled {
                    // With the chat off the mascot opens nothing either.
                    Text(model.t("settings.chat.hotkey.off")).font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.muted)
                }
            }
        }
        BackendGroup(model: model)
        if model.showsModes {
            SettingsGroup(title: model.t("settings.chat.modes"), note: model.t("settings.chat.modes.note")) {
                ForEach(model.offeredModes, id: \.self) { mode in
                    ChoiceRow(title: model.t(mode.nameKey),
                              badge: mode == model.standardMode ? model.t("settings.chat.modes.recommended") : nil,
                              detail: model.t(mode.detailKey),
                              selected: model.mode == mode) { model.setMode(mode) }
                }
            }
        } else {
            SettingsGroup(title: model.t("settings.chat.modes")) {
                RowBox {
                    Text(model.backendLine)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsPalette.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let count = model.memoryCount, model.hasMemory {
            SettingsGroup(title: model.t("settings.chat.memory")) {
                MemoryRow(model: model, count: count)
            }
        }
    }
}

/// "Chat with": every agent the balloon can talk to — its mark, its name,
/// where its program is. Two or more found, a radio picks the new chats'
/// one; one found, it is a plain row; one not found is dim and cannot be
/// picked. Under it, the chosen one's note and a version it was not
/// checked against.
private struct BackendGroup: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsGroup(title: model.t("settings.chat.with"),
                          note: model.picksBackend ? model.t("settings.chat.with.note") : nil) {
                ForEach(model.backendChoices) { choice in
                    BackendRow(model: model, choice: choice, picks: model.picksBackend,
                               selected: choice.id == model.selectedBackend)
                }
            }
            if let note = model.backendNote {
                line(note, color: SettingsPalette.muted)
            }
            if let warning = model.versionWarning {
                line(warning, color: SettingsPalette.wait)
            }
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .textSelection(.enabled)
    }
}

/// One agent in "Chat with".
private struct BackendRow: View {
    @ObservedObject var model: SettingsModel
    let choice: SettingsModel.BackendChoice
    /// A radio, rather than a plain row: two or more are found.
    let picks: Bool
    let selected: Bool

    var body: some View {
        if picks {
            Button { model.setBackend(choice.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().strokeBorder(selected ? SettingsPalette.ink : SettingsPalette.radio, lineWidth: 1.5)
                        if selected { Circle().fill(SettingsPalette.ink).padding(3.5) }
                    }
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                    title
                    Spacer(minLength: 0)
                    if !choice.isFound { state }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!choice.isFound)
            .opacity(choice.isFound ? 1 : 0.55)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            RowBox {
                HStack(alignment: .center, spacing: 10) {
                    title
                    Spacer(minLength: 0)
                    state
                }
            }
            .opacity(choice.isFound ? 1 : 0.55)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SourceGlyph(source: choice.id)
                    .fill(SettingsPalette.ink, style: FillStyle(eoFill: true))
                    .frame(width: 13, height: 13)
                Text(choice.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                if choice.experimental {
                    NameTag(text: model.t("settings.chat.backend.experimental"), caution: true)
                }
            }
            if let path = choice.path {
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SettingsPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// Found (a plain row only), not installed, or still being looked for.
    @ViewBuilder private var state: some View {
        switch choice.location {
        case .found:
            Text(model.t("settings.chat.backend.foundShort"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsPalette.ok).fixedSize()
        case .missing:
            Text(model.t("settings.chat.backend.notFound"))
                .font(.system(size: 12)).foregroundStyle(SettingsPalette.muted).fixedSize()
        case .looking:
            Text(verbatim: "…").font(.system(size: 12)).foregroundStyle(SettingsPalette.muted).fixedSize()
        }
    }
}

/// The shortcut as a key cap; blue and pulsing while recording.
struct KeyCap: View {
    let text: String
    let recording: Bool
    let off: Bool
    @State private var pulse = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(recording ? SettingsPalette.link : SettingsPalette.ink.opacity(off ? 0.45 : 1))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(minWidth: 88)
            .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.key))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(recording ? SettingsPalette.link : SettingsPalette.keyLine))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(recording ? SettingsPalette.link : SettingsPalette.keyLine)
                    .frame(height: 1).padding(.horizontal, 3)
            }
            .shadow(color: SettingsPalette.link.opacity(recording && pulse ? 0.25 : 0), radius: 3)
            // Only while recording: an idle window draws nothing.
            .animation(recording ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onChange(of: recording, initial: true) { _, now in pulse = now }
            .fixedSize()
    }
}

/// The memory's row, or its question in its place (no alert).
private struct MemoryRow: View {
    @ObservedObject var model: SettingsModel
    let count: Int

    var body: some View {
        RowBox {
            if model.confirmingClear {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.chat.memory.confirm"),
                             detail: model.t("settings.chat.memory.confirm.detail"))
                    Button(model.t("settings.chat.memory.cancel")) { model.cancelClear() }
                        .buttonStyle(SmallButtonStyle())
                    Button(model.t("settings.chat.memory.do")) { model.confirmClear() }
                        .buttonStyle(SmallButtonStyle(warn: true))
                }
            } else {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.chat.memory.title"),
                             detail: count == 0 ? model.t("settings.chat.memory.empty")
                                 : count == 1 ? model.t("settings.chat.memory.one")
                                 : model.t("settings.chat.memory.count", ["count": String(count)]))
                    Button(model.t("settings.chat.memory.show")) { model.showMemory() }
                        .buttonStyle(SmallButtonStyle())
                        .disabled(count == 0)
                    Button(model.t("settings.chat.memory.clear")) { model.askToClear() }
                        .buttonStyle(SmallButtonStyle())
                        .disabled(count == 0)
                }
            }
        }
    }
}

// MARK: - Command line

private struct CommandSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        if let row = setup.row(.commandLink) {
            SettingsGroup(title: model.t("settings.command.title")) {
                SetupRowView(row: row, model: setup)
            }
        }
        SettingsGroup(title: model.t("settings.command.examples"), note: model.t("settings.command.note")) {
            RowBox {
                RowTitle(name: model.t("settings.command.watch"), detail: model.t("settings.command.watch.detail"),
                         code: true)
            }
            RowBox {
                RowTitle(name: model.t("settings.command.signal"), detail: model.t("settings.command.signal.detail"),
                         code: true)
            }
        }
    }
}
