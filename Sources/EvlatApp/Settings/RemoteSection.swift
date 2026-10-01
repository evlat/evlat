import AppKit
import SwiftUI
import EvlatCore

/// Settings → Remote machines: what the "Remote Machines…"
/// window held, as a section. Each machine is a row that opens on a click
/// (the whole row, and a 24 pt chevron); open, it lists what is set up on
/// **the server's own files** — hooks, the usage line, the `evlat` command —
/// each with its path on the server (`devbox:~/.claude/settings.json`), its
/// state as last read over `ssh`, its button and its block to paste; then
/// every block in one.
struct RemoteSection: View {
    @ObservedObject var model: RemoteMachinesModel
    @ObservedObject var settings: SettingsModel

    var body: some View {
        SettingsGroup(title: model.t("settings.remote.machines"), note: note) {
            ForEach(model.rows) { row in
                MachineRow(model: model, row: row)
            }
            RemoteAddRow(model: model)
        }
    }

    private var note: String {
        var lines = [model.t(model.rows.isEmpty ? "remote.empty.body" : "settings.remote.note"),
                     model.t("remote.empty.requirement")]
        if !model.isStored { lines.append(model.t("remote.environment")) }
        return lines.joined(separator: " ")
    }
}

/// The target field and its button. Return adds; a refusal is one line
/// under it, in words, and the field keeps what was typed.
private struct RemoteAddRow: View {
    @ObservedObject var model: RemoteMachinesModel
    @FocusState private var focused: Bool

    var body: some View {
        RowBox {
            HStack(spacing: 8) {
                TextField(model.t("remote.add.placeholder"), text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focused)
                    .onSubmit { model.add() }
                    .disableAutocorrection(true)
                Button(model.t("remote.add")) { model.add() }
                    .buttonStyle(SmallButtonStyle())
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem = model.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.warnInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if model.rows.isEmpty { focused = true } }
    }
}

extension RemoteMachinesModel.Tone {
    var color: Color {
        switch self {
        case .neutral: return SettingsPalette.muted
        case .good: return SettingsPalette.ok
        case .trouble: return SettingsPalette.dot
        }
    }
}

/// One machine: its row (a click opens it), and when open, what is set up
/// on its server.
private struct MachineRow: View {
    @ObservedObject var model: RemoteMachinesModel
    let row: RemoteMachinesModel.Row
    @State private var hovered = false

    private var open: Bool { model.expanded == row.id }

    var body: some View {
        RowBox {
            header
            if let advice = row.advice {
                Text(advice).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 34)
            }
            if model.confirmingRemoval == row.id { removal }
            if open { ServerPart(model: model, row: row).padding(.leading, 22).padding(.top, 4) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Chevron(open: open, hovered: hovered)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(row.tone.color).frame(width: 7, height: 7)
                    Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if row.target != row.name {
                        Text(row.target).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(SettingsPalette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(row.status).font(.system(size: 11.5))
                    .foregroundStyle(row.tone == .trouble ? SettingsPalette.wait : SettingsPalette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if row.enterPassword {
                Button(model.t("remote.enterPassword")) { model.enterPassword(row.id) }
                    .buttonStyle(SmallButtonStyle())
            }
            Button(model.t("remote.remove")) { model.askToRemove(row.id) }
                .buttonStyle(SmallButtonStyle())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? SettingsPalette.rowHover : .clear))
        .padding(.vertical, -4)
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(row.id) }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(open ? model.t("settings.remote.open") : model.t("settings.remote.closed"))
        .accessibilityAction { model.toggle(row.id) }
    }

    private var removal: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.t("remote.remove.confirm", ["name": row.name]))
                .font(.system(size: 12)).foregroundStyle(SettingsPalette.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.t("remote.remove.cancel")) { model.cancelRemoval() }
                .buttonStyle(SmallButtonStyle())
            // Not the default button: Return must never remove.
            Button(model.t("remote.remove.do")) { model.confirmRemoval() }
                .buttonStyle(SmallButtonStyle(warn: true))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.warn.opacity(0.6)))
    }
}

/// "Set up on devbox": the three rows, the read's state, the last job's
/// line, and every block in one.
private struct ServerPart: View {
    @ObservedObject var model: RemoteMachinesModel
    let row: RemoteMachinesModel.Row
    /// The one open block to paste (R2): an item's, or the combined one.
    @State private var manual: Manual?

