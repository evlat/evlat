import AppKit
import SwiftUI
import EvlatCore

/// The setup as a short story the mascot tells, on the whole screen
/// (`SetupWindow`): the chapter's stage — the mascot, and what it shows —
/// in the middle, its line under it, what the chapter asks for under that,
/// and the footer that never moves: "‹ Back", the chapters, "Not now", the
/// primary button.
///
/// Motion answers the story, and only it: the entrance lands once from
/// blurred to sharp; a new chapter comes in the same way; the sessions
/// chapter plays its short loop while it is on screen. A still chapter
/// draws nothing. With reduced motion everything only fades.
struct SetupView: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var still

    /// `arrived`: already in, without the entrance — a picture of a
    /// chapter rather than its opening.
    init(model: SetupFlowModel, arrived: Bool = false) {
        self.model = model
        self.setup = model.setup
        _arrived = State(initialValue: arrived)
    }

    /// The column the story is set in: a comfortable line, narrower on a
    /// small screen.
    static func columnWidth(screen: CGFloat) -> CGFloat { max(360, min(560, screen - 96)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // A dim over the blurred desktop, heavier at the edges: the
                // story is read in the middle.
                RadialGradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.62)],
                               center: .center, startRadius: 80,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.7)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    chapter
                        .frame(width: Self.columnWidth(screen: geometry.size.width))
                    Spacer(minLength: 24)
                    SetupFooter(model: model)
                        .frame(width: Self.columnWidth(screen: geometry.size.width))
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: arrived || still ? 0 : 24)
                .scaleEffect(arrived || still ? 1 : 1.04)
                .opacity(arrived ? 1 : 0)
                CloseButton(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(28)
                    .opacity(arrived ? 1 : 0)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(still ? .easeOut(duration: 0.2) : .smooth(duration: 0.8).delay(0.12)) { arrived = true }
        }
    }

    /// One chapter: its stage, its line, what it asks. The old one leaves
    /// blurred as the new one comes in sharp.
    private var chapter: some View {
        ZStack {
            VStack(spacing: 0) {
                SetupStage(model: model)
                    .frame(minHeight: 140)
                    .padding(.bottom, 28)
                StoryLine(title: model.t(SetupFlowModel.titleKey(model.step)), text: body(of: model.step))
                    .padding(.bottom, 24)
                // Whole where it fits, which is everywhere but a small
                // screen: the chapter then sits in the middle as a group.
                ViewThatFits(in: .vertical) {
                    asks
                    ScrollView(.vertical) { asks }
                        .scrollIndicators(.never)
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
            .id(model.step)
            .transition(still ? .opacity : .asymmetric(
                insertion: .modifier(active: ChapterBlur(amount: 1), identity: ChapterBlur(amount: 0)),
                removal: .modifier(active: ChapterBlur(amount: 1, rising: true), identity: ChapterBlur(amount: 0)))
            )
        }
        .animation(still ? .easeOut(duration: 0.15) : .smooth(duration: 0.45), value: model.step)
    }

    /// What the chapter asks, narrower than its line.
    private var asks: some View {
        VStack(spacing: 14) {
            step
            consent
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    /// The line under the title; the done chapter has its summary instead.
    private func body(of step: SetupFlowModel.Step) -> String? {
        switch step {
        case .hello: return model.t("setup.flow.hello.body")
        case .edge: return model.t("setup.flow.edge.body")
        case .sessions: return model.t("setup.flow.sessions.body")
        case .chat: return model.t("setup.flow.chat.body")
        case .optional, .done: return nil
        }
    }

    @ViewBuilder private var consent: some View {
        switch model.step {
        // After "Install" the box goes, unless there is something to write
        // again (a switch turned back on, a refused write): whenever the
        // button says "Install", its lines are above it.
        case .sessions where !model.sessionRows.isEmpty && (!model.installed || !model.installConsent.isEmpty):
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

/// A chapter coming in or going: blurred, faded and a little off where it
/// settles — below on the way in, above on the way out.
private struct ChapterBlur: ViewModifier {
    let amount: Double
    var rising = false

    func body(content: Content) -> some View {
        content
            .blur(radius: 14 * amount)
            .opacity(1 - amount)
            .offset(y: (rising ? -14 : 18) * amount)
    }
}

// MARK: - The stage

/// What each chapter shows above its line. The mascot is the teller; its
/// size and face follow the story.
private struct SetupStage: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var mascot: MascotModel

    init(model: SetupFlowModel) {
        self.model = model
        self.mascot = model.mascot
    }

    var body: some View {
        switch model.step {
        case .hello:
            StoryMascot(pose: .resting(for: .idle), gaze: mascot.gaze, blinks: model.blinks, size: 116)
        case .edge:
            // It looks at the edge it is about to live on; the real bar
            // moves there, above this stage.
            StoryMascot(pose: .resting(for: .idle), gaze: mascot.gaze, blinks: model.blinks, size: 96)
        case .sessions:
            SessionsDemo(model: model)
        case .chat:
            ChatDemo(model: model, gaze: mascot.gaze)
        case .optional:
            StoryMascot(pose: .resting(for: .idle), gaze: mascot.gaze, blinks: model.blinks, size: 84)
        case .done:
            StoryMascot(pose: .resting(for: .review), gaze: mascot.gaze, blinks: model.blinks, size: 116)
        }
    }
}

/// The bar's face, large, in its black tile. It blinks when `blinks`
/// changes — a `KeyframeAnimator` does not fire on its first appearance,
/// and nothing else moves it.
private struct StoryMascot: View {
    let pose: MascotPose
    let gaze: CGSize
    let blinks: Int
    let size: CGFloat

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: blinks) { open in
            MascotBody(pose: Self.pose(pose, gaze: gaze, open: open), size: size)
                .frame(width: size, height: size)
                .padding(size * 0.1)
                .background(RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                    .fill(Color.black))
                .shadow(color: .black.opacity(0.45), radius: size * 0.3, y: size * 0.1)
        } keyframes: { _ in
            CubicKeyframe(0.06, duration: 0.09)
            CubicKeyframe(0.06, duration: 0.06)
            CubicKeyframe(1.0, duration: 0.12)
        }
        .animation(MascotPose.transition, value: gaze)
        .animation(MascotPose.transition, value: pose)
        .accessibilityHidden(true)
    }

    /// `pose` turned to `gaze`, its eyes `open` of the way.
    static func pose(_ pose: MascotPose, gaze: CGSize, open: Double) -> MascotPose {
        var pose = pose.blending(gaze: gaze)
        pose.eyeOpen *= open
        return pose
    }
}

/// The sessions chapter's stage: a small bar — the mascot at its head, three
/// sessions under it — playing what Evlat will show. One session starts,
/// one stops for the user, one finishes; the mascot's face is the bar's
/// aggregate. It moves in beats while it is on screen, and holds still with
/// reduced motion.
private struct SessionsDemo: View {
    let model: SetupFlowModel
    @State private var scene = 0
    @Environment(\.accessibilityReduceMotion) private var still

    /// Each beat's three sessions.
    static let scenes: [[Phase]] = [
        [.working, .idle, .idle],
        [.working, .working, .idle],
        [.working, .waiting, .idle],
        [.review, .working, .idle],
    ]

    static func face(_ phases: [Phase]) -> Phase {
        phases.max { $0.priority < $1.priority } ?? .idle
    }

    private var phases: [Phase] { Self.scenes[still ? 2 : scene % Self.scenes.count] }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                StoryMascot(pose: .resting(for: Self.face(phases)), gaze: .zero, blinks: scene, size: 52)
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    Circle()
                        .strokeBorder(Self.ring(phase), lineWidth: 3)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.black))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 14 + 52 * 1.2 + 14 - 11)
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    HStack(spacing: 8) {
                        Text(model.t("setup.story.demo.\(index + 1)"))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(model.t(StatusLine.statusKey(phase: phase, waitKind: nil)))
                            .foregroundStyle(Self.word(phase))
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(height: 36, alignment: .center)
                }
            }
            .frame(width: 190, alignment: .leading)
        }
        .animation(.smooth(duration: 0.35), value: scene)
        .task {
            guard !still else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.7))
                scene += 1
            }
        }
        .accessibilityHidden(true)
    }

    /// The bar's own ring colours (`SessionIndicator.color`).
    static func ring(_ phase: Phase) -> Color {
        phase == .idle ? Color.white.opacity(0.18) : SessionIndicator.color(phase)
    }

    static func word(_ phase: Phase) -> Color {
        phase == .idle || phase == .working ? Color.white.opacity(0.45) : SessionIndicator.color(phase)
    }
}

