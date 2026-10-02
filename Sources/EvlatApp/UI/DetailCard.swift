import SwiftUI
import EvlatCore
import EvlatAgents

/// The detail card beside the open list: what one session is doing.
///
/// The header is the tool's mark, the session's name (data, `verbatim`) and
/// the tool's name (catalogue); under it the status as a title in the phase's
/// colour; then the body `CardBody` picks — a tool and its one-line subject,
/// or the last reply — a footer of time in the phase, tools this turn and the
/// terminal, and `[Go to session]` under it.
///
/// A remote session's card names its machine in the header and has neither
/// the terminal nor the button: its terminal is on another computer, and a
/// dimmed one says why in its footer, as its status line does.
///
/// An outside job's card is read, not pressed: its sender in the header's
/// small caps (sender · machine for one elsewhere), the status title, the
/// sender's own line (what it is on, or how it ended), its progress as a percent over a thin bar, and the
/// time in the phase. No mark, no terminal, no button.
///
/// It observes `DetailModel` alone, and it is in the tree only while a
/// session is selected: so is its minute tick.
struct DetailCard: View {
    @ObservedObject var model: DetailModel
    /// The button's drawn rectangle, `nil` when it goes. The click is read
    /// from geometry by the panel (`AppController.click`), like the hovered row.
    var onButtonFrame: (CGRect?) -> Void = { _ in }
    /// A held request's buttons' drawn rectangles — Allow, Deny, a
    /// question's options and the rest — read the same way; `nil` when one
    /// goes.
    var onApprovalFrame: (DetailModel.Button, CGRect?) -> Void = { _, _ in }
    /// The window's cap; a test lifts it to measure what the card holds.
    var maxHeight = AppController.detailCardMaxHeight

    /// A card of its own, apart from the body (the user's decision): all
    /// four corners round, its own edge line and shadow. The body's shape
    /// does not change while it is up.
    static let corner: CGFloat = 14
    static let padding: CGFloat = 14
    /// A reply is a paragraph, not a transcript: this many lines, then "…".
    /// With the header, title and footer it keeps the card inside
    /// `AppController.detailCardMaxHeight`.
    static let replyLines = 4

