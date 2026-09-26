import SwiftUI
import EvlatCore

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
    static func sourceKey(_ source: AgentSource) -> String { "source.\(source.rawValue)" }
    static var keys: [String] {
        [toolsOneKey, toolsKey, goKey, closedKey, notFoundKey, taskKey, returnKey,
         outsideKey, progressKey]
            + AgentSource.allCases.map(sourceKey)
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
                .frame(maxHeight: AppController.detailCardMaxHeight, alignment: .top)
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
            HStack(spacing: 6) {
                Circle().fill(Self.color(detail.phase)).frame(width: 7, height: 7)
                Text(verbatim: Self.title(phase: detail.phase,
                                          waitKind: detail.activity?.waitKind))
                    .font(Self.titleFont)
                    .foregroundStyle(Self.color(detail.phase))
                    .lineLimit(1)
            }
            // The last thing a dimmed machine said, faded like its ring.
            .opacity(detail.dim == nil ? 1 : SessionColumn.dimOpacity + 0.2)
            bodyView(CardBody.pick(detail.activity))
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
            // Once a minute, and only while the card is up.
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
            if Self.showsButton(detail) {
                button(detail.traits.button == .backToChat ? Self.returnButton() : Self.button(for: detail.host))
            }
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
