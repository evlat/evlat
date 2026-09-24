import SwiftUI
import EvlatCore

/// The balloon's colours: dark like the bar, a step lighter so it reads as
/// something the bar said rather than more bar.
enum ChatPalette {
    static let ground = Color(.sRGB, red: 18 / 255, green: 19 / 255, blue: 20 / 255)
    static let edge = Color(.sRGB, red: 42 / 255, green: 43 / 255, blue: 46 / 255)
    static let field = Color(.sRGB, red: 28 / 255, green: 29 / 255, blue: 32 / 255)
    static let fieldEdge = Color(.sRGB, red: 52 / 255, green: 54 / 255, blue: 58 / 255)
    static let fieldEdgeFocused = Color(.sRGB, red: 78 / 255, green: 81 / 255, blue: 87 / 255)
    static let chipEdge = Color(.sRGB, red: 48 / 255, green: 50 / 255, blue: 54 / 255)
    static let chipHover = Color(.sRGB, red: 32 / 255, green: 33 / 255, blue: 36 / 255)
    static let mine = Color(.sRGB, red: 38 / 255, green: 40 / 255, blue: 44 / 255)
    static let text = Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 242 / 255)
    static let reply = Color(.sRGB, red: 230 / 255, green: 230 / 255, blue: 230 / 255)
    static let chipText = Color(.sRGB, red: 201 / 255, green: 203 / 255, blue: 208 / 255)
    static let placeholder = Color(.sRGB, red: 138 / 255, green: 141 / 255, blue: 147 / 255)
    static let faint = Color(.sRGB, red: 109 / 255, green: 112 / 255, blue: 118 / 255)
    static let failure = Color(.sRGB, red: 240 / 255, green: 113 / 255, blue: 103 / 255)
    static let done = Color(.sRGB, red: 120 / 255, green: 190 / 255, blue: 140 / 255)
    static let button = Color(.sRGB, red: 58 / 255, green: 60 / 255, blue: 64 / 255)
    static let buttonText = Color(.sRGB, red: 221 / 255, green: 221 / 255, blue: 221 / 255)

    // The permission card: the bar's own "waiting" amber (`#f5a524`), on a
    // ground dark enough that the amber reads as the one loud thing.
    static let amber = Color(.sRGB, red: 245 / 255, green: 165 / 255, blue: 36 / 255)
    static let amberInk = Color(.sRGB, red: 27 / 255, green: 20 / 255, blue: 6 / 255)
    static let cardGround = Color(.sRGB, red: 33 / 255, green: 26 / 255, blue: 12 / 255)
    static let cardEdge = Color(.sRGB, red: 107 / 255, green: 79 / 255, blue: 22 / 255)
    static let cardTitle = Color(.sRGB, red: 245 / 255, green: 196 / 255, blue: 105 / 255)
    static let cardText = Color(.sRGB, red: 217 / 255, green: 201 / 255, blue: 166 / 255)
    static let cardCode = Color(.sRGB, red: 243 / 255, green: 227 / 255, blue: 192 / 255)
}

/// The balloon (`011`, Karar 7): out of the mascot, its tail on the bar.
/// First a single line, three suggestions and a hint; once something is
/// sent, the exchange above the line: short messages, the reply as it
/// streams, a tool call as one dim line that opens on a click, a permission
/// request as an amber card with its buttons, and a stop button in the line
/// while a turn runs (`phase-3`).
struct ChatView: View {
    @ObservedObject var model: ChatModel
    @FocusState private var focused: Bool

    private var isLeft: Bool { model.edge.isLeft }
    /// The window's corner the balloon hangs from: the bar's side, the top.
    private var head: Alignment { isLeft ? .topLeading : .topTrailing }

    /// How tall the exchange grows before it scrolls.
    static let transcriptMaxHeight: CGFloat = 260

    var body: some View {
        balloon
            .padding(.top, ChatPanel.outerMargin)
            .padding(isLeft ? .leading : .trailing, ChatPanel.barSideMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: head)
            .environment(\.colorScheme, .dark)
    }

