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

    // A dropped file's chip (reference screen 3): a quiet tile, its
    // extension in a small tag tinted by kind.
    static let chip = Color(.sRGB, red: 31 / 255, green: 32 / 255, blue: 35 / 255)
    static let chipName = Color(.sRGB, red: 226 / 255, green: 226 / 255, blue: 226 / 255)
    static let tagDocument = Color(.sRGB, red: 45 / 255, green: 58 / 255, blue: 74 / 255)
    static let tagDocumentText = Color(.sRGB, red: 159 / 255, green: 195 / 255, blue: 238 / 255)
    static let tagImage = Color(.sRGB, red: 58 / 255, green: 45 / 255, blue: 74 / 255)
    static let tagImageText = Color(.sRGB, red: 210 / 255, green: 177 / 255, blue: 240 / 255)
    static let tagOther = Color(.sRGB, red: 44 / 255, green: 46 / 255, blue: 50 / 255)
    static let tagOtherText = Color(.sRGB, red: 176 / 255, green: 179 / 255, blue: 184 / 255)
    /// The balloon's edge while a file is over it.
    static let dropEdge = Color(.sRGB, red: 120 / 255, green: 124 / 255, blue: 132 / 255)

    // A reply's markdown (`ReplyView`): code a step darker than the
    // balloon, links a quiet blue, a quote's bar dim.
    static let codeGround = Color(.sRGB, red: 11 / 255, green: 12 / 255, blue: 13 / 255)
    static let codeEdge = Color(.sRGB, red: 37 / 255, green: 39 / 255, blue: 42 / 255)
    static let codeText = Color(.sRGB, red: 214 / 255, green: 218 / 255, blue: 224 / 255)
    static let inlineCode = Color(.sRGB, red: 226 / 255, green: 214 / 255, blue: 190 / 255)
    static let inlineCodeGround = Color(.sRGB, red: 36 / 255, green: 37 / 255, blue: 41 / 255)
    static let tableHeader = Color(.sRGB, red: 24 / 255, green: 25 / 255, blue: 28 / 255)
    static let link = Color(.sRGB, red: 125 / 255, green: 176 / 255, blue: 245 / 255)
    static let quoteBar = Color(.sRGB, red: 70 / 255, green: 73 / 255, blue: 79 / 255)
}

