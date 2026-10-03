import AppKit
import SwiftUI
import EvlatCore

/// Settings → Sandboxes: Docker sandboxes (`sbx`) on this Mac. One switch
/// and its one status line; the sandboxes the watcher last listed, each with
/// one tag; and what the switch does while on. Without `sbx` the switch is
/// dim and off, and one line says why — no instructions to install it.
struct SandboxSection: View {
    @ObservedObject var model: SettingsModel

    private var state: SettingsModel.Sandboxes { model.sandboxes }
    /// Nothing to switch on here: the section reads dim.
    private var dim: Bool { !model.canSwitchSandboxes && !state.on }
    /// The list has something to say: `sbx` is here, or a watcher listed.
    private var showsList: Bool { state.availability == .found || state.watcher != nil }

    var body: some View {
        Text(model.t("settings.sandboxes.intro"))
            .font(.system(size: 12.5))
            .foregroundStyle(SettingsPalette.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
        SettingsGroup(title: model.t("settings.sandboxes.watching")) {
            RowBox {
                HStack(spacing: 10) {
                    RowTitle(name: model.t("settings.sandboxes.watch"),
                             detail: model.t("settings.sandboxes.watch.detail"))
                    Toggle("", isOn: Binding(get: { state.on }, set: { model.setSandboxes($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!model.canSwitchSandboxes)
                        .accessibilityLabel(model.t("settings.sandboxes.watch"))
                }
                if let status = model.sandboxStatus {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(color(status.tone)).frame(width: 7, height: 7)
                        Text(status.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(status.tone == .trouble ? SettingsPalette.wait : SettingsPalette.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .opacity(dim ? 0.55 : 1)
        if showsList {
            SettingsGroup(title: model.t("settings.sandboxes.list")) {
                let rows = model.sandboxRows
                if rows.isEmpty {
                    RowBox {
                        Text(model.sandboxesEmptyLine)
                            .font(.system(size: 12)).foregroundStyle(SettingsPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(rows) { SandboxListRow(model: model, row: $0) }
            }
        }
        if state.availability != .isolated {
            SettingsGroup(title: model.t("settings.sandboxes.what")) {
                RowBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.sandboxWhat, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(SettingsPalette.muted)
                                Text(line)
                                    .foregroundStyle(SettingsPalette.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
            .opacity(dim ? 0.55 : 1)
        }
    }

    private func color(_ tone: SettingsModel.Tone) -> Color {
        switch tone {
        case .muted: return SettingsPalette.radio
        case .good: return SettingsPalette.ok
        case .trouble: return SettingsPalette.dot
        }
    }
}

/// One sandbox: its name, its agent and folder, and one tag. A sandbox
/// that could not be set up says why under it and offers "Try Again".
private struct SandboxListRow: View {
    @ObservedObject var model: SettingsModel
    let row: SettingsModel.SandboxRow

    var body: some View {
        RowBox {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(row.agent + " · " + (row.folder ?? model.t("settings.sandboxes.noFolder")))
                        .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                tag
                if case .failed = row.tag, model.sandboxes.on {
                    Button(model.t("settings.sandboxes.retry")) { model.retrySandbox(row.name) }
                        .buttonStyle(SmallButtonStyle())
                }
            }
            if let reason = failure {
                Text(reason)
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// What `sbx` said when setting up or taking out failed.
    private var failure: String? {
        switch row.tag {
        case .failed(let reason), .removalFailed(let reason): return reason
        default: return nil
        }
    }

    @ViewBuilder private var tag: some View {
        let text = model.sandboxTag(row.tag)
        switch row.tag {
        case .ready: NameTag(text: text)
        case .failed, .removalFailed, .agentOff: NameTag(text: text, caution: true)
        default:
            Text(text)
                .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 230, alignment: .trailing)
        }
    }
}