    private var balloon: some View {
        let shape = BalloonShape(tailOnLeft: isLeft, tailCenter: ChatPanel.tailCenter,
                                 tailDepth: ChatPanel.tailDepth)
        return VStack(alignment: .leading, spacing: 10) {
            if model.claudeMissing {
                missing
            } else {
                if !model.messages.isEmpty { transcript }
                if let failure = model.failure { failureLine(failure) }
                field
                if model.messages.isEmpty { suggestions }
                hint
            }
        }
        .padding(12)
        // The tail's room, on the bar's side.
        .padding(isLeft ? .leading : .trailing, ChatPanel.tailDepth)
        .frame(width: ChatPanel.balloonWidth + ChatPanel.tailDepth, alignment: .leading)
        .frame(maxHeight: ChatPanel.maxBalloonHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(ChatPalette.ground))
        .overlay(shape.stroke(ChatPalette.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    // MARK: - Parts

    /// No `claude`: what did not happen and what to do, in one sentence.
    private var missing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(ChatPalette.placeholder)
            Text(L10n.t("chat.missing"))
                .foregroundStyle(ChatPalette.reply)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 2)
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.draft,
                      prompt: Text(L10n.t("chat.placeholder")).foregroundColor(ChatPalette.placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ChatPalette.text)
                .focused($focused)
                // Not disabled while a turn runs: a disabled field drops its
                // focus and nothing would give it back until the balloon
                // reopened. `submit` refuses a second turn instead.
                .onSubmit { model.submit(model.draft) }
            if model.isRunning {
                StopButton { model.stop() }
            } else {
                Text("↩")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatPalette.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ChatPalette.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(focused ? ChatPalette.fieldEdgeFocused : ChatPalette.fieldEdge, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { focused = true }
        .onChange(of: model.openings) { focused = true }
    }

    private var suggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(ChatModel.suggestionKeys, id: \.self) { key in
                SuggestionChip(title: L10n.t(key)) { model.submit(L10n.t(key)) }
            }
        }
    }

    private var hint: some View {
        Text(L10n.t("chat.hint"))
            .font(.system(size: 11))
            .foregroundStyle(ChatPalette.faint)
    }

    private func failureLine(_ failure: ChatSession.Failure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.t(ChatModel.failureKey(failure)))
                .foregroundStyle(ChatPalette.failure)
            if let detail = ChatModel.failureDetail(failure), !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(ChatPalette.faint)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 11.5))
    }

    /// The exchange: the user's lines on the right, the reply as text, a tool
    /// call as one dim line. It follows its end as a reply streams in.
    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { index, message in
                        MessageLine(message: message, answer: model.answer).id(index)
                    }
                    if model.isRunning, !Self.isReplying(model.messages), !Self.isAsking(model.messages) {
                        Text(L10n.t("chat.working"))
                            .font(.system(size: 12))
                            .foregroundStyle(ChatPalette.faint)
                            .id(Self.workingID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.transcriptMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.messages) {
                reader.scrollTo(model.isRunning && !Self.isReplying(model.messages) && !Self.isAsking(model.messages)
                                ? AnyHashable(Self.workingID) : AnyHashable(model.messages.count - 1),
                                anchor: .bottom)
            }
        }
    }

    private static let workingID = "working"

    private static func isReplying(_ messages: [ChatSession.Message]) -> Bool {
        if case .reply? = messages.last { return true }
        return false
    }

    /// An open card says what is happening; "Working…" under it would not.
    private static func isAsking(_ messages: [ChatSession.Message]) -> Bool {
        messages.contains { if case .permission(let card) = $0 { return card.isOpen } else { return false } }
    }
}

/// One line of the exchange.
private struct MessageLine: View {
    let message: ChatSession.Message
    let answer: (String, Action.Decision) -> Void

    var body: some View {
        switch message {
        case .user(let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChatPalette.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 10,
                                                       style: .continuous)
                        .fill(ChatPalette.mine))
                    .textSelection(.enabled)
            }
        case .reply(let text):
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(ChatPalette.reply)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool(_, let name, let subject, let failed, let output):
            ToolLine(name: name, subject: subject, failed: failed, output: output)
        case .permission(let card):
            if card.isOpen {
                PermissionCardView(card: card, answer: answer)
            } else {
                AnsweredLine(card: card)
            }
        }
    }
}

