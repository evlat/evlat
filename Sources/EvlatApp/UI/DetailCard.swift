import SwiftUI
import EvlatCore
import EvlatAgents

/// The detail card beside the open list: what one session is doing.
///
/// Two blocks, told apart by space. On top, who: the tool's mark and name in
/// small capitals, the session's name (data, `verbatim`), and where it runs
/// under it — its branch on this Mac, its machine elsewhere, its sandbox, a
/// chat's folder, an outside job's sender. Below, how and what: the status in
/// its phase's colour with the time in the phase and the turn's tools, then
/// a section edge to edge — the tool and its subject on a grey ground, or a
/// held request on an amber one with its answers — or the last reply as
/// plain text. Last, the way back to the session, the card's one action:
/// "Open in Bateri", faint with the reason when there is nowhere to go.
///
/// A remote session's card has its button only once its terminal is found
/// here; a dimmed one is faded and says why on its status row.
///
/// An outside job's card is read, not pressed: its sender under its name,
/// its own line and its progress. No mark, no terminal, no button.
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

    /// The card's own ground and grey, not the bar's: the bar is the bezel's
    /// black, the card a surface beside it. Over pure black a section's 4%
    /// of white and the ask's amber all but vanished (the user's screenshot
    /// beside the mockup). The values are the mockup's.
    static let ground = Color(.sRGB, red: 11 / 255, green: 11 / 255, blue: 13 / 255)
    static let secondary = Color(.sRGB, red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    /// A card of its own, apart from the body (the user's decision): all
    /// four corners round, its own edge line and shadow. The body's shape
    /// does not change while it is up.
    static let corner: CGFloat = 16
    /// The card's edges, all four; a section's ground runs past the sides.
    static let padding: CGFloat = 18
    /// Who, then how: the gap between the two blocks. Inside each the lines
    /// sit close, so the space says which belong together.
    static let blockGap: CGFloat = 18
    /// From the status to what follows it: text, a section, the button.
    static let textGap: CGFloat = 10
    static let sectionGap: CGFloat = 12
    static let actionGap: CGFloat = 18
    /// A section's ground: grey for what the session is doing, amber for
    /// what it asks.
    static let sectionOpacity: Double = 0.04
    static let askOpacity: Double = 0.07
    /// A reply is a paragraph, not a transcript: this many lines, then "…".
    static let replyLines = 4
    /// A long name wraps once rather than giving way to what is beside it.
    static let nameLines = 2
    /// A tool's subject — a command or a path — wraps this far, then is cut
    /// in the middle: a path keeps its file's name, a command its start.
    static let subjectLines = 3

    static let nameFont = Font.system(size: 15, weight: .semibold)
    /// The tool's name above it, in small capitals.
    static let agentFont = Font.system(size: 9, weight: .semibold)
    static let agentKerning: CGFloat = 0.5
    static let stripMark: CGFloat = 10
    /// Where it runs, under the name.
    static let placeFont = Font.system(size: 10)
    static let placeMonoFont = Font.system(size: 10, design: .monospaced)
    /// The status and what follows it on its line.
    static let titleFont = Font.system(size: 12, weight: .semibold)
    static let metaFont = Font(NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular))
    /// A section's title: the tool, or what a held request wants.
    static let sectionTitleFont = Font.system(size: 11, weight: .semibold)
    static let labelFont = Font.system(size: 10, weight: .medium)
    static let subjectFont = Font.system(size: 11, design: .monospaced)
    static let replyFont = Font.system(size: 12)
    static let footerFont = Font(NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular))
    static let buttonFont = Font.system(size: 12, weight: .semibold)
    static let buttonHeight: CGFloat = 32
    /// The way back: the card's one action, a size above its answers.
    static let goFont = Font.system(size: 13, weight: .semibold)
    static let goHeight: CGFloat = 38

    /// Keys this view asks for beyond the status line's. Listed so a test
    /// reaches every one of them.
    static let toolsOneKey = "card.tools.one"
    static let toolsKey = "card.tools"
    static let goKey = "card.go"
    /// The way back named by where it goes: "Open in Bateri".
    static let openKey = "card.open"
    /// The session is in herdr but its pane cannot be selected: the click
    /// brings herdr's window, on whatever pane it shows (`HerdrLookup`).
    static let openHerdrKey = "card.openHerdr"
    static let closedKey = "card.closed"
    static let notFoundKey = "card.notFound"
    /// A sandbox's session with no `sbx` client in a terminal (`Sandbox`).
    static let noTerminalKey = "card.noTerminal"
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
    /// A question (`AskQuestion`): "Other…" and its line, what was written
    /// there, how many may be picked, and the way on.
    static let otherKey = "card.question.other"
    static let otherHintKey = "card.question.otherHint"
    static let writtenKey = "card.question.written"
    static let writtenHintKey = "card.question.writtenHint"
    static let pickOneKey = "card.question.pickOne"
    static let pickAnyKey = "card.question.pickAny"
    static let nextKey = "card.question.next"
    static let sendKey = "card.question.send"
    /// A question's text and an option's description, in lines.
    static let questionLines = 3
    static let descriptionLines = 2
    /// The options and "Other…" before their list scrolls: three options
    /// with two lines of description each stay whole; four long ones
    /// scroll (`QuestionCardTests` measures both).
    static let optionsMaxHeight: CGFloat = 250
    /// The agent's name (`AgentDisplay.nameKey`).
    static func sourceKey(_ source: AgentID) -> String {
        Agents.all[id: source]?.display.nameKey ?? source.rawValue
    }
    static var keys: [String] {
        [toolsOneKey, toolsKey, goKey, openKey, openHerdrKey, closedKey, notFoundKey, noTerminalKey, taskKey,
         returnKey, outsideKey, progressKey, approvalToolKey, approvalSubagentKey, allowKey, denyKey,
         otherKey, otherHintKey, writtenKey, writtenHintKey, pickOneKey, pickAnyKey, nextKey, sendKey]
            + Agents.all.map(\.display.nameKey)
    }

    /// The progress bar's height: a line, not a control.
    static let progressBarHeight: CGFloat = 4
    static let noteLines = 2

    var body: some View {
        if let detail = model.detail {
            let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            content(detail)
                .padding(.top, Self.padding)
                // A section last runs to the card's foot, as the mockup draws it.
                .padding(.bottom, Self.endsInSection(detail) ? 0 : Self.padding)
                .frame(width: AppController.detailCardWidth, alignment: .leading)
                // As tall as what it holds, never past the height the window
                // is sized for. A max-only frame grows to its max when offered
                // more, so the fixed size outside it asks for the ideal.
                .frame(maxHeight: maxHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(Self.ground)
                // A section's ground runs to the card's edges.
                .clipShape(shape)
                // The body's hairline, so the card reads against a dark wall too.
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        }
    }

    @ViewBuilder
    private func content(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            identity(detail)
                .padding(.horizontal, Self.padding)
            statusRow(detail)
                .padding(.horizontal, Self.padding)
                .padding(.top, Self.blockGap)
            what(detail)
            if let go = Self.go(detail) {
                goButton(go, detail: detail)
                    .padding(.horizontal, Self.padding)
                    .padding(.top, Self.actionGap)
            }
        }
        // The last thing a dimmed machine said, faded like its ring.
        .opacity(detail.dim == nil ? 1 : SessionColumn.dimOpacity + 0.22)
    }

    /// Who: the tool, the name, where it runs — close together.
    private func identity(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            agentLine(detail)
            nameText(detail)
                .padding(.top, 8)
            if let place = Self.place(detail) {
                placeLine(place)
                    .padding(.top, 5)
            }
        }
    }

    /// The tool's mark and name, or Evlat's own word for the row, in small
    /// capitals: quiet, above the name it belongs to.
    private func agentLine(_ detail: SessionDetail) -> some View {
        let word = Self.kindWord(detail.traits).map { L10n.t($0) }
            ?? detail.source.map { L10n.t(Self.sourceKey($0)) }
        return HStack(spacing: 5) {
            mark(detail)
            if let word {
                Text(verbatim: UsageBlock.heading(word))
                    .font(Self.agentFont)
                    .kerning(Self.agentKerning)
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func mark(_ detail: SessionDetail) -> some View {
        switch detail.traits.mark {
        case .face:
            MascotFaceMark().frame(width: Self.stripMark, height: Self.stripMark)
        case .tool:
            if let source = detail.source {
                SourceGlyph(source: source)
                    .fill(Self.secondary, style: FillStyle(eoFill: true))
                    .frame(width: Self.stripMark, height: Self.stripMark)
            }
        case .none:
            EmptyView()
        }
    }

    /// The name is data: what the user called the session. It has the
    /// card's width to itself and wraps once.
    private func nameText(_ detail: SessionDetail) -> some View {
        Text(verbatim: detail.label)
            .font(Self.nameFont)
            .foregroundStyle(BarPalette.textPrimary)
            // Display type tightens as it grows.
            .kerning(-0.15)
            .lineLimit(Self.nameLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Where the session runs, one of them: a session on this Mac has only
    /// its branch, a remote one only its machine — its folder is on its
    /// server — a sandbox's its sandbox, a chat its folder, an outside job
    /// its sender. Never two of them at once.
    enum Place: Equatable {
        case branch(String)
        case machine(String)
        case sandbox(String)
        case folder(String)
        case sender(String)
    }

    static func place(_ detail: SessionDetail) -> Place? {
        switch detail.traits.detail {
        case .folder: return detail.folder.map { .folder(folderName($0)) }
        case .note:
            return detail.traits.tag.text(machine: detail.machine, sender: detail.sender, inCard: true)
                .map(Place.sender)
        case .none:
            if detail.hasSandboxHost { return detail.machine.map(Place.sandbox) }
            if let machine = detail.machine { return .machine(machine) }
            return detail.branch.map(Place.branch)
        }
    }

    /// An address or a host is cut at its end — cut in the middle it names
    /// no machine — a branch in its middle, where `feature/PROJ-1234-…`
    /// names differ least.
    private func placeLine(_ place: Place) -> some View {
        let (symbol, text, mono): (String?, String, Bool) = {
            switch place {
            case .branch(let name): return ("arrow.triangle.branch", name, false)
            case .machine(let name): return ("server.rack", name, true)
            case .sandbox(let name): return ("shippingbox", name, false)
            case .folder(let path): return ("folder", path, false)
            case .sender(let name): return (nil, name, false)
            }
        }()
        return HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .medium))
            }
            // Data: the branch, the host, the folder as it is named.
            Text(verbatim: text)
                .font(mono ? Self.placeMonoFont : Self.placeFont)
                .lineLimit(1)
                .truncationMode({ if case .branch = place { return .middle } else { return .tail } }())
        }
        .foregroundStyle(Self.secondary)
    }

    /// How it stands: the status in its phase's colour after a dot, then the
    /// time in the phase and the turn's tools. A dimmed row says why and
    /// since when instead. Once a minute, and only while the card is up.
    private func statusRow(_ detail: SessionDetail) -> some View {
        TimelineView(.everyMinute) { context in
            let line = Self.status(detail, now: context.date)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(line.color).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(verbatim: line.title)
                    .font(Self.titleFont)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let meta = line.meta {
                    Text(verbatim: "· " + meta)
                        .font(Self.metaFont)
                        .foregroundStyle(Self.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    struct StatusText: Equatable {
        let title: String
        let meta: String?
        let color: Color
    }

    /// "Waiting for approval · 16 min · 2 tools"; a dimmed row's
    /// "No connection · 5 min" in grey.
    static func status(_ detail: SessionDetail, now: Date, in lang: String = L10n.language) -> StatusText {
        if let dim = detail.dim {
            let word = L10n.t(StatusLine.dimKey(dim.reason), in: lang)
            return StatusText(title: capitalized(word, in: lang),
                              meta: footer(enteredAt: dim.since, activity: detail.activity, now: now, in: lang),
                              color: Self.secondary)
        }
        return StatusText(title: title(phase: detail.phase, waitKind: detail.activity?.waitKind, in: lang),
                          meta: footer(enteredAt: detail.enteredAt, activity: detail.activity, now: now, in: lang),
                          color: color(detail.phase))
    }

    /// What it is on, under its status: a held request, the tool, the
    /// reply, an outside job's own line and its progress.
    @ViewBuilder
    private func what(_ detail: SessionDetail) -> some View {
        if let approval = detail.approval {
            Group {
                if let question = approval.question {
                    questionSection(question, armed: approval.armed)
                } else {
                    permissionSection(approval)
                }
            }
            .padding(.top, Self.sectionGap)
        } else {
            switch CardBody.pick(detail.activity) {
            case .tool(let tool):
                toolSection(tool).padding(.top, Self.sectionGap)
            case .reply(let reply):
                Text(verbatim: reply)
                    .font(Self.replyFont)
                    .foregroundStyle(BarPalette.textPrimary.opacity(0.82))
                    .lineSpacing(2)
                    .lineLimit(Self.replyLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.padding)
                    .padding(.top, Self.textGap)
            case .none:
                EmptyView()
            }
        }
        if let note = detail.note, !note.isEmpty {
            // The sender's words: data, like a reply.
            Text(verbatim: note)
                .font(Self.replyFont)
                .foregroundStyle(BarPalette.textPrimary.opacity(0.82))
                .lineLimit(Self.noteLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.padding)
                .padding(.top, Self.textGap)
        }
        if let progress = detail.progress {
            progressView(progress, phase: detail.phase)
                .padding(.horizontal, Self.padding)
                .padding(.top, Self.textGap)
        }
    }

    /// A section: a ground edge to edge, its title, what it holds.
    private func section<Content: View>(ask: Bool, gap: CGFloat = 8,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            content()
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ask ? SessionIndicator.amber.opacity(Self.askOpacity)
                        : Color.white.opacity(Self.sectionOpacity))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Self.sectionTitleFont)
            .foregroundStyle(BarPalette.textPrimary.opacity(0.78))
            .lineLimit(1)
    }

    /// The tool and its subject, on grey: what the session is doing.
    private func toolSection(_ tool: Signal.Activity.Tool) -> some View {
        section(ask: false, gap: 6) {
            // A tool's name is data too: the agent's word, not ours.
            sectionTitle(tool.name)
            if let subject = tool.subject, !subject.isEmpty {
                Text(verbatim: subject)
                    .font(Self.subjectFont)
                    .foregroundStyle(BarPalette.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(Self.subjectLines)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What Allow lets run, whole, and Deny and Allow under it, on amber:
    /// the request and its answer in one place. Until the card has stood
    /// still for a moment the buttons take no press, drawn as they will be
    /// (`AppController.click`): a card that comes up under the pointer is
    /// not an answer.
    private func permissionSection(_ approval: SessionDetail.ApprovalCard) -> some View {
        section(ask: true, gap: 10) {
            sectionTitle(L10n.t(approval.fromSubagent ? Self.approvalSubagentKey : Self.approvalToolKey,
                                ["tool": approval.tool]))
            if let text = approval.text {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(verbatim: text)
                        .font(Self.subjectFont)
                        .foregroundStyle(BarPalette.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: Self.approvalTextMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.35)))
            }
            HStack(spacing: 8) {
                approvalButton(L10n.t(Self.denyKey), button: .deny, loud: false, live: approval.armed)
                approvalButton(L10n.t(Self.allowKey), button: .allow, loud: true, live: approval.armed)
            }
            .padding(.top, 2)
        }
    }

    /// One question of the request, on amber: the questions' tabs, the
    /// question, how many may be picked, its options with their
    /// descriptions, "Other…" as the last one, and the way on. A
    /// single-select option answers with its press and moves on; one
    /// answered before, come back to, has Next to keep its answer. On the
    /// last question a press only picks, and Send sends. A multi-select one
    /// is ticked, then Next or Send. No press until armed.
    private func questionSection(_ question: SessionDetail.QuestionCard, armed: Bool) -> some View {
        let options = question.question.options
        let multi = question.question.multiSelect
        return section(ask: true, gap: 10) {
            if question.steps.count > 1 || question.steps.first?.header != nil {
                steps(question)
            }
            VStack(alignment: .leading, spacing: 4) {
                // Claude's words: data.
                Text(verbatim: question.question.text)
                    .font(Self.replyFont.weight(.medium))
                    .foregroundStyle(BarPalette.textPrimary)
                    .lineLimit(Self.questionLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L10n.t(multi ? Self.pickAnyKey : Self.pickOneKey))
                    .font(Self.labelFont)
                    .foregroundStyle(Self.secondary)
            }
            // Whole up to `optionsMaxHeight`, then the list scrolls in its
            // place: the buttons under it never leave the card.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(options.indices, id: \.self) { index in
                        optionRow(options[index], index: index, multi: multi,
                                  picked: question.picked.contains(index), live: armed)
                    }
                    otherRow(written: question.written, multi: multi, live: armed)
                }
            }
            .frame(maxHeight: Self.optionsMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if question.canGoBack {
                    backButton(live: armed)
                }
                approvalButton(L10n.t(Self.denyKey), button: .deny, loud: false, live: armed)
                // On the last question Send is always there, faint until
                // something is picked: a press there picks, Send sends.
                if multi || question.canCommit || question.isLast {
                    approvalButton(L10n.t(question.isLast ? Self.sendKey : Self.nextKey), button: .send,
                                   loud: true, live: armed, enabled: question.canCommit)
                }
            }
            .padding(.top, 2)
        }
    }

    /// The questions' tabs, the one up lit, the answered ones ticked.
    private func steps(_ question: SessionDetail.QuestionCard) -> some View {
        HStack(spacing: 4) {
            ForEach(question.steps.indices, id: \.self) { index in
                let step = question.steps[index]
                let now = index == question.index
                HStack(spacing: 4) {
                    if step.answered && !now {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(SessionIndicator.amber)
                    }
                    // A tab title is Claude's word: data.
                    Text(verbatim: step.header ?? "\(index + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(now ? BarPalette.textPrimary
                                         : step.answered ? Self.secondary
                                         : Self.secondary.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(now ? 0.12 : 0)))
            }
        }
    }

    /// An option: its mark, its label and its description under it. A
    /// round mark picks one, a square one any; amber when picked.
    private func optionRow(_ option: AgentQuestion.Option, index: Int, multi: Bool, picked: Bool,
                           live: Bool) -> some View {
        choiceRow(picked: picked, live: live, button: .option(index)) {
            markView(multi: multi, picked: picked)
        } text: {
            // An option's label and description are Claude's words: data.
            Text(verbatim: option.label)
                .font(Self.replyFont.weight(.medium))
                .foregroundStyle(BarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let description = option.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(Self.labelFont)
                    .foregroundStyle(Self.secondary)
                    .lineLimit(Self.descriptionLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Other…", the last choice: a press opens the line to write in, laid
    /// on this row (`AppController.openAnswer`). Once written, the answer
    /// stands here, marked, and a press opens the line again, filled.
    private func otherRow(written: String?, multi: Bool, live: Bool) -> some View {
        choiceRow(picked: written != nil, live: live, button: .other) {
            if written != nil {
                markView(multi: multi, picked: true)
            } else {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.secondary)
                    .frame(width: 14, height: 14)
            }
        } text: {
            // What was written is the user's own words: data.
            Text(verbatim: written ?? L10n.t(Self.otherKey))
                .font(Self.replyFont.weight(.medium))
                .foregroundStyle(written == nil ? BarPalette.textPrimary.opacity(0.78) : BarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: L10n.t(written == nil ? Self.otherHintKey : Self.writtenHintKey))
                .font(Self.labelFont)
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
        }
    }

    private func choiceRow<Mark: View, Words: View>(picked: Bool, live: Bool, button: DetailModel.Button,
                                                    @ViewBuilder mark: () -> Mark,
                                                    @ViewBuilder text: () -> Words) -> some View {
        HStack(alignment: .top, spacing: 10) {
            mark().padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) { text() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(picked ? SessionIndicator.amber.opacity(0.13) : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(picked ? SessionIndicator.amber.opacity(0.45) : .clear, lineWidth: 1))
        .reportingFrame(button, to: onApprovalFrame)
        .modifier(PressFeedback(model: model, button: live ? button : nil))
    }

    /// A round mark for one, a square one for any; filled amber with a
    /// tick when picked.
    private func markView(multi: Bool, picked: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: multi ? 4 : 7, style: .continuous)
        return ZStack {
            if picked {
                shape.fill(SessionIndicator.amber)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color.black)
            } else {
                shape.strokeBorder(Self.secondary.opacity(0.8), lineWidth: 1.5)
            }
        }
        .frame(width: 14, height: 14)
    }

    /// Back to the question before: a chevron, narrow beside the words.
    private func backButton(live: Bool) -> some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BarPalette.textPrimary)
            .frame(width: Self.buttonHeight, height: Self.buttonHeight)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
            .reportingFrame(.back, to: onApprovalFrame)
            .modifier(PressFeedback(model: model, button: live ? .back : nil))
    }

    /// The way back to the session, the card's one action, last: "Open in
    /// Bateri" and its arrow; a chat's "Back to chat". Faint with its reason
    /// when there is nowhere to go — the app closed, no terminal found. A
    /// sandbox's with no `sbx run` open says so faint and reports no
    /// rectangle: there is nothing a click could look for.
    private func goButton(_ go: GoButton, detail: SessionDetail) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: go.state.title)
                .font(go.state.enabled ? Self.goFont : Self.goFont.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if go.state.enabled {
                Image(systemName: detail.traits.button == .backToChat ? "arrow.uturn.backward" : "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BarPalette.textPrimary.opacity(0.75))
            }
        }
        .foregroundStyle(go.state.enabled ? BarPalette.textPrimary : Self.secondary.opacity(0.75))
        .frame(maxWidth: .infinity)
        .frame(height: Self.goHeight)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(go.state.enabled ? 0.11 : 0.04)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            onButtonFrame(go.reports ? rect : nil)
        }
        .onDisappear { onButtonFrame(nil) }
        .modifier(PressFeedback(model: model, button: go.reports ? .go : nil))
    }

    struct GoButton: Equatable {
        let state: ButtonState
        /// Whether its rectangle takes the click (`showsButton`).
        let reports: Bool
    }

    /// Whether the card's last thing is a section's ground: a held request
    /// or a tool, with no button, note or progress under it.
    static func endsInSection(_ detail: SessionDetail) -> Bool {
        guard go(detail) == nil, detail.note?.isEmpty ?? true, detail.progress == nil else { return false }
        if detail.approval != nil { return true }
        if case .tool = CardBody.pick(detail.activity) { return true }
        return false
    }

    /// The card's way back, or `nil` where there is none to draw.
    static func go(_ detail: SessionDetail, in lang: String = L10n.language) -> GoButton? {
        if showsButton(detail) {
            let state = detail.traits.button == .backToChat
                ? returnButton(in: lang) : button(for: detail.host, in: lang)
            return GoButton(state: state, reports: true)
        }
        if detail.hasSandboxHost, detail.noTerminalOpen {
            return GoButton(state: ButtonState(title: L10n.t(noTerminalKey, in: lang), enabled: false),
                            reports: false)
        }
        return nil
    }

    /// "Color · 1/2": the question's tab title, and where it is among them
    /// when there are more.
    static func questionTag(_ question: SessionDetail.QuestionCard) -> String {
        var parts: [String] = []
        if let header = question.question.header { parts.append(header) }
        if question.count > 1 { parts.append("\(question.index + 1)/\(question.count)") }
        return parts.joined(separator: " · ")
    }

    /// Drawn, like `[Go to session]`: the panel reads the click from the
    /// rectangle. The loud one is the phase's amber (Allow, Send), the rest
    /// quiet; none is a default, and no key presses them.
    ///
    /// Until the card has stood still a moment (`live` false) it takes no
    /// press (`AppController.click`), but it is drawn as it will be: drawn
    /// faint, every card came up looking switched off for half a second
    /// (the user's feedback). Faint is kept for a button that cannot be
    /// pressed at all — Next or Send with nothing picked (`enabled`).
    private func approvalButton(_ title: String, button: DetailModel.Button, loud: Bool, live: Bool,
                                enabled: Bool = true,
                                height: CGFloat = DetailCard.buttonHeight, ticked: Bool = false) -> some View {
        let fill = loud ? Self.color(.waiting) : Color.white.opacity(ticked ? 0.22 : 0.12)
        return Text(verbatim: title)
            .font(Self.buttonFont)
            .foregroundStyle(loud ? Color.black : BarPalette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .opacity(enabled ? 1 : 0.4)
            .reportingFrame(button, to: onApprovalFrame)
            .modifier(PressFeedback(model: model, button: live && enabled ? button : nil))
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
                    .foregroundStyle(Self.secondary)
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

    /// Where a card's way back goes, in words: a chat's folder, a session's
    /// terminal, a sandbox's missing one, or nothing for an outside job.
    static func footerPlace(_ detail: SessionDetail, in lang: String = L10n.language) -> String? {
        switch detail.traits.detail {
        case .folder: return detail.folder.map(folderName)
        case .note: return nil
        case .none:
            if detail.noTerminalOpen { return L10n.t(noTerminalKey, in: lang) }
            return terminal(detail.host)
        }
    }

    /// A session on this Mac always has its button. A remote card has one
    /// only once its terminal is found here (`Ssh`): searching, or not
    /// found, it draws none — not a dimmed "terminal not found" — so its
    /// rectangle is never reported and no click lands on it. A chat has its
    /// way back while the chat is switched on; an outside job has nothing
    /// to press.
    static func showsButton(_ detail: SessionDetail) -> Bool {
        switch detail.traits.button {
        case .goToSession:
            if detail.hasLocalHost { return true }
            // A sandbox's: only once an app is found on this Mac.
            if detail.hasSandboxHost {
                if case .app = detail.host { return true }
                return false
            }
            guard detail.hasRemoteHost, !detail.searching, case .app = detail.host else { return false }
            return true
        case .backToChat: return detail.opensChat
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
        // Named by where it goes: the app is data, not translated. Through
        // herdr with a pane that will not be selected — here, or on a
        // remote session's server — it says so, rather than promise the
        // session (tmux never selects one, and keeps the plain words).
        case .app(let app):
            let selects = (app.herdr?.selectsPane ?? true) && app.serverPane != .unselectable
            let key = selects ? openKey : openHerdrKey
            return ButtonState(title: L10n.t(key, ["app": app.name], in: lang), enabled: true)
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

    /// The header's last word when it is not a tool's name: what Evlat
    /// calls the row itself.
    static func kindWord(_ traits: RowTraits) -> String? {
        switch traits.tag {
        case .evlat: return taskKey
        case .sender: return outsideKey
        case .machine: return nil
        }
    }

    /// The phase's colour: the ring's.
    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .idle: return Self.secondary
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
        capitalized(L10n.t(StatusLine.statusKey(phase: phase, waitKind: waitKind), in: lang), in: lang)
    }

    static func capitalized(_ word: String, in lang: String) -> String {
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
        // None yet says nothing: "0 tools" under a first approval is noise.
        if let count = activity?.toolCount, count > 0 {
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
