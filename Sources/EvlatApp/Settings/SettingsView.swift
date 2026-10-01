import AppKit
import SwiftUI
import EvlatCore

/// The settings window: the
/// five sections on the left, a dot on the ones that want attention; the
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
                    VStack(alignment: .leading, spacing: 14) { section }
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
    }

    @ViewBuilder private var section: some View {
        switch model.section {
        case .general: GeneralSection(model: model, setup: setup)
        case .sessions: SessionsSection(model: model, setup: setup)
        case .chat: ChatSection(model: model, recorder: model.recorder, setup: setup)
        case .commandLine: CommandSection(model: model, setup: setup)
        case .remote: RemoteSection(model: model.remote, settings: model)
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
        SettingsGroup(title: model.t("settings.general.nudge")) {
            NudgeRows(model: model)
        }
        if let row = setup.row(.loginItem) {
            SettingsGroup(title: model.t("settings.general.start")) {
                LoginRow(row: row, setup: setup)
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

/// "Body": how much of the bar stays out, and under Smart the three
/// switches that shape it, with a note when waiting loses its peek.
private struct BodyRows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.body"), detail: model.t("settings.general.body.detail"))
                Picker("", selection: Binding(get: { model.bodyMode }, set: { model.setBodyMode($0) })) {
                    Text(model.t("settings.general.body.always")).tag(BodyPresence.Mode.always)
                    Text(model.t("settings.general.body.smart")).tag(BodyPresence.Mode.smart)
                    Text(model.t("settings.general.body.hidden")).tag(BodyPresence.Mode.hidden)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.general.body"))
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

/// "Waiting reminder": after how long, and how — a sound, a notification,
/// either or both. The two switches rest while the reminder is off.
private struct NudgeRows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.nudge.after"), detail: model.t("settings.general.nudge.after.detail"))
                Picker("", selection: Binding(get: { model.nudgeMinutes }, set: { model.setNudgeMinutes($0) })) {
                    ForEach(AppController.nudgeChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? model.t("settings.general.nudge.off")
                                          : model.t("settings.general.nudge.minutes", ["n": String(minutes)]))
                            .tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(model.t("settings.general.nudge.after"))
            }
        }
        toggle("settings.general.nudge.sound", on: model.nudgeSound) { model.setNudgeSound($0) }
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t("settings.general.nudge.notify"), detail: model.t("settings.general.nudge.notify.detail"))
                switchView("settings.general.nudge.notify", on: model.nudgeNotify) { model.setNudgeNotify($0) }
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

    private func toggle(_ key: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        RowBox {
            HStack(spacing: 10) {
                RowTitle(name: model.t(key), detail: model.t(key + ".detail"))
                switchView(key, on: on, set: set)
            }
        }
    }

    private func switchView(_ key: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { on }, set: set))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(model.nudgeMinutes == 0)
            .accessibilityLabel(model.t(key))
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

// MARK: - Sessions

private struct SessionsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        let agents = setup.rows.filter { $0.item.agent != nil }
        if agents.isEmpty {
            Text(model.t("settings.sessions.none"))
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsPalette.body)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SettingsGroup(title: model.t("settings.sessions.agents"), note: model.t("settings.sessions.agents.note")) {
                ForEach(agents) { SetupRowView(row: $0, model: setup) }
            }
        }
        SettingsGroup(title: model.t("settings.sessions.usage")) {
            if let usage = setup.row(.usageRelay) {
                SetupRowView(row: usage, model: setup)
            }
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.sessions.usage.hideStale"),
                             detail: model.t("settings.sessions.usage.hideStale.detail"))
                    Toggle("", isOn: Binding(get: { model.hidesStaleUsage }, set: { model.setHidesStaleUsage($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(model.t("settings.sessions.usage.hideStale"))
                }
            }
        }
        SettingsGroup(title: model.t("settings.sessions.branch"), note: model.t("settings.sessions.branch.note")) {
            BranchRow(model: model)
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
                } else if !model.isHotKeyOn {
                    Text(model.t("settings.chat.hotkey.off")).font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.muted)
                }
            }
        }
        if model.showsModes {
            SettingsGroup(title: model.t("settings.chat.modes"), note: model.t("settings.chat.modes.note")) {
                ForEach(PermissionMode.offered, id: \.self) { mode in
                    ChoiceRow(title: model.t(ChatModel.modeKey(mode)),
                              badge: mode == .standard ? model.t("settings.chat.modes.recommended") : nil,
                              detail: model.t(ChatModel.modeDetailKey(mode)),
                              selected: model.mode == mode) { model.setMode(mode) }
                }
            }
        } else {
            SettingsGroup(title: model.t("settings.chat.modes")) {
                RowBox {
                    Text(model.t(model.claude == .looking ? "settings.chat.claude.looking" : "settings.chat.claude.missing"))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsPalette.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let count = model.memoryCount {
            SettingsGroup(title: model.t("settings.chat.memory"), note: claudeNote) {
                MemoryRow(model: model, count: count)
            }
        }
    }

    private var claudeNote: String? {
        guard case .found(let path) = model.claude else { return nil }
        return model.t("settings.chat.claude.found", ["path": SettingsModel.tilde(path)])
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
