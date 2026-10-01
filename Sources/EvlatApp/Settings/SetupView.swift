import AppKit
import SwiftUI
import EvlatCore

/// The setup window: the mascot at
/// the top, the step under it — both scroll inside the fixed window, the
/// scrolled edge fading — and the footer that never moves: "‹ Back", the
/// dots, "Not now", the primary button.
struct SetupView: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel

    init(model: SetupFlowModel) {
        self.model = model
        self.setup = model.setup
    }

    var body: some View {
        VStack(spacing: 0) {
            FadingScroll(resetOn: model.step) {
                VStack(alignment: .leading, spacing: 0) {
                    SetupMascot(mascot: model.mascot, blinks: model.blinks)
                        .padding(.bottom, 12)
                    // The old step fades out where it stood as the new one
                    // fades in.
                    ZStack(alignment: .topLeading) {
                        step
                            .id(model.step)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    .animation(.easeOut(duration: 0.16), value: model.step)
                }
                .padding(.top, 34)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // What the primary button writes stays in sight right above it
            // (R3), whatever the step's length.
            consent
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            Rectangle().fill(SettingsPalette.paneLine).frame(height: 1)
            SetupFooter(model: model)
        }
        .background(SettingsPalette.pane)
        .ignoresSafeArea()
        .frame(width: SetupWindow.width)
    }

    @ViewBuilder private var consent: some View {
        switch model.step {
        // After "Install" the box goes, unless there is something to write
        // again (a switch turned back on, a refused write): whenever the
        // button says "Install", its lines are above it.
        // Every agent has a card, found or not: the box is for an agent found.
        case .sessions where model.sessionRows.contains(where: { $0.status != .notFound })
            && (!model.installed || !model.installConsent.isEmpty):
            SetupConsent(model: model, button: model.t("setup.flow.install"), lines: model.installConsent,
                         backup: true)
        case .optional where !model.finishConsent.isEmpty:
            SetupConsent(model: model, button: model.t("setup.flow.finish"), lines: model.finishConsent)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var step: some View {
        switch model.step {
        case .hello: HelloStep(model: model)
        case .edge: EdgeStep(model: model)
        case .sessions: SessionsStep(model: model, setup: setup)
        case .chat: ChatStep(model: model, recorder: model.recorder)
        case .optional: OptionalStep(model: model, setup: setup)
        case .done: DoneStep(model: model, setup: setup)
        }
    }
}

// MARK: - Frame

/// A scroll view whose scrolled-away edges fade (`.inner.ft`/`.fb`): 22 pt
/// at the top, 28 at the bottom, each only while there is more that way.
/// Its offset is read from the content's frame, which changes only on a
/// scroll or a new step: a still window draws nothing.
private struct FadingScroll<Content: View>: View {
    let resetOn: SetupFlowModel.Step
    @ViewBuilder let content: Content
    @State private var fadesTop = false
    @State private var fadesBottom = false
    @State private var viewportHeight: CGFloat = 0
    @State private var contentFrame: CGRect = .zero

    private static var space: String { "setup.scroll" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .id(Self.space)
                    // Read where it is from inside: a preference sent out of
                    // the scroll view arrived once, empty, and never again.
                    .background(GeometryReader { inner in
                        Color.clear.onChange(of: inner.frame(in: .named(Self.space)), initial: true) { _, frame in
                            contentFrame = frame
                            updateFades()
                        }
                    })
            }
            .coordinateSpace(name: Self.space)
            .background(GeometryReader { viewport in
                Color.clear.onChange(of: viewport.size.height, initial: true) { _, height in
                    viewportHeight = height
                    updateFades()
                }
            })
            .onChange(of: resetOn) { _, _ in proxy.scrollTo(Self.space, anchor: .top) }
            // Over the edges: the window's ground is one flat colour, so
            // fading into it reads as the content fading.
            .overlay(alignment: .top) { fade(from: .top).frame(height: 22).opacity(fadesTop ? 1 : 0) }
            .overlay(alignment: .bottom) { fade(from: .bottom).frame(height: 28).opacity(fadesBottom ? 1 : 0) }
        }
    }

    private func updateFades() {
        let top = contentFrame.minY < -2
        let bottom = viewportHeight > 0 && contentFrame.maxY > viewportHeight + 2
        if top != fadesTop { fadesTop = top }
        if bottom != fadesBottom { fadesBottom = bottom }
    }

    private func fade(from edge: UnitPoint) -> some View {
        LinearGradient(colors: [SettingsPalette.pane, SettingsPalette.pane.opacity(0)],
                       startPoint: edge, endPoint: edge == .top ? .bottom : .top)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: fadesTop)
            .animation(.easeOut(duration: 0.15), value: fadesBottom)
    }
}

