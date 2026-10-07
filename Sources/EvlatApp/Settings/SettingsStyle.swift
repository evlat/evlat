import AppKit
import SwiftUI

// The settings window's look: the design's light values, with a dark counterpart each, as one palette and a
// few small parts every section is built from.

/// A colour that follows the window's appearance.
private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
}

enum SettingsPalette {
    static let side = dynamic(0xEEEFF2, 0x1E2128)
    static let sideLine = dynamic(0xDFE1E5, 0x2E333C)
    static let pane = dynamic(0xFBFBFC, 0x171A21)
    static let paneLine = dynamic(0xECEEF1, 0x2A2F39)
    static let ink = dynamic(0x16181C, 0xE8EBF0)
    static let body = dynamic(0x4B5058, 0xB4BAC4)
    static let muted = dynamic(0x80858D, 0x8E96A3)
    static let rows = dynamic(0xFFFFFF, 0x1F232B)
    static let rowsLine = dynamic(0xE3E5E9, 0x2E333C)
    static let rowLine = dynamic(0xECEEF1, 0x2A2F39)
    static let serverRows = dynamic(0xFAFBFC, 0x1B1F26)
    static let button = dynamic(0xECEEF1, 0x2C313A)
    static let buttonPressed = dynamic(0xDFE2E7, 0x383E48)
    static let warn = dynamic(0xFBECEB, 0x3A2322)
    static let warnInk = dynamic(0xB3261E, 0xF08A80)
    static let ok = dynamic(0x1F8F5F, 0x3FB67F)
    static let wait = dynamic(0xB77912, 0xE0A23A)
    static let dot = dynamic(0xC7861A, 0xE0A23A)
    static let manual = dynamic(0xF5F6F8, 0x14171D)
    static let consent = dynamic(0xF3F5F8, 0x1A1E25)
    static let consentLine = dynamic(0xE3E6EB, 0x2E333C)
    static let chevron = dynamic(0xEEF0F3, 0x2A2F38)
    static let chevronHover = dynamic(0xE2E5EA, 0x353B45)
    static let rowHover = dynamic(0xF6F7F9, 0x232830)
    static let link = dynamic(0x3D63D8, 0x7C9BFF)
    static let key = dynamic(0xFFFFFF, 0x252A33)
    static let keyLine = dynamic(0xD7D9DE, 0x3A404B)
    static let selected = dynamic(0x16181C, 0xE8EBF0)
    static let selectedInk = dynamic(0xFFFFFF, 0x16181C)
    static let radio = dynamic(0xB9BCC3, 0x5A616D)
    // The setup's: its dots, the edge picture, the small and ghost buttons.
    static let dotOff = dynamic(0xD3D5DA, 0x3A404B)
    static let edgeLine = dynamic(0xDCDEE3, 0x3A404B)
    static let screenTop = dynamic(0xDFE4EA, 0x2A3440)
    static let screenBottom = dynamic(0xC8D0D9, 0x1A2029)
    static let ghost = dynamic(0x6B7079, 0x9AA3B1)
    /// The update window's buttons: outlined, and its one blue choice.
    static let buttonLine = dynamic(0xD2D2D7, 0x3A404B)
    static let accent = dynamic(0x0A63D8, 0x3B7BEA)
    // A tag beside a name: green for what an agent can do, amber for a
    // caution.
    static let tagOk = dynamic(0xEEF8F2, 0x17291F)
    static let tagOkLine = dynamic(0xBFE2CF, 0x2C5A41)
    static let tagWait = dynamic(0xFBF4E4, 0x2E2414)
    static let tagWaitLine = dynamic(0xECD7A9, 0x5E4A22)
    /// The update strip once automatic updates kept things current: a calm
    /// blue beside the tags' amber.
    static let calm = dynamic(0xF1F6FD, 0x17222F)
    static let calmLine = dynamic(0xCFDFF3, 0x2B3F58)
}

