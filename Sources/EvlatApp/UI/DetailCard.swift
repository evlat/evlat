import SwiftUI
import EvlatCore

/// The detail card beside the open list: what one session is doing.
///
/// The header is the tool's mark, the session's name (data, `verbatim`) and
/// the tool's name (catalogue); under it the status as a title in the phase's
/// colour; then the body `CardBody` picks — a tool and its one-line subject,
/// or the last reply — and a footer of time in the phase and tools this turn.
/// `[Go to session]` and the terminal's name come in `phase-5`.
///
/// It observes `DetailModel` alone, and it is in the tree only while a
/// session is selected: so is its minute tick.
struct DetailCard: View {
    @ObservedObject var model: DetailModel

    /// A card of its own, apart from the body (`005`, user's decision): all
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

    /// Keys this view asks for beyond the status line's. Listed so a test
    /// reaches every one of them.
    static let toolsOneKey = "card.tools.one"
    static let toolsKey = "card.tools"
    static func sourceKey(_ source: AgentSource) -> String { "source.\(source.rawValue)" }
    static var keys: [String] {
        [toolsOneKey, toolsKey] + AgentSource.allCases.map(sourceKey)
    }

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
            bodyView(CardBody.pick(detail.activity))
            // Once a minute, and only while the card is up.
            TimelineView(.everyMinute) { context in
                if let footer = Self.footer(enteredAt: detail.enteredAt, activity: detail.activity,
                                            now: context.date) {
                    Text(verbatim: footer)
                        .font(Self.footerFont)
                        .foregroundStyle(BarPalette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func header(_ detail: SessionDetail) -> some View {
        HStack(spacing: 7) {
            if let source = detail.source {
                SourceGlyph(source: source)
                    .fill(BarPalette.textPrimary, style: FillStyle(eoFill: true))
                    .frame(width: 14, height: 14)
            }
            // The name is data: what the user called the session.
            Text(verbatim: detail.label)
                .font(Self.nameFont)
                .foregroundStyle(BarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let source = detail.source {
                Text(verbatim: L10n.t(Self.sourceKey(source)))
                    .font(Self.sourceFont)
                    .foregroundStyle(BarPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
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

    /// "2 min · 12 tools": the time in the phase when it was seen entered,
    /// and the turn's tool count when the source counts — `~` when the count
    /// began mid-turn. `nil` when neither is known.
    static func footer(enteredAt: Date?, activity: Signal.Activity?, now: Date,
                       in lang: String = L10n.language) -> String? {
        var parts: [String] = []
        if let enteredAt {
            parts.append(StatusLine.duration(now.timeIntervalSince(enteredAt), in: lang))
        }
        if let count = activity?.toolCount {
            let text = count == 1
                ? L10n.t(toolsOneKey, in: lang)
                : L10n.t(toolsKey, ["count": String(count)], in: lang)
            parts.append((activity?.countIsPartial == true ? "~" : "") + text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