/// The balloon: out of the mascot, its tail on the bar.
/// First a single line, three suggestions and a hint; once something is
/// sent, the exchange above the line: short messages, the reply as it
/// streams, a tool call as one dim line that opens on a click, a permission
/// request as an amber card with its buttons, and a stop button in the line
/// while a turn runs.
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
                if !model.files.isEmpty, !model.isRunning { madeFiles }
                if !model.attachments.isEmpty { chips }
                field
                // Files dropped on a running exchange bring their own
                // suggestions back.
                if model.messages.isEmpty || !model.attachments.isEmpty { suggestions }
                // The history under an empty balloon only: a chat on screen
                // is the one thing talking.
                if !model.hasChat, !model.history.isEmpty { historyList }
                footer
            }
        }
        .padding(12)
        // The tail's room, on the bar's side.
        .padding(isLeft ? .leading : .trailing, ChatPanel.tailDepth)
        .frame(width: ChatPanel.balloonWidth + ChatPanel.tailDepth, alignment: .leading)
        .frame(maxHeight: ChatPanel.maxBalloonHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(ChatPalette.ground))
        .overlay(shape.stroke(model.dropTargeted ? ChatPalette.dropEdge : ChatPalette.edge,
                              lineWidth: model.dropTargeted ? 1.5 : 1))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .animation(.easeOut(duration: 0.12), value: model.dropTargeted)
        .animation(.smooth(duration: 0.2), value: model.attachments)
        .animation(.smooth(duration: 0.2), value: model.history)
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
                      prompt: Text(L10n.t(model.placeholderKey)).foregroundColor(ChatPalette.placeholder))
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
        // On the first opening the view appears while the panel is ordered
        // front and before it is made key; focus asked for then was lost and
        // the first thing typed went nowhere (seen from the balloon). Asked
        // again once `present` has made the panel key.
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.openings) { focused = true }
    }

    private var suggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.suggestions, id: \.self) { key in
                SuggestionChip(title: L10n.t(key)) { model.submit(L10n.t(key)) }
            }
        }
    }

    /// The dropped files, each a chip that can be taken off.
    private var chips: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.attachments, id: \.self) { item in
                FileChip(item: item) { model.remove(item) }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    /// The hint — or, with a chat on screen, `[+ New]` — and in the corner
    /// the folder the chat works in and its permission mode. One line when
    /// all of it fits whole; else the corner goes under the hint, rather than
    /// both being cut (Turkish, seen by eye: "Dosya bırakabilirsin · Esc
    /// kapatır" — "You can drop files · Esc closes" — beside "K…rü · otom…",
    /// "own folder · auto" cut short).
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                footerLead
                // The stack's spacing is the gap; a spacer's own minimum
                // would count twice toward fitting.
                Spacer(minLength: 0)
                footerCorner
            }
            VStack(alignment: .leading, spacing: 6) {
                footerLead
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    footerCorner
                }
            }
        }
    }

    @ViewBuilder private var footerLead: some View {
        if model.hasChat {
            QuietButton(title: L10n.t("chat.new"), systemImage: "plus") { model.newChat() }
        } else {
            Text(L10n.t("chat.hint"))
                .font(.system(size: 11))
                .foregroundStyle(ChatPalette.faint)
                .lineLimit(1)
        }
    }

    private var footerCorner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            FolderLabel(folder: model.folder, locked: model.folderLocked) { model.folderTapped() }
            Text(verbatim: "·")
                .font(.system(size: 11))
                .foregroundStyle(ChatPalette.faint.opacity(0.7))
            ModeLabel(mode: model.mode) { model.modeTapped() }
        }
        // At its own width: beside a spacer the dot was the one part left
        // to give way, and went (seen by eye).
        .fixedSize()
    }

    /// The history: a few quiet rows — what, where, when —
    /// each opening its chat; pin and × on the pointer; "Clear history"
    /// dim under them. Old chats leave by themselves after a week, so the
    /// list never asks to be tidied.
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("chat.history").uppercased(with: Locale(identifier: L10n.language)))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(ChatPalette.faint)
                .padding(.leading, 2)
            ScrollView(.vertical, showsIndicators: false) {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.history) { item in
                            HistoryRow(item: item, now: context.date,
                                       open: { model.open(item.id) },
                                       pin: { model.pin(item.id, !item.pinned) },
                                       remove: { model.removeFromHistory(item.id) })
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(maxHeight: Self.historyMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            if model.canClearHistory {
                HStack {
                    Spacer(minLength: 0)
                    QuietButton(title: L10n.t("chat.history.clear")) { model.clearHistory() }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Four rows before the list scrolls.
    static let historyMaxHeight: CGFloat = 4 * HistoryRow.height

    /// What a workspace chat made: each file with `[Save…]` and
    /// `[Show in Finder]` — the workspace is Evlat's and goes in a week.
    private var madeFiles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.t("chat.files").uppercased(with: Locale(identifier: L10n.language)))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(ChatPalette.faint)
            ForEach(model.files, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(ChatPalette.tagOtherText)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatPalette.chipName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer(minLength: 6)
                    QuietButton(title: L10n.t("chat.file.save")) { model.save(path) }
                    QuietButton(title: L10n.t("chat.file.show")) { model.reveal(path) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ChatPalette.chip))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ChatPalette.chipEdge, lineWidth: 1))
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
                        MessageLine(message: message, folder: model.folder, answer: model.answer,
                                    retry: retry).id(index)
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
            // A reply's links and code blocks go through the model: a link
            // opens in the default browser (http, https, mailto only), and
            // the balloon closes as it would on any click elsewhere.
            .environment(\.openURL, OpenURLAction { url in model.openLink(url) ? .handled : .discarded })
            .environment(\.replyActions, ReplyActions(copy: { model.copy($0) }))
            .onChange(of: model.messages) {
                reader.scrollTo(model.isRunning && !Self.isReplying(model.messages) && !Self.isAsking(model.messages)
                                ? AnyHashable(Self.workingID) : AnyHashable(model.messages.count - 1),
                                anchor: .bottom)
            }
        }
    }

    private static let workingID = "working"

    /// A "not done" line's retry, while one can be offered.
    private var retry: ((ChatSession.NotDone) -> Void)? {
        guard model.canRetry else { return nil }
        let model = model
        return { model.retry($0) }
    }

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
    /// The chat's folder: a dropped folder that is the chat's own is sent
    /// as `./` and shown by its name.
    let folder: String?
    let answer: (String, Action.Decision) -> Void
    /// A "not done" line's retry, when it can be offered now.
    var retry: ((ChatSession.NotDone) -> Void)?

    var body: some View {
        switch message {
        case .user(let text, let attachments):
            VStack(alignment: .trailing, spacing: 4) {
                bubble(text)
                if !attachments.isEmpty {
                    // What went with it, by name: quiet, under the line.
                    Text(attachments.map(name).joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatPalette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply(let text):
            ReplyView(text: text).equatable()
        case .tool(_, let name, let subject, let failed, let output):
            ToolLine(name: name, subject: subject, failed: failed, output: output)
        case .permission(let card):
            if card.isOpen {
                PermissionCardView(card: card, answer: answer)
            } else {
                AnsweredLine(card: card)
            }
        case .notDone(let line):
            NotDoneLine(line: line, retry: line.isAutoModes ? retry : nil)
        }
    }
}

extension MessageLine {
    /// An attachment as the line under a prompt names it.
    func name(_ attachment: String) -> String {
        attachment == "./" ? (folder as NSString?)?.lastPathComponent ?? attachment
            : (attachment as NSString).lastPathComponent
    }

    /// The user's own line, on the right.
    func bubble(_ text: String) -> some View {
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
    }
}

/// A dropped file: its kind's tag or a folder's icon, its name, and × to
/// take it off (reference screen 3).
private struct FileChip: View {
    let item: ChatFolder.Item
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            tag
            Text(item.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatPalette.chipName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovered ? ChatPalette.chipText : ChatPalette.faint)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hovered ? ChatPalette.button : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(L10n.t("chat.file.remove"))
            .accessibilityLabel(L10n.t("chat.file.remove") + " " + item.name)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatPalette.chip))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ChatPalette.fieldEdge, lineWidth: 1))
        .help(item.path)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }

    @ViewBuilder private var tag: some View {
        switch ChatFolder.kind(of: item) {
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(ChatPalette.tagDocumentText)
        case let kind:
            if let label = ChatFolder.label(of: item) {
                let (ground, ink) = Self.colors(kind)
                Text(label.count > 4 ? String(label.prefix(4)) : label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(ground))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(ChatPalette.tagOtherText)
            }
        }
    }

    private static func colors(_ kind: ChatFolder.Kind) -> (Color, Color) {
        switch kind {
        case .pdf: return (ChatPalette.tagDocument, ChatPalette.tagDocumentText)
        case .image: return (ChatPalette.tagImage, ChatPalette.tagImageText)
        case .folder, .other: return (ChatPalette.tagOther, ChatPalette.tagOtherText)
        }
    }
}

