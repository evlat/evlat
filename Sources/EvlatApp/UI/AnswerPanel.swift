import AppKit
import Carbon.HIToolbox
import SwiftUI
import EvlatCore

/// "Other…" on a question's card: one line to write an answer in. Also
/// `ssh`'s question (`PromptView`): a password, a host key's yes or no.
///
/// The bar never takes the keyboard (`BarPanel.canBecomeKey` is `false`),
/// so the line is a window of its own, laid exactly on the card's "Other…"
/// row and drawn as that row, so the answer is written where it was asked
/// for (`present(over:)`): the balloon's
/// pattern (`ChatPanel`) — `.nonactivatingPanel` with `canBecomeKey`, so it
/// gets the keys and Evlat stays in the background. Return answers, Esc or
/// a click elsewhere lets it go, the answer unwritten. Built once and
/// ordered out between uses.
final class AnswerPanel: NSPanel {
    /// Esc, or the keyboard went elsewhere: the controller closes it.
    var onClose: (() -> Void)?
    /// `false`: only Esc closes it; the keyboard may go elsewhere and come
    /// back — to fetch a password from a password manager, say.
    var closesWhenKeyLeaves = true

    static let width = AppController.detailCardWidth
    static let height: CGFloat = 96

    init(content: some View, size: CGSize = CGSize(width: AnswerPanel.width, height: AnswerPanel.height)) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Over the card, which is on the bar's level.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        contentView = hosting
        WindowStage.stage(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Offstage the keyboard is a flag (`ChatPanel`, `WindowStage`).
    private var stagedKey = false

    override var isKeyWindow: Bool { WindowStage.isOffstage ? stagedKey : super.isKeyWindow }

    override func makeKey() {
        guard WindowStage.isOffstage else { return super.makeKey() }
        stagedKey = true
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        guard WindowStage.isOffstage, stagedKey else { return }
        stagedKey = false
        keyWentElsewhere()
    }

    /// Esc before the field editor answers it with completion; not while an
    /// input method is composing (`ChatPanel.sendEvent`).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onClose?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// ⌘V and the other editing keys: a password is often pasted
    /// (`EditingKeys`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditingKeys.perform(event, from: self) || super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        keyWentElsewhere()
    }

    private func keyWentElsewhere() {
        if isVisible, closesWhenKeyLeaves { onClose?() }
    }

    /// Its top-left on the card's, in screen coordinates; shown with the
    /// keyboard and no activation.
    /// Laid on `rect` (screen coordinates), its size: the "Other…" row
    /// the line stands in for.
    func present(over rect: NSRect) {
        follow(rect)
        orderFrontRegardless()
        makeKey()
    }

    /// Moved to the row's new place, keyboard untouched: the row moves while
    /// it is written in — the options scroll, the card goes to another slot
    /// or changes height — and a line left where it was opened stood beside
    /// the row it was writing for.
    func follow(_ rect: NSRect) {
        guard rect != frame else { return }
        setFrame(rect, display: false)
        contentView?.frame = NSRect(origin: .zero, size: rect.size)
    }

    func present(atTopLeft point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height))
        orderFrontRegardless()
        makeKey()
    }

    /// Centred near the top of `screen`'s visible frame: a question that
    /// does not come out of the bar (`ssh`'s). Same keyboard, no activation.
    func present(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return present(atTopLeft: .zero) }
        present(atTopLeft: NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - visible.height / 5))
    }
}

/// What the line asks and holds.
@MainActor
final class AnswerModel: ObservableObject {
    @Published var question = ""
    @Published var text = ""
    /// The question picks any, not one: the line's mark is square, as the
    /// row's it stands on.
    @Published var multiSelect = false
    /// Bumped on every opening, so the field takes the focus each time.
    @Published private(set) var openings = 0
    var onSubmit: (String) -> Void = { _ in }

    func open(question: String, text: String, multiSelect: Bool = false) {
        self.question = question
        self.text = text
        self.multiSelect = multiSelect
        openings += 1
    }
}

struct AnswerView: View {
    @ObservedObject var model: AnswerModel
    @FocusState private var focused: Bool

    static let placeholderKey = "answer.placeholder"
    static let hintKey = "answer.hint"
    static var keys: [String] { [placeholderKey, hintKey] }