/// The footer: always there, whatever the step's length.
private struct SetupFooter: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 10) {
            if model.showsBack {
                Button(model.t("setup.flow.back")) { model.back() }
                    .buttonStyle(GhostButtonStyle())
                    .padding(.leading, -4)
            }
            StepDots(model: model)
            Spacer(minLength: 0)
            if model.showsSkip {
                Button(model.t("setup.flow.skip")) { model.skip() }
                    .buttonStyle(GhostButtonStyle())
            }
            Button(model.t(model.primaryKey)) { model.primary() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
    }
}

/// Six dots, the current one long; a passed one goes back to its step.
private struct StepDots: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(SetupFlowModel.Step.allCases, id: \.self) { step in
                let on = step == model.step
                Capsule()
                    .fill(on ? SettingsPalette.ink : SettingsPalette.dotOff)
                    .frame(width: on ? 16 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { model.go(to: step) }
                    .accessibilityElement()
                    .accessibilityLabel(model.t("setup.flow.step", ["number": String(step.index + 1),
                                                                     "name": model.t(SetupFlowModel.titleKey(step))]))
                    .accessibilityAddTraits(on ? .isSelected : model.canGo(to: step) ? .isButton : [])
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.step)
    }
}

/// The setup's mascot: the bar's face, still, looking at the chosen edge.
/// It blinks only when `blinks` changes — a `KeyframeAnimator` does not
/// fire on its first appearance, and nothing else moves it.
private struct SetupMascot: View {
    @ObservedObject var mascot: MascotModel
    let blinks: Int

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: blinks) { open in
            MascotBody(pose: Self.pose(gaze: mascot.gaze, open: open), size: 38)
                .frame(width: 38, height: 38)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.11)],
                                         startPoint: .top, endPoint: .bottom)))
        } keyframes: { _ in
            CubicKeyframe(0.06, duration: 0.09)
            CubicKeyframe(0.06, duration: 0.06)
            CubicKeyframe(1.0, duration: 0.12)
        }
        .animation(MascotPose.transition, value: mascot.gaze)
        .accessibilityHidden(true)
    }

    /// The bar's resting face, turned to `gaze`, its eyes `open` of the way.
    static func pose(gaze: CGSize, open: Double) -> MascotPose {
        var pose = MascotPose.resting(for: .idle).blending(gaze: gaze)
        pose.eyeOpen *= open
        return pose
    }
}

// MARK: - Steps

/// A step's title and its first paragraph.
private struct StepHead: View {
    let title: String
    var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.17)
                .foregroundStyle(SettingsPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let text {
                Paragraph(text: text)
            }
        }
    }
}

private struct Paragraph: View {
    let text: String
    var small = false

    var body: some View {
        Text(text)
            .font(.system(size: small ? 12 : 13))
            .lineSpacing(small ? 2 : 3)
            .foregroundStyle(small ? SettingsPalette.muted : SettingsPalette.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HelloStep: View {
    let model: SetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.hello)), text: model.t("setup.flow.hello.body"))
            Paragraph(text: model.t("setup.flow.hello.note"), small: true)
        }
    }
}

private struct EdgeStep: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.edge)), text: model.t("setup.flow.edge.body"))
            HStack(spacing: 10) {
                EdgeBox(edge: .left, title: model.t("setup.flow.edge.left"), selected: model.edge.isLeft) {
                    model.chooseEdge(.left)
                }
                EdgeBox(edge: .right, title: model.t("setup.flow.edge.right"), selected: !model.edge.isLeft) {
                    model.chooseEdge(.right)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One of the edge step's two boxes: a small screen with the bar on its
/// side (`.edge` + `.mini`).
private struct EdgeBox: View {
    let edge: BarPanel.Edge
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: edge.isLeft ? .leading : .trailing) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [SettingsPalette.screenTop, SettingsPalette.screenBottom],
                                             startPoint: .top, endPoint: .bottom))
                    UnevenRoundedRectangle(topLeadingRadius: edge.isLeft ? 0 : 4, bottomLeadingRadius: edge.isLeft ? 0 : 4,
                                           bottomTrailingRadius: edge.isLeft ? 4 : 0, topTrailingRadius: edge.isLeft ? 4 : 0)
                        .fill(Color(white: 0.04))
                        .frame(width: 7)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 28 * 0.44)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.ink)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.rows))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? SettingsPalette.ink : SettingsPalette.edgeLine, lineWidth: 1.5))
            .background(RoundedRectangle(cornerRadius: 10).inset(by: -3)
                .fill(SettingsPalette.ink.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SessionsStep: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.sessions)), text: model.t("setup.flow.sessions.body"))
            let rows = model.sessionRows
            if !rows.contains(where: { $0.status != .notFound }) {
                Paragraph(text: model.t("setup.flow.sessions.none"), small: true)
            } else {
                SettingsRows {
                    ForEach(rows) { row in
                        SetupRowView(row: row, model: setup, showsButton: false, queued: queued(row.item))
                    }
                }
                if model.installed {
                    Paragraph(text: model.t("setup.flow.sessions.hint"), small: true)
                }
            }
        }
    }

    private func queued(_ item: SetupItem) -> Binding<Bool> {
        Binding(get: { model.isQueued(item) }, set: { model.setQueued(item, $0) })
    }
}