/// The chat chapter's stage: the mascot, and a balloon with a file dropped
/// on it and a question.
private struct ChatDemo: View {
    let model: SetupFlowModel
    let gaze: CGSize

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            StoryMascot(pose: .resting(for: .idle), gaze: CGSize(width: 0.6, height: 0), blinks: model.blinks,
                        size: 76)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 11))
                    Text(model.t("setup.story.chat.file"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                Text(model.t("setup.story.chat.prompt"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(16)
            .frame(width: 250, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ChatPalette.ground))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ChatPalette.edge))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Frame

/// The chapter's title, in the mascot's voice, and its line.
private struct StoryLine: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let text {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The stage's way out, at the screen's corner: the setup goes to the bar,
/// nothing more written.
private struct CloseButton: View {
    let model: SetupFlowModel
    @State private var hovered = false

    var body: some View {
        Button { model.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(model.t("setup.story.close"))
        .accessibilityLabel(model.t("setup.story.close"))
    }
}

/// The footer: always there, whatever the chapter.
private struct SetupFooter: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        ZStack {
            StepDots(model: model)
            HStack(spacing: 10) {
                if model.showsBack {
                    Button(model.t("setup.flow.back")) { model.back() }
                        .buttonStyle(GhostButtonStyle())
                        .padding(.leading, -6)
                }
                Spacer(minLength: 0)
                if model.showsSkip {
                    Button(model.t("setup.flow.skip")) { model.skip() }
                        .buttonStyle(GhostButtonStyle())
                }
                Button(model.t(model.primaryKey)) { model.primary() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The six chapters, the current one long; a passed one goes back to it.
private struct StepDots: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupFlowModel.Step.allCases, id: \.self) { step in
                let on = step == model.step
                Capsule()
                    .fill(Color.white.opacity(on ? 0.92 : step < model.step ? 0.4 : 0.18))
                    .frame(width: on ? 22 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -5))
                    .onTapGesture { model.go(to: step) }
                    .accessibilityElement()
                    .accessibilityLabel(model.t("setup.flow.step", ["number": String(step.index + 1),
                                                                     "name": model.t(SetupFlowModel.titleKey(step))]))
                    .accessibilityAddTraits(on ? .isSelected : model.canGo(to: step) ? .isButton : [])
            }
        }
        .animation(.smooth(duration: 0.35), value: model.step)
    }
}

// MARK: - Steps

private struct Paragraph: View {
    let text: String
    var small = false

    var body: some View {
        Text(text)
            .font(.system(size: small ? 12.5 : 13.5))
            .lineSpacing(small ? 2 : 3)
            .foregroundStyle(.white.opacity(small ? 0.5 : 0.68))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
    }
}

private struct HelloStep: View {
    let model: SetupFlowModel

    var body: some View {
        Paragraph(text: model.t("setup.flow.hello.note"), small: true)
    }
}

private struct EdgeStep: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 14) {
            EdgeBox(edge: .left, title: model.t("setup.flow.edge.left"), selected: model.edge.isLeft) {
                model.chooseEdge(.left)
            }
            EdgeBox(edge: .right, title: model.t("setup.flow.edge.right"), selected: !model.edge.isLeft) {
                model.chooseEdge(.right)
            }
        }
        .frame(width: 380)
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
                    // A desktop, lighter than the stage, so the black bar
                    // on it reads.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.14)],
                                             startPoint: .top, endPoint: .bottom))
                    UnevenRoundedRectangle(topLeadingRadius: edge.isLeft ? 0 : 4, bottomLeadingRadius: edge.isLeft ? 0 : 4,
                                           bottomTrailingRadius: edge.isLeft ? 4 : 0, topTrailingRadius: edge.isLeft ? 4 : 0)
                        .fill(Color.black)
                        .frame(width: 8)
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
        VStack(spacing: 12) {
            let rows = model.sessionRows
            if rows.isEmpty {
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
        VStack(spacing: 10) {
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
                    ForEach([PermissionMode.auto, .acceptEdits, .ask], id: \.self) { mode in
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
        VStack(spacing: 12) {
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
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.summary, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.mark(line.mark))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Self.color(line.mark))
                            .frame(width: 14)
                        Text(line.text)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
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

/// The chapter's one button: the mascot's white on the stage's dark.
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.95)))
            .opacity(isEnabled ? 1 : 0.5)
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// `.btn.ghost`: "‹ Back" and "Not now".
private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.4 : 0.62))
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