    static let nameFont = Font.system(size: 13, weight: .semibold)
    static let sourceFont = Font.system(size: 10, weight: .medium)
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let labelFont = Font.system(size: 10, weight: .medium)
    static let subjectFont = Font.system(size: 11, design: .monospaced)
    static let replyFont = Font.system(size: 11)
    static let footerFont = Font(NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular))
    static let buttonFont = Font.system(size: 12, weight: .semibold)
    static let buttonHeight: CGFloat = 28

    /// Keys this view asks for beyond the status line's. Listed so a test
    /// reaches every one of them.
    static let toolsOneKey = "card.tools.one"
    static let toolsKey = "card.tools"
    static let goKey = "card.go"
    static let closedKey = "card.closed"
    static let notFoundKey = "card.notFound"
    /// Evlat's own chat: its header's kind and its button.
    static let taskKey = "card.task"
    static let returnKey = "card.return"
    /// An outside job: its header's kind and its progress row's name.
    static let outsideKey = "card.outside"
    static let progressKey = "card.progress"
    /// A held permission (`ApprovalHook`).
    static let approvalToolKey = "card.approval.tool"
    static let approvalSubagentKey = "card.approval.subagent"
    static let allowKey = "card.approval.allow"
    static let denyKey = "card.approval.deny"
    /// About six lines of command before the box scrolls: all of what Allow
    /// lets run is on the card, never cut.
    static let approvalTextMaxHeight: CGFloat = 92
    /// A question (`AskQuestion`): "Other…", what was written there, and a
    /// multi-select's way on.
    static let otherKey = "card.question.other"
    static let writtenKey = "card.question.written"
    static let nextKey = "card.question.next"
    static let sendKey = "card.question.send"
    /// A question's lines and options, sized so the tallest — three lines,
    /// four options (the tool's most), two lines of description, the button
    /// row and `[Go to session]`, the way to answer in the terminal — stays
    /// inside `AppController.detailCardMaxHeight` with the header and the
    /// title (`QuestionCardTests` measures it). The footer gives its room.
    /// A card that ran past the cap would be clipped, but its clipped
    /// buttons would still report rectangles.
    static let questionLines = 3
    static let descriptionLines = 2
    static let optionHeight: CGFloat = 22
    static let questionButtonHeight: CGFloat = 26
    /// The agent's name (`AgentDisplay.nameKey`).
    static func sourceKey(_ source: AgentID) -> String {
        Agents.all[id: source]?.display.nameKey ?? source.rawValue
    }
    static var keys: [String] {
        [toolsOneKey, toolsKey, goKey, closedKey, notFoundKey, taskKey, returnKey,
         outsideKey, progressKey, approvalToolKey, approvalSubagentKey, allowKey, denyKey,
         otherKey, writtenKey, nextKey, sendKey]
            + Agents.all.map(\.display.nameKey)
    }

    /// The progress bar's height: a line, not a control.
    static let progressBarHeight: CGFloat = 4
    static let noteLines = 2

    var body: some View {
        if let detail = model.detail {
            content(detail)
                .padding(Self.padding)
                .frame(width: AppController.detailCardWidth, alignment: .leading)
                // As tall as what it holds, never past the height the window
                // is sized for. A max-only frame grows to its max when offered
                // more, so the fixed size outside it asks for the ideal.
                .frame(maxHeight: maxHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .background(background)
        }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return shape
            .fill(BarPalette.body)
            // The body's hairline, so the card reads against a dark wall too.
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private func content(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(detail)
            if let branch = detail.branch {
                // A line of its own under the header, as the first mockup
                // drew it. Beside the name in the header the two fought for
                // one line and the name lost: a 260 pt card cut `shop-api` to
                // "s…" next to `feat/checkout-v2` and "Claude Code".
                branchLine(branch)
            }
            HStack(spacing: 6) {
                Circle().fill(Self.color(detail.phase)).frame(width: 7, height: 7)
                Text(verbatim: Self.title(phase: detail.phase,
                                          waitKind: detail.activity?.waitKind))
                    .font(Self.titleFont)
                    .foregroundStyle(Self.color(detail.phase))
                    .lineLimit(1)
                if let question = detail.approval?.question {
                    Spacer(minLength: 8)
                    Text(verbatim: Self.questionTag(question))
                        .font(Self.footerFont)
                        .foregroundStyle(BarPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            // The last thing a dimmed machine said, faded like its ring.
            .opacity(detail.dim == nil ? 1 : SessionColumn.dimOpacity + 0.2)
            if let approval = detail.approval {
                approvalView(approval)
            } else {
                bodyView(CardBody.pick(detail.activity))
            }
            if let note = detail.note, !note.isEmpty {
                // The sender's words: data, like a reply.
                Text(verbatim: note)
                    .font(Self.replyFont)
                    .foregroundStyle(BarPalette.textPrimary.opacity(0.85))
                    .lineLimit(Self.noteLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = detail.progress {
                progressView(progress, phase: detail.phase)
            }
            // Once a minute, and only while the card is up. A question takes
            // the footer's room (`questionLines`).
            if detail.approval?.question == nil {
            TimelineView(.everyMinute) { context in
                if let footer = Self.footer(enteredAt: detail.enteredAt, activity: detail.activity,
                                            terminal: Self.footerPlace(detail),
                                            dim: detail.dim, now: context.date) {
                    Text(verbatim: footer)
                        .font(Self.footerFont)
                        .foregroundStyle(BarPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            }
            if Self.showsButton(detail) {
                button(detail.traits.button == .backToChat ? Self.returnButton() : Self.button(for: detail.host))
                    .modifier(PressFeedback(model: model, button: .go))
            }
        }
    }

    /// The session's branch: its mark and its name, cut in the middle when
    /// longer than the card, where `feature/PROJ-1234-…` names differ least.
    private func branchLine(_ branch: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .medium))
            Text(verbatim: branch)
                .font(Self.sourceFont)
                .lineLimit(1)
                .truncationMode(.middle)
        }
            .foregroundStyle(BarPalette.textSecondary)
            .padding(.top, -4)
    }

    /// "Color · 1/2": the question's tab title, and where it is among them
    /// when there are more.
    static func questionTag(_ question: SessionDetail.QuestionCard) -> String {
        var parts: [String] = []
        if let header = question.question.header { parts.append(header) }
        if question.count > 1 { parts.append("\(question.index + 1)/\(question.count)") }
        return parts.joined(separator: " · ")
    }

    /// The request whole, then Deny and Allow. Until the card has stood
    /// still for a moment the buttons are drawn faint and take no press
    /// (`AppController.click`): a card that comes up under the pointer is
    /// not an answer.
    @ViewBuilder
    private func approvalView(_ approval: SessionDetail.ApprovalCard) -> some View {
        if let question = approval.question {
            questionView(question, armed: approval.armed)
        } else {
            permissionView(approval)
        }
    }

    private func permissionView(_ approval: SessionDetail.ApprovalCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L10n.t(approval.fromSubagent ? Self.approvalSubagentKey : Self.approvalToolKey,
                                  ["tool": approval.tool]))
                .font(Self.replyFont)
                .foregroundStyle(BarPalette.textPrimary.opacity(0.85))
                .lineLimit(1)
            if let text = approval.text {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(verbatim: text)
                        .font(Self.subjectFont)
                        .foregroundStyle(BarPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: Self.approvalTextMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
            }
            HStack(spacing: 8) {
                approvalButton(L10n.t(Self.denyKey), button: .deny, loud: false, live: approval.armed)
                approvalButton(L10n.t(Self.allowKey), button: .allow, loud: true, live: approval.armed)
            }
            .padding(.top, 2)
        }
    }

    /// The question, its options, the hovered option's description, and
    /// (‹ ·) Deny · Other… (· Next or Send, when several can be picked). A
    /// single-select option answers with its press — marked when the way
    /// back returns to it; a multi-select one is ticked. Faint until armed,
    /// like Allow.
    private func questionView(_ question: SessionDetail.QuestionCard, armed: Bool) -> some View {
        let options = question.question.options
        let multi = question.question.multiSelect
        return VStack(alignment: .leading, spacing: 4) {
            // Claude's words: data.
            Text(verbatim: question.question.text)
                .font(Self.replyFont.weight(.medium))
                .foregroundStyle(BarPalette.textPrimary)
                .lineLimit(Self.questionLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 3) {
                ForEach(options.indices, id: \.self) { index in
                    optionButton(options[index].label, index: index, multi: multi,
                                 picked: question.picked.contains(index), live: armed)
                }
            }
            if options.contains(where: { $0.description != nil }) {
                // The hovered option's, in lines kept for it: the card does
                // not change height under the pointer. A longer one ends in
                // "…"; the terminal has it whole (`[Go to session]`).
                Text(verbatim: hoveredDescription(options) ?? " ")
                    .font(Self.labelFont)
                    .foregroundStyle(BarPalette.textSecondary)
                    .lineLimit(Self.descriptionLines, reservesSpace: true)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if question.canGoBack {
                    backButton(live: armed)
                }
                approvalButton(L10n.t(Self.denyKey), button: .deny, loud: false, live: armed,
                               height: Self.questionButtonHeight)
                approvalButton(question.written.map { L10n.t(Self.writtenKey, ["text": $0]) } ?? L10n.t(Self.otherKey),
                               button: .other, loud: false, live: armed, height: Self.questionButtonHeight,
                               ticked: question.written != nil)
                if multi {
                    approvalButton(L10n.t(question.isLast ? Self.sendKey : Self.nextKey), button: .send, loud: true,
                                   live: armed && question.canCommit, height: Self.questionButtonHeight)
                }
            }
        }
    }

    /// Back to the question before: a chevron, narrow beside the words.
    private func backButton(live: Bool) -> some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BarPalette.textPrimary)
            .frame(width: Self.questionButtonHeight, height: Self.questionButtonHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.14)))
            .opacity(live ? 1 : 0.4)
            .reportingFrame(.back, to: onApprovalFrame)
            .modifier(PressFeedback(model: model, button: live ? .back : nil))
    }

    private func hoveredDescription(_ options: [AgentQuestion.Option]) -> String? {
        guard case .option(let index)? = model.hovered, options.indices.contains(index) else { return nil }
        return options[index].description
    }

    /// An option: its label, whole-width. A multi-select one carries its
    /// tick, amber when picked.
    private func optionButton(_ label: String, index: Int, multi: Bool, picked: Bool, live: Bool) -> some View {
        HStack(spacing: 6) {
            if multi {
                Image(systemName: picked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(picked ? Self.color(.waiting) : BarPalette.textSecondary)
            }
            // An option's label is Claude's word: data.
            Text(verbatim: label)
                .font(Self.replyFont.weight(.medium))
                .foregroundStyle(BarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.optionHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(picked ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(picked ? Self.color(.waiting).opacity(0.6) : .clear, lineWidth: 1))
        .opacity(live ? 1 : 0.4)
        .reportingFrame(.option(index), to: onApprovalFrame)
        .modifier(PressFeedback(model: model, button: live ? .option(index) : nil))
    }

    /// Drawn, like `[Go to session]`: the panel reads the click from the
    /// rectangle. The loud one is the phase's amber (Allow, Send), the rest
    /// quiet; none is a default, and no key presses them. A faint one is
    /// drawn at 0.4 and takes no press (`AppController.click`).
    private func approvalButton(_ title: String, button: DetailModel.Button, loud: Bool, live: Bool,
                                height: CGFloat = DetailCard.buttonHeight, ticked: Bool = false) -> some View {
        let fill = loud ? Self.color(.waiting) : Color.white.opacity(ticked ? 0.22 : 0.14)
        return Text(verbatim: title)
            .font(Self.buttonFont)
            .foregroundStyle(loud ? Color.black : BarPalette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .opacity(live ? 1 : 0.4)
            .reportingFrame(button, to: onApprovalFrame)
            .modifier(PressFeedback(model: model, button: live ? button : nil))
    }

    /// A drawn button answering the pointer: brighter under it, pressed in
    /// on a click. Only a live button does (`nil` is a faint one); only a
    /// change animates, so a still card draws nothing.
    struct PressFeedback: ViewModifier {
        @ObservedObject var model: DetailModel
        let button: DetailModel.Button?

        func body(content: Content) -> some View {
            let hovered = button != nil && model.hovered == button
            let pressed = button != nil && model.pressed == button
            content
                .brightness(pressed ? -0.12 : hovered ? 0.08 : 0)
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.08), value: hovered)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
    }

    /// "Progress        ~40%" over a thin bar in the phase's colour: the
    /// percent is the number to read, the bar lets it be read at a glance.
    private func progressView(_ progress: Int, phase: Phase) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: L10n.t(Self.progressKey))
                    .font(Self.labelFont)
                    .foregroundStyle(BarPalette.textSecondary)
                Spacer(minLength: 8)
                Text(verbatim: Self.progressText(progress))
                    .font(Self.footerFont)
                    .foregroundStyle(BarPalette.textPrimary)
            }
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Self.color(phase == .idle ? .working : phase))
                        .frame(width: box.size.width * CGFloat(progress) / 100)
                }
            }
            .frame(height: Self.progressBarHeight)
        }
    }

    /// The card's percent: the status line's, `~` and all.
    static func progressText(_ value: Int, in lang: String = L10n.language) -> String {
        StatusLine.percent(value, in: lang)
    }

    /// The footer's last word: a chat's folder, a session's terminal, or
    /// nothing for an outside job.
    static func footerPlace(_ detail: SessionDetail) -> String? {
        switch detail.traits.detail {
        case .folder: return detail.folder.map(folderName)
        case .note: return nil
        case .none: return terminal(detail.host)
        }
    }

    /// Drawn, not a SwiftUI `Button`: the panel reads the click from the
    /// reported rectangle. A dimmed button still reports it — a click there
    /// looks again, in case the app has come back.
    private func button(_ state: ButtonState) -> some View {
        Text(verbatim: state.title)
            .font(Self.buttonFont)
            .foregroundStyle(state.enabled ? Color.black : BarPalette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .frame(height: Self.buttonHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(state.enabled ? Color.white : Color.white.opacity(0.08)))
            .padding(.top, 2)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                onButtonFrame(rect)
            }
            .onDisappear { onButtonFrame(nil) }
    }

    /// Only a session on this Mac has a terminal to go to. A remote card
    /// draws no button at all — not a dimmed "terminal not found" — so its
    /// rectangle is never reported and no click lands on it. A chat always
    /// has its way back; an outside job has nothing to press.
    static func showsButton(_ detail: SessionDetail) -> Bool {
        switch detail.traits.button {
        case .goToSession: return detail.hasTerminal
        case .backToChat: return true
        case .none: return false
        }
    }

    /// A chat's button: back to it in the balloon, always there to press —
    /// it has no terminal to be missing.
    static func returnButton(in lang: String = L10n.language) -> ButtonState {
        ButtonState(title: L10n.t(returnKey, in: lang), enabled: true)
    }

    /// A chat's folder as the footer names it: `~/Downloads`; its own
    /// workspace by the balloon's word for it, never its UUID.
    static func folderName(_ folder: String) -> String {
        let parent = (folder as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == "chats",
           UUID(uuidString: (folder as NSString).lastPathComponent) != nil {
            return L10n.t("chat.folder.workspace")
        }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    struct ButtonState: Equatable {
        let title: String
        let enabled: Bool
    }

    /// Only a running app is a place to go. A closed one is named and not
    /// opened: the session went with it.
    static func button(for host: SessionHost, in lang: String = L10n.language) -> ButtonState {
        switch host {
        case .app: return ButtonState(title: L10n.t(goKey, in: lang), enabled: true)
        case .closed(let name):
            return ButtonState(title: L10n.t(closedKey, ["app": name], in: lang), enabled: false)
        case .notFound: return ButtonState(title: L10n.t(notFoundKey, in: lang), enabled: false)
        }
    }

    /// The footer's last word: the app's own name, running or not.
    static func terminal(_ host: SessionHost) -> String? {
        switch host {
        case .app(let app): return app.name
        case .closed(let name): return name
        case .notFound: return nil
        }
    }

    private func header(_ detail: SessionDetail) -> some View {
        HStack(spacing: 7) {
            switch detail.traits.mark {
            case .face:
                MascotFaceMark().frame(width: 13, height: 13)
            case .tool:
                if let source = detail.source {
                    SourceGlyph(source: source)
                        .fill(BarPalette.textPrimary, style: FillStyle(eoFill: true))
                        .frame(width: 14, height: 14)
                }
            case .none:
                EmptyView()
            }
            // The name is data: what the user called the session.
            Text(verbatim: detail.label)
                .font(Self.nameFont)
                .foregroundStyle(BarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let tag = detail.traits.tag.text(machine: detail.machine, sender: detail.sender, inCard: true) {
                // The column's tag — the machine, an outside job's sender,
                // or both for one elsewhere — in the usage heading's type.
                Text(verbatim: UsageBlock.heading(tag))
                    .font(Font(SessionColumn.machineFont))
                    .kerning(SessionColumn.machineKerning)
                    .foregroundStyle(UsageBlock.headerColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if detail.source != nil || detail.traits.tag == .sender {
                    Text(verbatim: "·")
                        .font(Self.sourceFont)
                        .foregroundStyle(UsageBlock.headerColor)
                }
            }
            if let word = Self.kindWord(detail.traits) {
                Text(verbatim: L10n.t(word))
                    .font(Self.sourceFont)
                    .foregroundStyle(BarPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            } else if let source = detail.source {
                Text(verbatim: L10n.t(Self.sourceKey(source)))
                    .font(Self.sourceFont)
                    .foregroundStyle(BarPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The header's last word when it is not a tool's name: what Evlat
    /// calls the row itself.
    static func kindWord(_ traits: RowTraits) -> String? {
        switch traits.tag {
        case .evlat: return taskKey
        case .sender: return outsideKey
        case .machine: return nil
        }
    }

    @ViewBuilder
    private func bodyView(_ body: CardBody) -> some View {
        switch body {
        case .tool(let tool):
            VStack(alignment: .leading, spacing: 4) {
                // A tool's name is data too: the agent's word, not ours.
                Text(verbatim: tool.name)
                    .font(Self.labelFont)
                    .foregroundStyle(BarPalette.textSecondary)
                if let subject = tool.subject, !subject.isEmpty {
                    Text(verbatim: subject)
                        .font(Self.subjectFont)
                        .foregroundStyle(BarPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08)))
                }
            }
        case .reply(let reply):
            Text(verbatim: reply)
                .font(Self.replyFont)
                .foregroundStyle(BarPalette.textPrimary.opacity(0.85))
                .lineLimit(Self.replyLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    /// The phase's colour: the ring's.
    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .idle: return BarPalette.textSecondary
        case .working: return BarPalette.textPrimary
        case .waiting: return SessionIndicator.amber
        case .review: return SessionIndicator.green
        case .failed: return SessionIndicator.red
        }
    }

    /// The status line's word as a title: its first letter raised in the
    /// language's own rules (Turkish has a dotted capital İ).
    static func title(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                      in lang: String = L10n.language) -> String {
        let word = L10n.t(StatusLine.statusKey(phase: phase, waitKind: waitKind), in: lang)
        guard let first = word.first else { return word }
        return String(first).uppercased(with: Locale(identifier: lang)) + word.dropFirst()
    }

    /// "2 min · 12 tools · Metalterm": the time in the phase when it was seen
    /// entered, the turn's tool count when the source counts — `~` when the
    /// count began mid-turn — and the terminal when one was found. `nil` when
    /// none is known. A dimmed row leads with why and for how long instead
    /// of its time in the phase ("no connection · 5 min · 12 tools").
    static func footer(enteredAt: Date?, activity: Signal.Activity?, terminal: String? = nil,
                       dim: Signal.Machine.Dim? = nil,
                       now: Date, in lang: String = L10n.language) -> String? {
        var parts: [String] = []
        if let dim {
            parts.append(StatusLine.text(phase: .idle, waitKind: nil, enteredAt: nil, dim: dim,
                                         now: now, in: lang))
        } else if let enteredAt {
            parts.append(StatusLine.duration(now.timeIntervalSince(enteredAt), in: lang))
        }
        if let count = activity?.toolCount {
            let text = count == 1
                ? L10n.t(toolsOneKey, in: lang)
                : L10n.t(toolsKey, ["count": String(count)], in: lang)
            parts.append((activity?.countIsPartial == true ? "~" : "") + text)
        }
        // The app's name is data, like the session's: not translated.
        if let terminal { parts.append(terminal) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension View {
    /// A drawn button's rectangle, for the click read from geometry; `nil`
    /// when it goes. Each button clears its own: a question with fewer
    /// options than the last must leave no stale option behind.
    func reportingFrame(_ button: DetailModel.Button,
                        to report: @escaping (DetailModel.Button, CGRect?) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report(button, $0) }
            .onDisappear { report(button, nil) }
    }
}