/// What the button under it writes (R3), right above it:
/// "What Install writes → ~/.claude/settings.json · hooks…".
private struct SetupConsent: View {
    let model: SetupFlowModel
    let button: String
    let lines: [String]
    var backup = false

    var body: some View {
        if lines.isEmpty {
            if backup {
                Paragraph(text: model.t("setup.consent.nothing"), small: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.t("setup.consent.title", ["button": button]))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                ConsentLines(lines: lines)
                if backup {
                    Text(model.t("setup.consent.backup"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.consent))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsPalette.consentLine))
        }
    }
}

private struct ChatStep: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var recorder: HotKeyRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.chat)), text: model.t("setup.flow.chat.body"))
            SettingsRows {
                RowBox {
                    HStack(spacing: 10) {
                        RowTitle(name: model.t("settings.chat.hotkey"), detail: model.t("setup.flow.chat.hotkey.detail"))
                        KeyCap(text: recorder.isRecording ? model.t("settings.chat.hotkey.recording") : model.hotKey.title,
                               recording: recorder.isRecording, off: !model.isHotKeyOn)
                        Button(model.t(recorder.isRecording ? "settings.chat.hotkey.cancel"
                                                            : "settings.chat.hotkey.change")) {
                            model.toggleRecording()
                        }
                        .buttonStyle(SmallButtonStyle())
                    }
                    if let line = recorder.text(in: model.lang) {
                        Text(line.0).font(.system(size: 11.5))
                            .foregroundStyle(line.trouble ? SettingsPalette.wait : SettingsPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.showsModes {
                SettingsRows {
                    ForEach(PermissionMode.offered, id: \.self) { mode in
                        ChoiceRow(title: model.t(ChatModel.modeKey(mode)),
                                  badge: mode == .standard ? model.t("settings.chat.modes.recommended") : nil,
                                  detail: model.t(ChatModel.modeDetailKey(mode)),
                                  selected: model.mode == mode) { model.setMode(mode) }
                    }
                }
            }
            switch model.claude {
            case .found(let path):
                Paragraph(text: model.t("settings.chat.claude.found", ["path": SettingsModel.tilde(path)]), small: true)
            case .missing:
                Paragraph(text: model.t("settings.chat.claude.missing"), small: true)
            case .looking:
                Paragraph(text: model.t("settings.chat.claude.looking"), small: true)
            }
        }
    }
}

private struct OptionalStep: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.optional)))
            SettingsRows {
                if let login = setup.row(.loginItem) {
                    SetupRowView(row: login, model: setup, showsButton: false, monospaced: false,
                                 queued: queued(.loginItem))
                }
                if let command = setup.row(.commandLink) {
                    SetupRowView(row: command, model: setup, showsButton: false, queued: queued(.commandLink))
                }
                RowBox {
                    HStack(spacing: 10) {
                        RowTitle(name: model.t("setup.flow.remote"), detail: model.t("setup.flow.remote.detail"))
                        Text(model.t("setup.flow.remote.later"))
                            .font(.system(size: 12)).foregroundStyle(SettingsPalette.muted).fixedSize()
                    }
                }
            }
        }
    }

    private func queued(_ item: SetupItem) -> Binding<Bool> {
        Binding(get: { model.isQueued(item) }, set: { model.setQueued(item, $0) })
    }
}

private struct DoneStep: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHead(title: model.t(SetupFlowModel.titleKey(.done)))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.summary, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.mark(line.mark))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Self.color(line.mark))
                            .frame(width: 14)
                        Text(line.text)
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Paragraph(text: model.t("setup.flow.done.note"), small: true)
        }
    }

    private static func mark(_ mark: SetupFlowModel.SummaryLine.Mark) -> String {
        switch mark {
        case .done: return "✓"
        case .pending: return "…"
        case .skipped: return "–"
        }
    }

    private static func color(_ mark: SetupFlowModel.SummaryLine.Mark) -> Color {
        switch mark {
        case .done: return SettingsPalette.ok
        case .pending: return SettingsPalette.wait
        case .skipped: return SettingsPalette.radio
        }
    }
}

// MARK: - Buttons

/// `.btn.pri`: the step's one dark button.
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SettingsPalette.selectedInk)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(SettingsPalette.selected.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(isEnabled ? 1 : 0.5)
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// `.btn.ghost`: "‹ Back" and "Not now".
private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SettingsPalette.ghost.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