    enum Manual: Equatable { case item(RemoteMachinesModel.Item), combined }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t("remote.items.title", ["name": row.name]))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
                Text(model.t("remote.items.body"))
                    .font(.system(size: 12)).foregroundStyle(SettingsPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            readingLine
            SettingsRows(fill: SettingsPalette.serverRows) {
                ForEach(RemoteMachinesModel.Item.allCases, id: \.self) { item in
                    ServerItemRow(model: model, row: row, item: item, manual: $manual)
                }
            }
            outcome
            combined
            Text(model.t("remote.manual.surface"))
                .font(.system(size: 11)).foregroundStyle(SettingsPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var readingLine: some View {
        if model.needsConnectionFirst(row.id), model.readings[row.id] != .reading {
            // The reads and installs ride the tunnel's connection; without
            // it a password server cannot be reached (`BatchMode=yes`).
            HStack(spacing: 8) {
                Text(model.t("remote.reading.connectFirst")).font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.wait)
                    .fixedSize(horizontal: false, vertical: true)
                if row.enterPassword {
                    Button(model.t("remote.enterPassword")) { model.enterPassword(row.id) }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        } else {
            plainReadingLine
        }
    }

    @ViewBuilder private var plainReadingLine: some View {
        switch model.readings[row.id] {
        case .reading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(model.t("remote.reading")).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
            }
        case .unreachable?:
            HStack(spacing: 8) {
                Text(model.t("remote.reading.failed")).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                Button(model.t("settings.remote.retry")) { model.check(row.id) }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(!model.canRun(row.id))
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var outcome: some View {
        if !model.isBusy(row.id), let outcome = model.outcomes[row.id] {
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.line).font(.system(size: 12))
                    .foregroundStyle(outcome.trouble ? SettingsPalette.wait : SettingsPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(outcome.hints, id: \.self) { hint in
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Only from a reading: without one there is no block and no button
    /// — each row's own blocks remain.
    @ViewBuilder private var combined: some View {
        if let block = model.combinedBlock(for: row.id) {
            if manual == .combined {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("remote.combined.title", ["name": row.name]))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
                    Text(model.t("remote.combined.body"))
                        .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    // What the copy carries, said before the Copy button.
                    Text(model.t(block.captionKey))
                        .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.consent))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsPalette.consentLine))
                    ManualBox(text: block.shown, footnote: model.t("remote.combined.checkNote"), maxHeight: 120) {
                        Button(model.copied == block.id ? model.t("remote.copied") : model.t("remote.copy")) {
                            model.copy(block)
                        }
                        .buttonStyle(SmallButtonStyle())
                        Button(model.t("remote.combined.check")) { model.check(row.id) }
                            .buttonStyle(SmallButtonStyle())
                            .disabled(!model.canRun(row.id))
                        Button(model.t("settings.remote.close")) { manual = nil }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Button(model.t("remote.combined")) { manual = .combined }
                        .buttonStyle(LinkButtonStyle())
                    Text(model.t("remote.combined.hint")).font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.muted)
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// One of the three: the server path it writes, its state, its button
/// with what it writes beside it, and its blocks to paste.
private struct ServerItemRow: View {
    @ObservedObject var model: RemoteMachinesModel
    let row: RemoteMachinesModel.Row
    let item: RemoteMachinesModel.Item
    @Binding var manual: ServerPart.Manual?

    private var target: String { row.target }
    private var status: SetupStatus {
        let items = model.items(for: row.id)
        switch item {
        case .hooks: return items.hooks
        case .usage: return items.usage
        case .command: return items.command
        }
    }

    /// The command installed and current, but not found by a new login
    /// shell on the server: the row says so and offers the PATH line
    /// beside "Remove" — automatically, or by hand.
    private var offPath: RemotePath.Status? {
        guard item == .command, status == .installed else { return nil }
        return model.items(for: row.id).offPath
    }

    /// What the button does from the state: unknown (not read, or not
    /// readable) offers the install, which leaves a current setup as it is.
    private var action: RemoteSettings.Action? {
        switch status {
        case .missing, .outdated, .unknown: return .install
        case .installed: return .remove
        case .foreign, .notFound: return nil
        }
    }

    var body: some View {
        RowBox {
            HStack(alignment: .center, spacing: 10) {
                RowTitle(name: model.t("remote.item.\(item.rawValue)"), detail: detail, monospaced: true)
                state
            }
            .opacity(status == .foreign ? 0.55 : 1)
            if let offPath {
                Text(offPath.added ? model.t("settings.remote.path.stillOff", ["file": "~/" + offPath.file])
                                   : model.t("settings.remote.path.note"))
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if manual != .item(item), model.readings[row.id] != .reading, model.working[row.id] != item {
                // Evlat's line already there and still not found: nothing to
                // add; the command can still be removed, line and all.
                if let offPath, !offPath.added {
                    ConsentAction(lines: [consentLine(offPath.file, "settings.remote.what.path")],
                                  title: model.t("settings.remote.path.add"), enabled: model.canRun(row.id)) {
                        model.addToPath(row.id)
                    }
                }
                if let action {
                    ConsentAction(lines: consent(action), title: model.t(buttonKey(action)),
                                  enabled: model.canRun(row.id)) {
                        model.perform(item, action, on: row.id)
                    }
                }
            }
            if let offPath {
                if !offPath.added { pathManualPart(offPath) }
            } else {
                manualPart
            }
        }
    }

    @ViewBuilder private var state: some View {
        if model.working[row.id] == item || model.readings[row.id] == .reading {
            ProgressView().controlSize(.small).frame(height: 16)
        } else if offPath != nil {
            StatusText(status: .outdated, text: model.t("settings.remote.path.status"))
        } else {
            StatusText(status: status, text: model.t(status.key))
        }
    }

    private func buttonKey(_ action: RemoteSettings.Action) -> String {
        switch (action, status) {
        case (.remove, _): return SetupAction.remove.key
        case (.install, .outdated): return SetupAction.update.key
        case (.install, _): return SetupAction.install.key
        }
    }

    /// `devbox:~/.claude/settings.json` — where on the server, in `scp`'s
    /// words.
    private func path(_ relative: String) -> String { "\(target):~/\(relative)" }

    private var detail: String {
        switch item {
        case .hooks:
            return AgentSource.allCases.map { path($0.settingsPath) }.joined(separator: "\n")
        case .usage:
            return model.t("settings.remote.usage.detail", ["file": path(AgentSource.claude.settingsPath)])
        case .command:
            return model.t("settings.remote.command.detail",
                           ["command": path(RemoteCommand.commandPath), "key": path(RemoteCommand.keyPath)])
        }
    }

    private func consentLine(_ file: String, _ whatKey: String) -> String {
        model.t("setup.consent.line", ["file": path(file), "what": model.t(whatKey)])
    }

    /// R3 for the server: each file the press writes, by its server path.
    private func consent(_ action: RemoteSettings.Action) -> [String] {
        let install = action == .install
        let line = consentLine
        switch item {
        case .hooks:
            let what = install ? "setup.consent.what.hooks" : "setup.consent.what.hooks.remove"
            return AgentSource.allCases.map { line($0.settingsPath, what) }
        case .usage:
            return [line(AgentSource.claude.settingsPath,
                         install ? "setup.consent.what.usage" : "setup.consent.what.usage.remove")]
        case .command:
            var lines = [line(RemoteCommand.commandPath, install ? "settings.remote.what.command"
                                                                 : "settings.remote.what.command.remove"),
                         line(RemoteCommand.keyPath, install ? "settings.remote.what.key" : "settings.remote.what.key.remove")]
            // The removal takes Evlat's PATH line with the command.
            if !install, let file = model.pathLineToRemove(for: row.id) {
                lines.append(line(file, "settings.remote.what.path.remove"))
            }
            return lines
        }
    }

    private var blocks: [RemoteMachinesModel.Block] {
        switch item {
        case .hooks: return RemoteMachinesModel.blocks.filter { AgentSource(rawValue: $0.id) != nil }
        case .usage: return RemoteMachinesModel.blocks.filter { $0.id == "statusLine" || $0.id == "wrapping" }
        case .command: return model.commandBlocks(for: row.id)
        }
    }

    @ViewBuilder private var manualPart: some View {
        if status != .installed, status != .foreign, !blocks.isEmpty {
            if manual == .item(item) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks) { block in
                        ManualBox(lead: model.t(block.captionKey, ["placeholder": RemoteSettings.Manual.placeholder]),
                                  text: block.shown) {
                            Button(model.copied == block.id ? model.t("remote.copied") : model.t("remote.copy")) {
                                model.copy(block)
                            }
                            .buttonStyle(SmallButtonStyle())
                        }
                    }
                    HStack(spacing: 8) {
                        Button(model.t("setup.manual.check")) { model.check(row.id) }
                            .buttonStyle(SmallButtonStyle())
                            .disabled(!model.canRun(row.id))
                        Button(model.t("setup.manual.auto")) { manual = nil }
                            .buttonStyle(LinkButtonStyle())
                    }
                    if let removal {
                        Text(removal).font(.system(size: 11)).foregroundStyle(SettingsPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Button(model.t("setup.manual.open")) { manual = .item(item) }
                    .buttonStyle(LinkButtonStyle())
            }
        }
    }

    /// The PATH line by hand: the line, the file it goes into, and how to
    /// take it out again.
    @ViewBuilder private func pathManualPart(_ offPath: RemotePath.Status) -> some View {
        if manual == .item(item) {
            let block = RemoteMachinesModel.pathBlock
            VStack(alignment: .leading, spacing: 6) {
                ManualBox(lead: model.t(block.captionKey, ["file": path(offPath.file)]), text: block.shown,
                          footnote: model.t("settings.remote.path.manual.remove",
                                            ["marker": RemotePath.marker, "file": "~/" + offPath.file])) {
                    Button(model.copied == block.id ? model.t("remote.copied") : model.t("remote.copy")) {
                        model.copy(block)
                    }
                    .buttonStyle(SmallButtonStyle())
                    Button(model.t("setup.manual.check")) { model.check(row.id) }
                        .buttonStyle(SmallButtonStyle())
                        .disabled(!model.canRun(row.id))
                    Button(model.t("setup.manual.auto")) { manual = nil }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        } else {
            Button(model.t("setup.manual.open")) { manual = .item(item) }
                .buttonStyle(LinkButtonStyle())
        }
    }

    /// How to take it out by hand; the command's is its own third block.
    private var removal: String? {
        switch item {
        case .hooks: return model.t("remote.manual.remove", ["marker": RemoteSettings.manual.marker])
        case .usage: return model.t("setup.manual.remove.usage")
        case .command: return nil
        }
    }
}