/// The folder the chat works in, in the balloon's corner: its name, or
/// "own folder" for the workspace. Before the first prompt a click
/// chooses another; after it, it shows the folder in Finder.
private struct FolderLabel: View {
    let folder: String?
    let locked: Bool
    let action: () -> Void
    @State private var hovered = false

    private var name: String {
        folder.map { ($0 as NSString).lastPathComponent } ?? L10n.t("chat.folder.workspace")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5, weight: .medium))
                Text(name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(hovered ? ChatPalette.chipText : ChatPalette.faint)
            // Its own width up to 130 pt: a long name gives way in the
            // middle, a short one leaves no gap before the mode.
            .frame(maxWidth: 130, alignment: .trailing)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t(locked ? "chat.folder.show" : "chat.folder.change",
                     ["folder": folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? name]))
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// The chat's permission mode beside the folder, in the same quiet type:
/// a click offers the three (`PermissionMode`), for the next turn on.
private struct ModeLabel: View {
    let mode: PermissionMode
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let name = L10n.t(ChatModel.modeKey(mode))
        Button(action: action) {
            HStack(spacing: 2) {
                Text(name.lowercased(with: Locale(identifier: L10n.language)))
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(hovered ? 1 : 0.6)
            }
            .foregroundStyle(hovered ? ChatPalette.chipText : ChatPalette.faint)
            // Whole, always: the longest (Turkish "düzenlemeleri kabul et",
            // "accept edits", ~125 pt)
            // fits the footer's own line when the hint leaves no room.
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t("chat.mode.help", ["mode": name]))
        .accessibilityLabel(L10n.t("chat.mode.help", ["mode": name]))
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// A tool call that was denied without a card (auto mode's classifier, a
/// deny rule): one dim amber line — what did not run — and, when the chat
/// could ask instead, the way to try it there.
private struct NotDoneLine: View {
    let line: ChatSession.NotDone
    let retry: ((ChatSession.NotDone) -> Void)?
    @State private var hovered = false

