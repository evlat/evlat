import SwiftUI
import EvlatCore

/// The update window: the heading and its paragraph, "On this Mac" and "On
/// your servers", and the footer. Every line wraps; nothing is cut. The
/// lists' viewport is the window's rule's (`UpdatesWindow.fit`), from the
/// heights measured here.
struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
    @ObservedObject var measure: UpdatesMeasure
    /// Drawn for a picture (`ImageRenderer`, which draws no scroll view):
    /// the lists clipped to their viewport, as the scroll view at its top.
    var still = false

    var body: some View {
        VStack(spacing: 0) {
            header.background(height { measure.set(header: $0) })
            listsArea
            footer.background(height { measure.set(footer: $0) })
        }
        .frame(width: measure.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsPalette.pane)
    }

    // MARK: - Parts

    /// Below the see-through title bar.
    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("updates.title"))
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(SettingsPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("updates.body"))
                .font(.system(size: 13.5))
                .lineSpacing(3.5)
                .foregroundStyle(SettingsPalette.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 600, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
        .padding(.horizontal, 36)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var listsArea: some View {
        if still {
            lists.frame(height: measure.listsHeight, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) {
                lists.background(height { measure.set(lists: $0) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: measure.listsHeight)
        }
    }

    var lists: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.agents.isEmpty { section(model.t("updates.section.mac"), model.agents) }
            if !model.machines.isEmpty { section(model.t("updates.section.servers"), model.machines) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 36)
        .padding(.bottom, 22)
    }

    private func section(_ title: String, _ rows: [UpdatesModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased(with: Locale(identifier: model.lang)))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(SettingsPalette.muted)
            SettingsRows {
                ForEach(rows) { row in rowView(row) }
            }
        }
        .padding(.top, 16)
    }

    private func rowView(_ row: UpdatesModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SettingsPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(row.lines, id: \.self) { line in
                        Text(line.text)
                            .font(.system(size: 12))
                            .foregroundStyle(color(line.tone))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing(row)
            }
            if let advice = row.advice, model.expanded.contains(row.kind) {
                Text(advice)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.consent))
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func trailing(_ row: UpdatesModel.Row) -> some View {
        HStack(spacing: 12) {
            switch row.state {
            case .needsUpdate:
                status(model.t("setup.status.outdated"), SettingsPalette.wait)
                button(model.t("setup.action.update")) { model.press(row.kind) }
            case .updating:
                HStack(spacing: 6) {
                    if !still { ProgressView().controlSize(.small).frame(height: 14) }
                    status(model.t("updates.updating"), SettingsPalette.muted)
                }
            case .updated:
                status(model.t("updates.updated"), SettingsPalette.ok)
            case .current:
                status(model.t("updates.current"), SettingsPalette.ok)
            case .failed:
                button(model.t("updates.retry")) { model.press(row.kind) }
            case .checking:
                status(model.t("updates.checking"), SettingsPalette.muted)
            case .channelFailed:
                Button(model.t("updates.why")) { model.toggleWhy(row.kind) }
                    .buttonStyle(LinkButtonStyle())
            case .notConnected:
                EmptyView()
            }
        }
        .fixedSize()
    }

    var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(model.t("updates.note"))
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.isDone {
                    button(model.t("updates.done"), primary: true, enabled: true) { model.close() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    button(model.t("updates.later"), enabled: true) { model.close() }
                    button(model.t("updates.all"), primary: true, enabled: model.canUpdateAll) { model.updateAll() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .fixedSize()
        }
        .padding(.top, 14)
        .padding(.horizontal, 36)
        .padding(.bottom, 18)
        .overlay(alignment: .top) { Rectangle().fill(SettingsPalette.rowLine).frame(height: 1) }
    }

    // MARK: - Pieces

    private func status(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func button(_ title: String, primary: Bool = false, enabled: Bool? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(UpdatesButtonStyle(primary: primary))
            .disabled(!(enabled ?? (model.running == nil)))
    }

    private func color(_ tone: UpdatesModel.Tone) -> Color {
        switch tone {
        case .neutral: return SettingsPalette.muted
        case .step: return SettingsPalette.wait
        case .trouble: return SettingsPalette.warnInk
        }
    }

    /// A clear view behind `content` that hands its height up as it lays
    /// out — inside the scroll view too, where a preference arrives once,
    /// empty (`AGENTS.md` → Pitfalls).
    private func height(_ set: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in set(height) }
        }
    }
}

/// The window's outlined button, and its one blue choice.
struct UpdatesButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.white : SettingsPalette.ink)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                primary ? SettingsPalette.accent.opacity(configuration.isPressed ? 0.8 : 1)
                        : configuration.isPressed ? SettingsPalette.buttonPressed : SettingsPalette.rows))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(primary ? SettingsPalette.accent : SettingsPalette.buttonLine))
            .opacity(isEnabled ? 1 : 0.45)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