/// A small tag beside a name (`.tag`): "Available in chat", "experimental".
struct NameTag: View {
    let text: String
    var caution = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(caution ? SettingsPalette.wait : SettingsPalette.ok)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(caution ? SettingsPalette.tagWait : SettingsPalette.tagOk))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(caution ? SettingsPalette.tagWaitLine : SettingsPalette.tagOkLine))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A group: its small uppercase heading, the rows' box, and an optional
/// note under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased(with: Locale.current))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.55)
                .foregroundStyle(SettingsPalette.muted)
                .padding(.leading, 2)
            SettingsRows { content }
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The white box rows sit in, a hairline between each.
struct SettingsRows<Content: View>: View {
    var fill = SettingsPalette.rows
    @ViewBuilder let content: Content

    var body: some View {
        _VariadicView.Tree(RowsLayout()) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.rowsLine))
    }

    private struct RowsLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    if child.id != children.first?.id {
                        Rectangle().fill(SettingsPalette.rowLine).frame(height: 1)
                    }
                    child
                }
            }
        }
    }
}

/// A row's name and the line under it (a path in monospace, or a sentence).
struct RowTitle: View {
    let name: String
    var detail: String?
    var monospaced = false
    var code = false
    /// A tag beside the name (`NameTag`).
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(code ? .system(size: 12.5, weight: .semibold, design: .monospaced)
                               : .system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge { NameTag(text: badge) }
            }
            if let detail {
                Text(detail)
                    .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row's padding: the design's 10 × 12.
struct RowBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "✓ Installed", "Old", "Not installed"…
struct StatusText: View {
    let status: SetupStatus
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: status == .installed ? .medium : .regular))
            .foregroundStyle(status == .installed ? SettingsPalette.ok
                             : status == .outdated ? SettingsPalette.wait : SettingsPalette.muted)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The small grey button (`.btn.sm`), its warning form, or the dark one
/// a question's first choice is (`.btn.pri`).
struct SmallButtonStyle: ButtonStyle {
    var warn = false
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: warn || primary ? .medium : .regular))
            .foregroundStyle(warn ? SettingsPalette.warnInk : primary ? SettingsPalette.selectedInk : SettingsPalette.ink)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                warn ? SettingsPalette.warn
                     : primary ? SettingsPalette.selected.opacity(configuration.isPressed ? 0.8 : 1)
                     : configuration.isPressed ? SettingsPalette.buttonPressed : SettingsPalette.button))
            .opacity(isEnabled ? 1 : 0.45)
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// The blue text button (`.lnk`).
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(SettingsPalette.link.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

/// What pressing the button beside it writes (R3): one line per file,
/// each after an arrow.
struct ConsentLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("→").foregroundStyle(SettingsPalette.muted.opacity(0.8))
                    Text(line).foregroundStyle(SettingsPalette.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A button and, right before it, what it writes.
struct ConsentAction: View {
    let lines: [String]
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ConsentLines(lines: lines)
            Button(title, action: action)
                .buttonStyle(SmallButtonStyle())
                .disabled(!enabled)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.consent))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsPalette.consentLine))
    }
}

/// A block to paste (`.manual`): its text scrolls inside a fixed height,
/// with its buttons and a line under them.
struct ManualBox<Actions: View>: View {
    var title: String?
    var lead: String?
    let text: String
    var footnote: String?
    var maxHeight: CGFloat = 92
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
            }
            if let lead {
                Text(lead).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SettingsPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { actions }
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.manual))
    }
}

/// The 24 pt box with the chevron: turns a quarter when its row is open.
struct Chevron: View {
    let open: Bool
    let hovered: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(SettingsPalette.body)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? SettingsPalette.chevronHover : SettingsPalette.chevron))
            .animation(.easeOut(duration: 0.2), value: open)
    }
}

/// A radio choice (`.choice`): its circle, name and what it does.
struct ChoiceRow: View {
    let title: String
    var badge: String?
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? SettingsPalette.ink : SettingsPalette.radio, lineWidth: 1.5)
                    if selected { Circle().fill(SettingsPalette.ink).padding(3.5) }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsPalette.ink)
                        if let badge {
                            Text(" · " + badge).font(.system(size: 13)).foregroundStyle(SettingsPalette.muted)
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(SettingsPalette.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