    var body: some View {
        FlowLayout(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "slash.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatPalette.amber.opacity(0.6))
                Text(L10n.t(ChatModel.notDoneKey(line)))
                    .foregroundStyle(ChatPalette.cardTitle.opacity(0.7))
                // The call's own line, as Claude wrote it.
                Text(verbatim: line.subject ?? line.tool)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ChatPalette.cardText.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let retry {
                Button { retry(line) } label: {
                    Text(L10n.t("chat.notDone.retry"))
                        .foregroundStyle(hovered ? ChatPalette.cardTitle : ChatPalette.amber.opacity(0.75))
                        .underline(hovered)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .animation(.easeOut(duration: 0.1), value: hovered)
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

    /// About eight lines of command before the card scrolls.
    static let commandMaxHeight: CGFloat = 112

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
                // A command whole — never its first line, never cut: what
                // [Allow] lets run is all on the card, scrolling if long.
                if let command = card.command {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(verbatim: command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ChatPalette.cardCode)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.commandMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let subject = card.subject {
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

/// One chat in the history: its title, and under it where and how long
/// ago. The row opens the chat; pin and × come with the pointer, and a
/// pinned chat keeps its pin in sight.
private struct HistoryRow: View {
    let item: ChatModel.HistoryItem
    let now: Date
    let open: () -> Void
    let pin: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    static let height: CGFloat = 34

    private var place: String {
        item.folder.map { ($0 as NSString).lastPathComponent } ?? L10n.t("chat.folder.workspace")
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                // The title is data: the chat's own words.
                Text(verbatim: item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(hovered ? ChatPalette.text : ChatPalette.reply)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: place + " · " + StatusLine.duration(now.timeIntervalSince(item.when),
                                                                 in: L10n.language))
                    .font(.system(size: 10.5))
                    .foregroundStyle(ChatPalette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovered || item.pinned {
                IconButton(systemImage: item.pinned ? "pin.fill" : "pin",
                           help: L10n.t(item.pinned ? "chat.history.unpin" : "chat.history.pin"),
                           tint: item.pinned && !hovered ? ChatPalette.placeholder : nil,
                           action: pin)
            }
            if hovered {
                IconButton(systemImage: "xmark", help: L10n.t("chat.history.remove"), action: remove)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovered ? ChatPalette.chipHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// A small round icon button: the history row's pin and ×.
private struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? ChatPalette.text : tint ?? ChatPalette.faint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovered ? ChatPalette.button : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovered = $0 }
    }
}

/// A dim text button: `[+ New]`, "Clear history", a made file's actions.
private struct QuietButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(hovered ? ChatPalette.chipText : ChatPalette.faint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? ChatPalette.chipHover : .clear))
            .contentShape(Rectangle())
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