/// A tool call: one dim line; a click opens it to the whole subject and
/// how it ended.
private struct ToolLine: View {
    let name: String
    let subject: String?
    let failed: Bool?
    let output: String?
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Text("▸")
                        .foregroundStyle(ChatPalette.faint.opacity(0.7))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(name).foregroundStyle(failed == true ? ChatPalette.failure
                                               : hovered ? ChatPalette.chipText : ChatPalette.placeholder)
                    if let subject, !open {
                        Text(subject).foregroundStyle(ChatPalette.faint).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    if let subject {
                        Text(subject)
                            .foregroundStyle(ChatPalette.chipText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L10n.t(failed == nil ? "chat.tool.running"
                                    : failed == true ? "chat.tool.failed" : "chat.tool.done"))
                            .foregroundStyle(failed == true ? ChatPalette.failure
                                             : failed == false ? ChatPalette.done : ChatPalette.faint)
                        if let output {
                            Text(output).foregroundStyle(ChatPalette.faint).lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .animation(.easeOut(duration: 0.12), value: open)
    }
}

/// A permission request waiting for the user (reference screen 4): what
/// it is, what it will do in one line, and the buttons. The third button
/// is there only when there is something to keep: a folder to reach
/// ("Give access") or a rule for this chat ("Always in this folder").
private struct PermissionCardView: View {
    let card: ChatSession.PermissionCard
    let answer: (String, Action.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.t("chat.permission.title"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(ChatPalette.cardTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("chat.permission.tool", ["tool": card.tool]))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChatPalette.cardText)
                if let subject = card.subject {
                    Text(subject)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ChatPalette.cardCode)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Every folder and rule the third button would keep for the
                // chat's later turns is on the card: a grant is not made
                // from lines the user never saw.
                ForEach(card.directories, id: \.self) { folder in
                    Text(L10n.t("chat.permission.folder", ["folder": (folder as NSString).abbreviatingWithTildeInPath]))
                        .font(.system(size: 11))
                        .foregroundStyle(ChatPalette.cardText.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !card.rules.isEmpty {
                    Text(card.rules.map(\.text).joined(separator: "  "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ChatPalette.cardText.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowLayout(spacing: 6) {
                CardButton(title: L10n.t("chat.permission.allow"), primary: true) { answer(card.id, .allow) }
                CardButton(title: L10n.t("chat.permission.deny")) { answer(card.id, .deny) }
                if card.offersAlways {
                    CardButton(title: L10n.t(card.directories.isEmpty ? "chat.permission.always"
                                             : "chat.permission.access")) { answer(card.id, .allowAlways) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ChatPalette.cardGround))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatPalette.cardEdge, lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }
}

/// An answered card, folded to one quiet line: what was asked, what came of it.
private struct AnsweredLine: View {
    let card: ChatSession.PermissionCard

    var body: some View {
        let allowed = card.outcome == .allowed || card.outcome == .allowedAlways
        HStack(spacing: 6) {
            Image(systemName: allowed ? "checkmark.shield" : "xmark.shield")
                .foregroundStyle(allowed ? ChatPalette.amber.opacity(0.8) : ChatPalette.faint)
            Text(card.outcome.map { L10n.t(ChatModel.outcomeKey($0)) } ?? "")
                .foregroundStyle(allowed ? ChatPalette.placeholder : ChatPalette.faint)
            Text(card.tool).foregroundStyle(ChatPalette.faint)
            if let subject = card.subject {
                Text(subject).foregroundStyle(ChatPalette.faint.opacity(0.8)).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }
}

/// A card's button: amber and filled when it is the one to press, quiet
/// otherwise; both answer the pointer.
private struct CardButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? ChatPalette.amberInk : ChatPalette.buttonText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(primary ? ChatPalette.amber.opacity(hovered ? 0.88 : 1)
                          : hovered ? ChatPalette.chipHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(primary ? ChatPalette.amber : ChatPalette.button, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// Ends the running turn: a small square in the line's corner.
private struct StopButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(hovered ? ChatPalette.text : ChatPalette.chipText)
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovered ? ChatPalette.button : ChatPalette.chipHover))
                .overlay(Circle().stroke(ChatPalette.chipEdge, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("chat.stop"))
        .accessibilityLabel(L10n.t("chat.stop"))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// A suggestion: a quiet pill that says what it will send.
private struct SuggestionChip: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(hovered ? ChatPalette.text : ChatPalette.chipText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(hovered ? ChatPalette.chipHover : .clear))
                .overlay(Capsule().stroke(ChatPalette.chipEdge, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// The balloon with its tail: a rounded rectangle and, on the bar's side, a
/// small point toward the mascot — one path, so the edge runs around both.
struct BalloonShape: Shape {
    var tailOnLeft: Bool
    /// The tail's middle, down from the top.
    var tailCenter: CGFloat
    var tailDepth: CGFloat
    var corner: CGFloat = 16
    var tailHalf: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var body = rect
        body.size.width -= tailDepth
        if tailOnLeft { body.origin.x += tailDepth }
        var path = Path(roundedRect: body, cornerRadius: corner, style: .continuous)
        let y = min(max(tailCenter, corner + tailHalf), body.maxY - corner - tailHalf)
        let base = tailOnLeft ? body.minX : body.maxX
        let tip = tailOnLeft ? rect.minX : rect.maxX
        // Its base a hair inside the body, so the fill joins without a seam.
        let inset: CGFloat = tailOnLeft ? 1 : -1
        var tail = Path()
        tail.move(to: CGPoint(x: base + inset, y: y - tailHalf))
        tail.addQuadCurve(to: CGPoint(x: tip, y: y), control: CGPoint(x: base + (tip - base) * 0.55, y: y - 2))
        tail.addQuadCurve(to: CGPoint(x: base + inset, y: y + tailHalf),
                          control: CGPoint(x: base + (tip - base) * 0.55, y: y + 2))
        tail.closeSubpath()
        path = path.union(tail)
        return path
    }
}

/// Lays its children out in rows, wrapping when the next does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
