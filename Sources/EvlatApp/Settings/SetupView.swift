import AppKit
import SwiftUI
import EvlatCore

/// What is the same on every step: the frame, the footer's height and the
/// primary button's size. Nothing here depends on the language or the step,
/// so the button never moves and no step grows the frame.
enum SetupLayout {
    static let size = CGSize(width: 380, height: 460)
    static let footerHeight: CGFloat = 72
    static var bodyHeight: CGFloat { size.height - footerHeight }
    static let side: CGFloat = 24
    /// Wide enough for the longest title in the twelve tables (a test
    /// measures them) and the same for all.
    static let primary = CGSize(width: 132, height: 38)
}

/// The setup's colours: dark in both appearances, like the bar and the
/// balloon it opens beside, not the settings window's light-and-dark pairs.
enum SetupPalette {
    private static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: opacity)
    }

    static let groundTop = hex(0x17181B)
    static let groundBottom = hex(0x111214)
    static let text = hex(0xF2F2F2)
    static let body = hex(0xB9BCC3)
    static let line = hex(0xA9ACB3)
    static let muted = hex(0x8A8D93)
    static let faint = hex(0x6D7076)
    static let ink = hex(0x111214)
    static let amber = SessionIndicator.amber
    static let green = SessionIndicator.green
    static let switchOff = hex(0x3A3C40)
    static let dot = hex(0x2E3034)
    static let dotPast = hex(0x6A6D73)
    static let radio = hex(0x5A5D63)
    static let playLine = hex(0x44474D)
    static let tickOff = hex(0x55585E)
    static let field = Color.white.opacity(0.035)
    static let fieldOn = Color.white.opacity(0.065)
    static let fieldLine = Color.white.opacity(0.08)
    static let fieldOnLine = Color.white.opacity(0.5)
    static let rule = Color.white.opacity(0.07)
    static let pill = Color.white.opacity(0.07)
    static let pillLine = Color.white.opacity(0.09)
    static let idleRing = Color.white.opacity(0.32)
    static let screenTop = hex(0x3E86AE)
    static let screenBottom = hex(0x22547D)
    static let window = hex(0xE9EAEC)
    static let menuBar = Color.white.opacity(0.22)
    static let closeLight = hex(0xFF5F57)
    static let minimizeLight = hex(0xFEBC2E)
    static let zoomLight = hex(0x28C840)
}

/// The setup: one step, always the same 380 × 460. The step's body is
/// clipped to its own height and never scrolls (a test measures every step
/// in every language against it), and the footer under it never moves:
/// "‹ Back", the progress, "Not now", the primary button.
struct SetupView: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel
    /// Drawn for a picture: no layer-driven motion, which a renderer cannot
    /// draw.
    var still = false

    init(model: SetupFlowModel, still: Bool = false) {
        self.model = model
        self.setup = model.setup
        self.still = still
    }

    var body: some View {
        ZStack {
            SetupGround().ignoresSafeArea()
            VStack(spacing: 0) {
                // The old step fades out where it stood as the new one
                // fades in; nothing slides.
                ZStack(alignment: .topLeading) {
                    SetupStepBody(model: model, setup: setup, step: model.step, still: still)
                        .id(model.step)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: 0.12), value: model.step)
                .frame(width: SetupLayout.size.width, height: SetupLayout.bodyHeight, alignment: .topLeading)
                .clipped()
                SetupFooter(model: model)
                    .frame(width: SetupLayout.size.width, height: SetupLayout.footerHeight)
            }
            .frame(width: SetupLayout.size.width, height: SetupLayout.size.height)
        }
        .overlay(alignment: .topTrailing) {
            SetupClose(model: model)
                .padding(.top, 16)
                .padding(.trailing, 16)
        }
        // The pictures are of the user's bar: its mascot is the one chosen.
        .environment(\.mascotRig, model.mascotRig)
        .environment(\.colorScheme, .dark)
        // Built again in a new language (Settings → General → Language), as
        // the settings window is; the step is the model's, so it stays.
        .id(model.lang)
    }
}

/// The ×, in the top corner on the far side from the title (the design's, for
/// either edge): the panel has no title bar, and Esc does not close it, so
/// this and "Finish" are the ways out.
private struct SetupClose: View {
    let model: SetupFlowModel
    @State private var hovered = false