    /// The card's "Other…" row being written in: its empty mark where it
    /// was, the field where its words were, the keys under it — on the
    /// row's own ground, opaque, so nothing of the row beneath shows through.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            DetailCard.mark(multi: model.multiSelect, picked: false)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $model.text, prompt: Text(verbatim: L10n.t(Self.placeholderKey)))
                    .textFieldStyle(.plain)
                    .font(DetailCard.replyFont.weight(.medium))
                    .foregroundStyle(BarPalette.textPrimary)
                    .focused($focused)
                    .onSubmit { model.onSubmit(model.text) }
                Text(verbatim: L10n.t(Self.hintKey))
                    .font(DetailCard.labelFont)
                    .foregroundStyle(DetailCard.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ZStack {
            shape.fill(DetailCard.ground)
            shape.fill(SessionIndicator.amber.opacity(DetailCard.askOpacity))
            shape.fill(Color.white.opacity(0.10))
        })
        .overlay(shape.strokeBorder(SessionIndicator.amber.opacity(focused ? 0.7 : 0.4), lineWidth: 1))
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.openings) { focused = true }
    }
}

/// `ssh`'s question while it waits (`RemoteTunnels.Prompt`): its text as
/// `ssh` wrote it, then a hidden field or Yes/No.
@MainActor
final class PromptModel: ObservableObject {
    @Published private(set) var prompt: RemoteTunnels.Prompt?
    @Published var secret = ""
    /// "Remember in Keychain": on by default, password prompts only.
    @Published var remember = true
    @Published private(set) var openings = 0
    /// The answer (`nil`: refused) and the box, for the shown prompt.
    var onAnswer: (_ id: String, _ text: String?, _ remember: Bool) -> Void = { _, _, _ in }

    func show(_ prompt: RemoteTunnels.Prompt) {
        guard prompt != self.prompt else { return }
        self.prompt = prompt
        secret = ""
        remember = true
        openings += 1
    }

    func clear() {
        prompt = nil
        secret = ""
    }

    /// Return or the button: the field's text, or "yes"/"no" — what `ssh`
    /// reads from its helper.
    func submit(_ text: String? = nil) {
        guard let prompt else { return }
        let answer = text ?? secret
        // An empty password is a failed login, not an answer: Return on
        // an empty field waits for the text.
        if prompt.isPassword, answer.isEmpty { return }
        secret = ""
        onAnswer(prompt.id, answer, prompt.isPassword && remember)
    }

    func refuse() {
        guard let prompt else { return }
        secret = ""
        onAnswer(prompt.id, nil, false)
    }
}

struct PromptView: View {
    @ObservedObject var model: PromptModel
    @FocusState private var focused: Bool

    static let size = CGSize(width: 360, height: 200)
    static var keys: [String] {
        ["prompt.title", "prompt.placeholder", "prompt.remember", "prompt.yes", "prompt.no",
         "prompt.cancel", "prompt.send"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = model.prompt {
                Text(verbatim: L10n.t("prompt.title", ["machine": prompt.machine]))
                    .font(DetailCard.labelFont)
                    .foregroundStyle(BarPalette.textSecondary)
                    .lineLimit(1)
                // `ssh`'s words, whole: a host key's fingerprint is several
                // lines and the user must be able to read all of it.
                ScrollView {
                    Text(verbatim: prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11.5))
                        .foregroundStyle(BarPalette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: .infinity)
                if prompt.isYesNo {
                    HStack(spacing: 8) {
                        Spacer()
                        button("prompt.no") { model.submit("no") }
                        button("prompt.yes") { model.submit("yes") }
                    }
                } else {
                    SecureField("", text: $model.secret, prompt: Text(verbatim: L10n.t("prompt.placeholder")))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(BarPalette.textPrimary)
                        .focused($focused)
                        .onSubmit { model.submit() }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SessionIndicator.amber.opacity(focused ? 0.7 : 0.3), lineWidth: 1))
                    HStack(spacing: 8) {
                        if prompt.isPassword {
                            Toggle(isOn: $model.remember) {
                                Text(verbatim: L10n.t("prompt.remember"))
                                    .font(DetailCard.labelFont)
                                    .foregroundStyle(BarPalette.textSecondary)
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        }
                        Spacer()
                        button("prompt.cancel") { model.refuse() }
                        button("prompt.send") { model.submit() }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DetailCard.corner, style: .continuous)
            .fill(BarPalette.body)
            .overlay(RoundedRectangle(cornerRadius: DetailCard.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)))
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.openings) { focused = true }
    }

    private func button(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: L10n.t(key))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BarPalette.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
