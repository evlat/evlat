import SwiftUI
import EvlatCore

/// A reply drawn from its markdown (`011/phase-3`, after the gate): the
/// blocks from `MarkdownBlock`, each block's text through the inline reader.
/// Headings a step up from the body, lists with their markers hung, code on
/// a darker ground with `[Copy]`, tables scrolling sideways in the narrow
/// balloon. Each block's text is selectable.
///
/// Equatable on its text: a reply further up is not read again while the
/// last one streams.
struct ReplyView: View, Equatable {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlock.parse(text))
    }
}

/// What a code block's `[Copy]` and a link do: the balloon's model decides,
/// so no view reaches the pasteboard or the browser on its own.
struct ReplyActions {
    var copy: (String) -> Void = { _ in }
}

private struct ReplyActionsKey: EnvironmentKey {
    static let defaultValue = ReplyActions()
}

extension EnvironmentValues {
    var replyActions: ReplyActions {
        get { self[ReplyActionsKey.self] }
        set { self[ReplyActionsKey.self] = newValue }
    }
}

/// The body's type, and the steps above it for headings.
enum ReplyType {
    static let body: CGFloat = 12.5
    static let code: CGFloat = 11.5

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 15, weight: .semibold)
        case 2: return .system(size: 13.5, weight: .semibold)
        default: return .system(size: body, weight: .semibold)
        }
    }
}

/// Blocks one under another. `muted` is a quote's quieter ink.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var depth = 0
    var muted = false
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, depth: depth, muted: muted)
                    // A heading keeps a little air from what is above it.
                    .padding(.top, index > 0 && Self.isHeading(block) ? 4 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func isHeading(_ block: MarkdownBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int
    let muted: Bool

    private var ink: Color { muted ? ChatPalette.placeholder : ChatPalette.reply }

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .font(.system(size: ReplyType.body))
                .lineSpacing(2)
                .foregroundStyle(ink)
                .tint(ChatPalette.link)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(ReplyType.heading(level))
                .foregroundStyle(muted ? ChatPalette.placeholder : ChatPalette.text)
                .tint(ChatPalette.link)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            ListBlock(ordered: ordered, start: start, items: items, depth: depth, muted: muted)
        case .code(let language, let text, _):
            CodeBlock(language: language, code: text)
        case .quote(let blocks):
            AnyView(MarkdownBlocksView(blocks: blocks, depth: depth, muted: true, spacing: 6))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(ChatPalette.quoteBar)
                        .frame(width: 2)
                }
        case .rule:
            Rectangle()
                .fill(ChatPalette.edge)
                .frame(height: 1)
                .padding(.vertical, 3)
        case .table(let header, let alignments, let rows):
            TableBlock(header: header, alignments: alignments, rows: rows)
        }
    }
}

/// A list: markers hung in a narrow column, each item's blocks beside its
/// marker; bullets change shape with depth.
private struct ListBlock: View {
    let ordered: Bool
    let start: Int
    let items: [[MarkdownBlock]]
    let depth: Int
    let muted: Bool

    private static let bullets = ["•", "◦", "▪︎"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(start + index)." : Self.bullets[depth % Self.bullets.count])
                        .font(.system(size: ReplyType.body).monospacedDigit())
                        .foregroundStyle(ChatPalette.faint)
                        .frame(minWidth: ordered ? 16 : 9, alignment: ordered ? .trailing : .center)
                    AnyView(MarkdownBlocksView(blocks: blocks, depth: depth + 1, muted: muted, spacing: 4))
                }
            }
        }
    }
}

/// A fenced block: its language and `[Copy]` over the code, the code on a
/// darker ground, scrolling sideways rather than wrapping.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @Environment(\.replyActions) private var actions
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language ?? "")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatPalette.faint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                copyButton
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.top, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(.system(size: ReplyType.code, design: .monospaced))
                    .lineSpacing(1.5)
                    .foregroundStyle(ChatPalette.codeText)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 9)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatPalette.codeGround))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ChatPalette.codeEdge, lineWidth: 1))
    }

    private var copyButton: some View {
        Button {
            actions.copy(code)
            copied = true
            // `copied` is `@State`: read live when this fires, not the copy
            // of the view it was scheduled from (AGENTS.md → Tuzaklar).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(L10n.t(copied ? "chat.code.copied" : "chat.code.copy"))
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(copied ? ChatPalette.done : hovered ? ChatPalette.chipText : ChatPalette.faint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? ChatPalette.chipHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

/// A table: header on a slightly lighter band, a hairline under each row,
/// columns aligned as the delimiter row says. Wider than the balloon, it
/// scrolls sideways.
private struct TableBlock: View {
    let header: [String]
    let alignments: [MarkdownBlock.Alignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column, bold: true)
                            // Each header cell fills its column, so the band
                            // runs unbroken under columns of any width.
                            .background(ChatPalette.tableHeader)
                            .gridColumnAlignment(Self.alignment(alignments[column]))
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Rectangle().fill(ChatPalette.codeEdge).frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column, bold: false)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatPalette.codeGround))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ChatPalette.codeEdge, lineWidth: 1))
            .padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String, column: Int, bold: Bool) -> some View {
        Text(MarkdownInline.attributed(text))
            .font(.system(size: 11.5, weight: bold ? .semibold : .regular))
            .foregroundStyle(bold ? ChatPalette.text : ChatPalette.reply)
            .tint(ChatPalette.link)
            .textSelection(.enabled)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: Self.alignment(alignments[column]),
                                                              vertical: .center))
    }

    private static func alignment(_ alignment: MarkdownBlock.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// The inside of a line: emphasis, code spans, links, escapes — read by
/// Foundation, whitespace kept. Raw HTML comes back as text and stays so.
enum MarkdownInline {
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible)

    static func attributed(_ text: String) -> AttributedString {
        guard var string = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                string[run.range].font = .system(size: ReplyType.code, design: .monospaced)
                string[run.range].foregroundColor = ChatPalette.inlineCode
                string[run.range].backgroundColor = ChatPalette.inlineCodeGround
            }
            if intent.contains(.strikethrough) {
                string[run.range].strikethroughStyle = .single
            }
        }
        return string
    }
}