    var body: some View {
        Button { model.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? SetupPalette.text : SetupPalette.muted)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? SetupPalette.fieldOn : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(model.t("setup.flow.close")))
    }
}

/// The panel's ground: a faint light from above on two near-blacks.
private struct SetupGround: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [SetupPalette.groundTop, SetupPalette.groundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.06), .clear], center: .top, startRadius: 0, endRadius: 260)
        }
    }
}

// MARK: - Body

/// One step's body at its natural height: the part a test measures against
/// `SetupLayout.bodyHeight`. Whatever sits at the bottom (a note) is pushed
/// there by a spacer that takes no height of its own.
struct SetupStepBody: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var setup: SetupModel
    let step: SetupFlowModel.Step
    var still = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupWho(model: model)
            switch step {
            case .agents: AgentsStep(model: model)
            case .connected: ConnectedStep(model: model, still: still)
            case .bar: BarStep(model: model)
            case .finish: FinishStep(model: model)
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, SetupLayout.side)
        .padding(.bottom, 14)
        .frame(width: SetupLayout.size.width, alignment: .topLeading)
    }
}

/// Who is speaking: the small mascot and "Setup".
private struct SetupWho: View {
    let model: SetupFlowModel

    var body: some View {
        HStack(spacing: 8) {
            MascotBody(pose: MascotPose.resting(for: .idle), size: 18)
                .frame(width: 18, height: 18)
            Text(model.t("setup.flow.who"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SetupPalette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .tracking(-0.44)
            .foregroundStyle(SetupPalette.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StepText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(SetupPalette.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// The note at the step's foot.
private struct StepNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .foregroundStyle(SetupPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1 · Agents

private struct AgentsStep: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        let tiles = model.tiles
        VStack(alignment: .leading, spacing: 0) {
            if tiles.isEmpty {
                StepTitle(text: model.t("setup.flow.agents.none.title"))
                StepText(text: model.t("setup.flow.agents.none.text"))
                // The pages that tell how to get an agent, in the browser.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { links }
                    VStack(alignment: .leading, spacing: 8) { links }
                }
                .padding(.top, 22)
                Spacer(minLength: 10)
                StepNote(text: model.t("setup.flow.agents.none.note"))
            } else {
                StepTitle(text: model.t(model.reopened ? "setup.flow.agents.title.again" : "setup.flow.agents.title"))
                StepText(text: introduction)
                // Three to a row; a fourth agent starts the next one.
                VStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: 3)), id: \.self) { start in
                        HStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { column in
                                if start + column < tiles.count {
                                    let tile = tiles[start + column]
                                    AgentTile(tile: tile) { model.setQueued(tile.item, !tile.selected) }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 24)
                Spacer(minLength: 10)
                StepNote(text: model.t(model.pendingWrites.isEmpty ? "setup.flow.agents.note.done"
                                                                   : "setup.flow.agents.note"))
            }
        }
    }

    @ViewBuilder private var links: some View {
        ForEach(model.installLinks) { link in
            Button { model.openInstallPage(link) } label: {
                Text(model.t("setup.flow.agents.install", ["agent": model.t(link.nameKey)]))
                    .font(.system(size: 13))
                    .foregroundStyle(SetupPalette.text)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SetupPalette.pill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SetupPalette.pillLine))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The sentence under the title: it points at the bar and its rings.
    private var introduction: String {
        if model.reopened { return model.t("setup.flow.agents.text.again") }
        switch model.openSessionTotal {
        case 0: return model.t("setup.flow.agents.text.none")
        case 1: return model.t("setup.flow.agents.text.one")
        case let count: return model.t("setup.flow.agents.text", ["count": String(count)])
        }
    }
}

/// One agent: its ring as the bar draws it, its name, a line, and the mark
/// in the corner that says whether it is chosen. A connected one is drawn
/// done and takes no press.
private struct AgentTile: View {
    let tile: SetupFlowModel.Tile
    let action: () -> Void

    var body: some View {
        if tile.mood == .choice {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tile.selected ? .isSelected : [])
        } else {
            face
        }
    }

    private var face: some View {
        VStack(spacing: 9) {
            SetupRing(source: tile.source, look: tile.selected ? .on : .idle, size: 34)
            Text(tile.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SetupPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(tile.note ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(noteColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, -5)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tile.selected ? SetupPalette.fieldOn : SetupPalette.field))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tile.selected ? SetupPalette.fieldOnLine : SetupPalette.fieldLine))
        .overlay(alignment: .topTrailing) { tick.padding(9) }
        .opacity(tile.selected || tile.mood == .done ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([tile.name, tile.note].compactMap { $0 }.joined(separator: ", ")))
    }

    private var noteColor: Color {
        switch tile.tone {
        case .plain: return SetupPalette.muted
        case .ok: return SetupPalette.green
        case .caution: return SetupPalette.amber
        }
    }

    @ViewBuilder private var tick: some View {
        ZStack {
            if tile.mood == .dim {
                EmptyView()
            } else if tile.selected {
                Circle().fill(tile.mood == .done ? SetupPalette.green : SetupPalette.text)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(tile.mood == .done ? Color(white: 0.03) : SetupPalette.ink)
            } else {
                Circle().strokeBorder(SetupPalette.tickOff, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - 2 · Connected

private struct ConnectedStep: View {
    @ObservedObject var model: SetupFlowModel
    let still: Bool

    var body: some View {
        let allHeard = model.allHeard
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(text: model.t(allHeard ? "setup.flow.connected.title.heard" : "setup.flow.connected.title"))
            StepText(text: model.t(allHeard ? "setup.flow.connected.text.heard" : "setup.flow.connected.text"))
            VStack(alignment: .leading, spacing: 18) {
                ForEach(model.listening) { row in
                    HStack(spacing: 14) {
                        SetupRing(source: row.source, look: row.heard ? .heard : .turning, size: 34, still: still)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SetupPalette.text)
                            Text(row.line)
                                .font(.system(size: 13))
                                .foregroundStyle(row.heard ? SetupPalette.green : SetupPalette.line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 26)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 3 · Bar

private struct BarStep: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        let edge = model.edge
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(text: model.t("setup.flow.bar.title"))
            SectionLabel(model.t("setup.flow.bar.place"), lang: model.lang)
                .padding(.top, 14)
            HStack(spacing: 12) {
                Choice(title: model.t("setup.flow.bar.left"), selected: edge.isLeft,
                       picture: ScreenPicture(left: true)) { model.chooseEdge(.left) }
                Choice(title: model.t("setup.flow.bar.right"), selected: !edge.isLeft,
                       picture: ScreenPicture(left: false)) { model.chooseEdge(.right) }
            }
            .padding(.top, 10)
            SectionLabel(model.t("setup.flow.bar.visibility"), lang: model.lang)
                .padding(.top, 14)
            HStack(spacing: 12) {
                Choice(title: model.t("setup.flow.bar.always"), selected: model.visibility == .always,
                       picture: EdgePicture(left: edge.isLeft, tucked: false)) { model.chooseVisibility(.always) }
                Choice(title: model.t("setup.flow.bar.smart"), selected: model.visibility == .smart,
                       picture: EdgePicture(left: edge.isLeft, tucked: true)) { model.chooseVisibility(.smart) }
            }
            .padding(.top, 10)
            // Two lines are kept for it: it is one sentence or the other,
            // and the choices above do not move for it.
            Text(model.t(model.edgeCovered == true ? "setup.flow.bar.hint.covered" : "setup.flow.bar.hint.smart"))
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(SetupPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
    }

    private struct SectionLabel: View {
        let text: String
        let lang: String

        init(_ text: String, lang: String) {
            self.text = text
            self.lang = lang
        }

        var body: some View {
            // The language Settings picked, not the system's: Turkish "i"
            // goes to "İ" only by its own rules.
            Text(text.uppercased(with: Locale(identifier: lang)))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(SetupPalette.faint)
        }
    }
}

/// One of the bar step's choices: a picture and, under it, its name.
private struct Choice<Picture: View>: View {
    let title: String
    let selected: Bool
    let picture: Picture
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture
                HStack(spacing: 7) {
                    Circle()
                        .strokeBorder(selected ? SetupPalette.text : SetupPalette.radio, lineWidth: selected ? 4 : 1.5)
                        .frame(width: 12, height: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SetupPalette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 4)
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? SetupPalette.fieldOn : SetupPalette.field))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? SetupPalette.fieldOnLine : SetupPalette.fieldLine))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pictures' height: both rows alike, and what the body's height in
/// every language was measured with.
private let pictureHeight: CGFloat = 48

/// A whole Mac screen at 16:10, menu bar on top, with the bar on one edge,
/// halfway down — where `BarPanel.origin` puts it.
private struct ScreenPicture: View {
    let left: Bool

    private static let size = CGSize(width: pictureHeight * 1.6, height: pictureHeight)
    private static let menu: CGFloat = 4
    /// The bar is drawn far wider than its share of a real screen (54 pt of
    /// some 1,500): at that share it would be a hairline with no face.
    private static let barWidth: CGFloat = 11

    var body: some View {
        let size = Self.size
        let bar = MiniBar(left: left, scale: Self.barWidth / AppController.barWidth)
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [SetupPalette.screenTop, SetupPalette.screenBottom], startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            Rectangle().fill(SetupPalette.menuBar).frame(height: Self.menu)
            bar.offset(x: left ? 0 : size.width - bar.size.width,
                       y: Self.menu + (size.height - Self.menu - bar.size.height) / 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// A close-up of the edge with a window over it, the same in both choices
/// so the bar is the only difference: out over the window, or tucked in
/// with the mascot peeking (what Smart hide shows while something waits;
/// its sliver is too thin to read here). Still: Smart hide's motion is not
/// drawn, a loop in SwiftUI would cost the idle bar's budget.
private struct EdgePicture: View {
    let left: Bool
    let tucked: Bool

    private static let size = CGSize(width: 146, height: pictureHeight)
    private static let scale: CGFloat = 0.3
    /// The bar's head, from the picture's top; its foot runs out of the
    /// picture, as the rest of the screen does.
    private static let barTop: CGFloat = 3

    var body: some View {
        let size = Self.size
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [SetupPalette.screenTop, SetupPalette.screenBottom], startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            window
            if tucked {
                let peek = MiniPeek(left: left, scale: Self.scale)
                let middle = Self.barTop
                    + (AppController.mascotTopInset + AppController.mascotSize / 2) * Self.scale
                peek.offset(x: left ? 0 : size.width - peek.size.width, y: middle - peek.size.height / 2)
            } else {
                let bar = MiniBar(left: left, scale: Self.scale)
                bar.offset(x: left ? 0 : size.width - bar.size.width, y: Self.barTop)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    /// A window reaching past the edge, its lights at its top left whichever
    /// edge it is.
    private var window: some View {
        let size = Self.size
        let width = size.width * 0.72
        let inset: CGFloat = left ? 16 : 0
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SetupPalette.window)
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 11)
            HStack(spacing: 2.6) {
                Circle().fill(SetupPalette.closeLight)
                Circle().fill(SetupPalette.minimizeLight)
                Circle().fill(SetupPalette.zoomLight)
            }
            .frame(width: 16, height: 4)
            .padding(.leading, 6 + inset)
            .padding(.top, 3.5)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([52, 68, 40, 60] as [CGFloat], id: \.self) { length in
                    Capsule().fill(Color.black.opacity(0.12)).frame(width: length, height: 2.6)
                }
            }
            .padding(.leading, 9 + inset)
            .padding(.top, 18)
        }
        .frame(width: width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .offset(x: left ? -6 : size.width - width + 6, y: 9)
    }
}

/// The closed bar with two rows, drawn at its own geometry (`BarShape`, the
/// mascot, the rings) and shrunk by `scale`, so the pictures are the bar and
/// not a drawing of it.
private struct MiniBar: View {
    let left: Bool
    let scale: CGFloat

    private static let full = CGSize(width: AppController.barWidth, height: AppController.barLength(slots: 2))
    var size: CGSize { CGSize(width: Self.full.width * scale, height: Self.full.height * scale) }

    var body: some View {
        let shape = BarShape(corner: AppController.barCorner, flare: AppController.barFlare,
                             edge: left ? .left : .right)
        let ring = AppController.indicatorSize
        return ZStack(alignment: .top) {
            shape.fill(BarPalette.body)
                .overlay(shape.outline.stroke(Color.white.opacity(0.14), lineWidth: 1.5))
            VStack(spacing: AppController.indicatorSpacing) {
                MascotBody(pose: MascotPose.resting(for: .idle), size: AppController.mascotSize)
                    .frame(width: AppController.mascotSize, height: AppController.mascotSize)
                    .padding(.bottom, AppController.indicatorTopGap - AppController.indicatorSpacing)
                // One waiting, one working: the two the bar is for.
                Circle().strokeBorder(SessionIndicator.amber, lineWidth: 2.5)
                    .frame(width: ring, height: ring)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(BarPalette.textPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: ring - 3, height: ring - 3)
                    .frame(width: ring, height: ring)
            }
            .padding(.top, AppController.mascotTopInset)
        }
        .frame(width: Self.full.width, height: Self.full.height)
        .shadow(color: .black.opacity(0.4), radius: 8, x: left ? 3 : -3)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The peek, shrunk by `scale`, in the glow of a wait. Wider than the real
/// one (`BodyPresence.peekWidth`), which shows half the face: at this size
/// half is only a white square, three quarters is the mascot.
private struct MiniPeek: View {
    let left: Bool
    let scale: CGFloat

    private static let full = CGSize(width: 32, height: BarBody.peekLength)
    var size: CGSize { CGSize(width: Self.full.width * scale, height: Self.full.height * scale) }

    var body: some View {
        let shape = BarShape(corner: BarBody.peekCorner, flare: BarBody.peekFlare, edge: left ? .left : .right)
        return ZStack {
            shape.fill(BarPalette.body)
                .overlay(shape.outline.stroke(Color.white.opacity(0.18), lineWidth: 1.5))
            MascotBody(pose: MascotPose.resting(for: .idle), size: AppController.mascotSize)
                .frame(width: AppController.mascotSize, height: AppController.mascotSize)
                .offset(x: (left ? -1 : 1) * (Self.full.width / 2 - 12))
                .mask(shape)
        }
        .frame(width: Self.full.width, height: Self.full.height)
        .shadow(color: SessionIndicator.amber.opacity(0.7), radius: 8)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - 4 · Finish

private struct FinishStep: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(text: model.t("setup.flow.finish.title"))
            VStack(spacing: 0) {
                SwitchRow(title: model.t("setup.flow.finish.sound"), on: Binding(get: { model.soundOn },
                                                                                  set: { model.setSound($0) }),
                          play: { model.previewSound() }, playLabel: model.t("setup.flow.finish.sound.play"))
                if let login = model.toggle(.loginItem) {
                    SwitchRow(title: model.t("setup.flow.finish.login"), on: binding(.loginItem, login),
                              enabled: login.enabled)
                }
                SwitchRow(title: model.t("setup.flow.finish.update"),
                          detail: model.t(model.offersUpdater ? "setup.flow.finish.update.detail"
                                                              : "setup.flow.finish.update.detail.parts"),
                          on: $model.autoUpdate)
                if let command = model.toggle(.commandLink) {
                    SwitchRow(title: model.t("setup.flow.finish.command"),
                              detail: model.t("setup.flow.finish.command.detail"),
                              on: binding(.commandLink, command), enabled: command.enabled)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 10)
            StepNote(text: model.t("setup.flow.finish.note"))
        }
    }

    private func binding(_ item: SetupItem, _ state: SetupFlowModel.Switch) -> Binding<Bool> {
        Binding(get: { state.on }, set: { model.setSwitch(item, $0) })
    }
}

/// A last-step row: its words, a ▶ where there is a sound to hear, a switch;
/// a hairline between rows.
private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var on: Bool
    var enabled = true
    var play: (() -> Void)?
    var playLabel = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SetupPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The words take the room the controls leave, not a share of it.
            .frame(maxWidth: .infinity, alignment: .leading)
            if let play {
                Button(action: play) {
                    // The symbol carries its own optical centring; a nudge on
                    // top of it set the triangle a point right of the ring's middle.
                    Image(systemName: "play.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(SetupPalette.text)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(SetupPalette.playLine))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(playLabel))
            }
            Toggle(title, isOn: $on)
                .toggleStyle(SetupSwitchStyle())
                .labelsHidden()
                .disabled(!enabled)
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(SetupPalette.rule).frame(height: 1) }
    }
}

/// `.sw`: 30 × 18, the knob slides once when it is pressed.
private struct SetupSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? SetupPalette.text : SetupPalette.switchOff)
                .frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? SetupPalette.ink : SetupPalette.muted)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.16), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(configuration.isOn ? "1" : "0"))
    }
}

// MARK: - Ring

/// The bar's ring for an agent, larger: its outline and the agent's mark.
/// `turning` is the bar's working ring (a layer Core Animation turns: the
/// one continuous motion the setup has, in the tree only on the second
/// step with an agent not yet heard); `heard` is the ring with a ✓.
private struct SetupRing: View {
    enum Look { case idle, on, turning, heard }
    let source: AgentID
    let look: Look
    let size: CGFloat
    var still = false

    private let line: CGFloat = 2

    var body: some View {
        ZStack {
            ring
            mark
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var ring: some View {
        switch look {
        case .idle:
            Circle().stroke(SetupPalette.idleRing, lineWidth: line)
        case .on:
            Circle().stroke(SetupPalette.text, lineWidth: line)
        case .turning:
            Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
            if still {
                Circle().trim(from: 0, to: SpinningArc.length)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
            } else {
                SpinningArc(lineWidth: line)
            }
        case .heard:
            Circle().stroke(SetupPalette.green.opacity(0.8), lineWidth: line)
        }
    }

    @ViewBuilder private var mark: some View {
        switch look {
        case .heard:
            CheckMark()
                .stroke(SetupPalette.green, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        case .idle:
            SourceGlyph(source: source)
                .fill(SetupPalette.idleRing, style: FillStyle(eoFill: true))
                .frame(width: size * 0.56, height: size * 0.56)
        case .on, .turning:
            SourceGlyph(source: source)
                .fill(SetupPalette.text, style: FillStyle(eoFill: true))
                .frame(width: size * 0.56, height: size * 0.56)
        }
    }
}

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 26
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 9 * k, y: rect.minY + 13.3 * k))
        path.addLine(to: CGPoint(x: rect.minX + 11.7 * k, y: rect.minY + 16 * k))
        path.addLine(to: CGPoint(x: rect.minX + 17 * k, y: rect.minY + 10.4 * k))
        return path
    }
}

// MARK: - Footer

/// The footer: always there, whatever the step's length. The primary button
/// is the same size and in the same place on every step, and Return presses
/// it.
struct SetupFooter: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 10) {
            if model.showsBack {
                Button(model.t("setup.flow.back")) { model.back() }
                    .buttonStyle(GhostButtonStyle())
                    .padding(.leading, -6)
            }
            SetupProgress(model: model)
            Spacer(minLength: 0)
            if model.showsSkip {
                Button(model.t("setup.flow.skip")) { model.skip() }
                    .buttonStyle(GhostButtonStyle())
            }
            Button { model.primary() } label: { SetupPrimaryLabel(text: model.t(model.primaryKey)) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, SetupLayout.side)
        .padding(.trailing, 20)
        .padding(.bottom, 4)
    }
}

/// The primary button's words and the Return mark.
struct SetupPrimaryLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1)
            Text("↩")
                .font(.system(size: 11))
                .opacity(0.55)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

/// Four short lines: the ones passed, the one it is on, the ones to come.
private struct SetupProgress: View {
    @ObservedObject var model: SetupFlowModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SetupFlowModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == model.step ? SetupPalette.text : step < model.step ? SetupPalette.dotPast : SetupPalette.dot)
                    .frame(width: step == model.step ? 22 : 14, height: 3)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.t("setup.flow.progress", ["number": String(model.step.index + 1),
                                                                 "count": String(SetupFlowModel.Step.allCases.count)])))
    }
}

// MARK: - Buttons

/// `.btn.pri`: the step's one light button.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(SetupPalette.ink)
            .frame(width: SetupLayout.primary.width, height: SetupLayout.primary.height)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SetupPalette.text.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

/// `.btn.ghost`: "‹ Back" and "Not now".
private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(SetupPalette.muted.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
