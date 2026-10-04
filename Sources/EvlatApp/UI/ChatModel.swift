import Foundation
import EvlatCore
import EvlatAgents

/// What the balloon draws, and the one way out of it: a prompt.
///
/// Written by the controller from the chat's state (`ChatSession`) on each
/// refresh, field by field — a reply streams in at the refresh's pace and
/// nothing else in the balloon should move with it. Observed by `ChatView`
/// alone, `DetailModel`'s pattern.
@MainActor
final class ChatModel: ObservableObject {
    /// Which side the bar is on: the tail points at it.
    @Published var edge: BarPanel.Edge = .right
    /// The text's language: a change builds the balloon's views again
    /// (Settings → General → Language).
    @Published var language = L10n.language
    @Published private(set) var messages: [ChatSession.Message] = []
    @Published private(set) var isRunning = false
    @Published private(set) var failure: ChatSession.Failure?
    /// Is there a program to send to? Without one the balloon says so
    /// instead of offering a line; while it is looked for, the line stays
    /// and sends nothing. Written by the controller.
    @Published var backendState: ChatStore.Availability = .ready
    /// The chat's agent — or, before the first prompt, the one it will be
    /// made on: the corner names it, and so do the "not found" line and the
    /// card. Written by the controller.
    @Published private(set) var agent: AgentID = Agents.chatBackends[0].id
    /// The line being typed.
    @Published var draft = ""
    /// Counts the balloon's openings; a change takes the field's focus.
    @Published private(set) var openings = 0
    /// Files dropped for the next prompt: chips over the
    /// line, sent with it and cleared.
    @Published private(set) var attachments: [ChatFolder.Item] = []
    /// The folder the chat runs in, for the corner label; `nil` is its own
    /// workspace. Written by the controller.
    @Published private(set) var folder: String?
    /// Sent once: the folder is the chat's for good and the label only
    /// shows it.
    @Published private(set) var folderLocked = false
    /// The chat's permission mode — or, before the first prompt, the one
    /// it will start in. The corner label beside the folder shows it.
    @Published private(set) var mode: ChatMode = Agents.chatBackends[0].standardMode
    /// A file is being dragged over the balloon.
    @Published var dropTargeted = false
    /// Does the balloon speak for a chat? Then `[+ New]` takes the hint's
    /// place.
    @Published private(set) var hasChat = false
    /// The history, under an empty balloon: pinned first, then the latest.
    @Published private(set) var history: [HistoryItem] = []
    /// Files a workspace chat made, once its turn is over: full paths.
    @Published private(set) var files: [String] = []

    /// One chat in the history: what it was about, where, when.
    struct HistoryItem: Equatable, Identifiable {
        let id: String
        let title: String
        /// The user's folder; `nil` is its own workspace.
        let folder: String?
        let when: Date
        let pinned: Bool
    }

    /// The prompt, trimmed. The controller turns it into `Action.send`.
    var onSend: ((String) -> Void)?
    /// A card's button: `Action.answer`.
    var onAnswer: ((String, Action.Decision) -> Void)?
    /// The stop button: `Action.stop`.
    var onStop: (() -> Void)?
    /// A chip was added or removed: the folder may follow the files.
    var onAttachmentsChange: (() -> Void)?
    /// The folder label: choose another before the first prompt, show it
    /// in Finder after.
    var onFolder: (() -> Void)?
    /// The mode label: the controller shows the three modes.
    var onMode: (() -> Void)?
    /// A "not done" line's `[Retry in Ask mode]`.
    var onRetry: ((ChatSession.NotDone) -> Void)?
    /// `[+ New]`: an empty balloon, the chat left where it is.
    var onNew: (() -> Void)?
    /// A history row: that chat, to go on with.
    var onOpen: ((String) -> Void)?
    var onPin: ((String, Bool) -> Void)?
    var onRemove: ((String) -> Void)?
    var onClearHistory: (() -> Void)?
    /// A made file's buttons: `[Save…]` and `[Show in Finder]`.
    var onSaveFile: ((String) -> Void)?
    var onRevealFile: ((String) -> Void)?
    /// A code block's `[Copy]`: the text, to the pasteboard.
    var onCopy: ((String) -> Void)?
    /// A reply's link, already checked by `openLink`.
    var onOpenLink: ((URL) -> Void)?
    /// An install page's link, from the balloon that found no program.
    var onOpenInstallPage: ((URL) -> Void)?

    /// One backend's install page, for the balloon that found no program.
    struct InstallLink: Equatable, Identifiable {
        let id: AgentID
        /// The agent's name, a catalogue key (`AgentDisplay.nameKey`).
        let nameKey: String
        let url: URL
    }

    /// Every backend's install page, in the catalogue's order.
    static let installLinks = Agents.chatBackends.compactMap { backend in
        backend.installPage.map { InstallLink(id: backend.id, nameKey: backend.id.agent.display.nameKey, url: $0) }
    }

    /// Three prompts a bare `claude -p` can answer from its own folder,
    /// asking for no folder the system guards (Downloads, Desktop) and no
    /// screen — those would put a macOS permission prompt in front of the
    /// user. Sent as they are.
    static let suggestionKeys = ["chat.suggestion.capabilities", "chat.suggestion.memory",
                                 "chat.suggestion.disk"]

    /// With files, the suggestions follow what they are:
    /// PDFs are summarised or mined for tables, and two of them compared;
    /// images explained or read; one folder organised or looked into. A
    /// mix — or a kind with nothing particular to offer — gets what fits
    /// any file. Never the file-less three: "how much disk is left" is not
    /// a question about a dropped report.
    static func suggestionKeys(for items: [ChatFolder.Item]) -> [String] {
        guard !items.isEmpty else { return suggestionKeys }
        let compare = items.count == 2 ? ["chat.suggestion.compareTwo"]
            : items.count > 2 ? ["chat.suggestion.compare"] : []
        switch ChatFolder.kind(of: items) {
        case .pdf?:
            return ["chat.suggestion.summarize", "chat.suggestion.tables"] + compare
        case .image?:
            return ["chat.suggestion.explain", "chat.suggestion.text"] + compare
        case .folder? where items.count == 1:
            return ["chat.suggestion.organize", "chat.suggestion.contents"]
        default:
            return ["chat.suggestion.summarize", "chat.suggestion.explain"] + compare
        }
    }

    static let fileSuggestionKeys = ["chat.suggestion.summarize", "chat.suggestion.tables",
                                     "chat.suggestion.compareTwo", "chat.suggestion.compare",
                                     "chat.suggestion.explain", "chat.suggestion.text",
                                     "chat.suggestion.organize", "chat.suggestion.contents"]

    /// Every key the balloon asks for, but the failures'.
    static let keys = ["chat.placeholder", "chat.placeholder.file", "chat.placeholder.files",
                       "chat.placeholder.looking", "chat.hint", "chat.missing", "chat.nothingFound",
                       "chat.working", "chat.stop", "chat.agent.help",
                       "chat.permission.title", "chat.permission.tool", "chat.permission.folder",
                       "chat.permission.allow", "chat.permission.deny", "chat.permission.always",
                       "chat.permission.access", "chat.permission.always.command", "chat.permission.reason",
                       "chat.unsupported", "chat.tool.running", "chat.tool.done", "chat.tool.failed",
                       "chat.file.remove", "chat.folder.workspace", "chat.folder.change", "chat.folder.show",
                       "chat.new", "chat.history", "chat.history.pin", "chat.history.unpin",
                       "chat.history.remove", "chat.history.clear", "chat.files", "chat.file.save",
                       "chat.file.show", "chat.code.copy", "chat.code.copied",
                       "chat.mode.help", "chat.notDone", "chat.notDone.auto", "chat.notDone.retry",
                       "chat.notDone.prompt"]
        + modeKeys + modeDetailKeys + BypassConfirmation.keys + suggestionKeys + fileSuggestionKeys + outcomeKeys

    /// What the balloon offers now.
    var suggestions: [String] { Self.suggestionKeys(for: attachments) }

    /// The line's prompt: what to do, or what to do with these — or,
    /// while the program is looked for, that.
    var placeholderKey: String {
        if backendState == .looking { return "chat.placeholder.looking" }
        switch attachments.count {
        case 0: return "chat.placeholder"
        case 1: return "chat.placeholder.file"
        default: return "chat.placeholder.files"
        }
    }

    /// Every chat backend's modes' names, and what each does in one line
    /// (the menu's tooltips).
    static let modeKeys = Agents.chatBackends.flatMap(\.modes).map(\.nameKey)
    static let modeDetailKeys = Agents.chatBackends.flatMap(\.modes).map(\.detailKey)

    /// A "not done" line's first words: the mode is named only for its own
    /// judgement, the denial a retry could get past.
    nonisolated static func notDoneKey(_ line: ChatSession.NotDone) -> String {
        line.retryAs != nil ? "chat.notDone.auto" : "chat.notDone"
    }

    /// Can "not done" lines be tried again where they would ask? Not while
    /// a turn runs.
    private var canRetry: Bool { !isRunning && onRetry != nil }

    /// This line's retry: only the mode's own judgement — a deny rule denies
    /// in every mode — and not when the chat is already in the mode the
    /// retry would switch it to: that would switch it for nothing.
    func canRetry(_ line: ChatSession.NotDone) -> Bool {
        guard canRetry, let target = line.retryAs else { return false }
        return mode.id != target
    }

    static let outcomeKeys = ["chat.permission.allowed", "chat.permission.allowedAlways",
                              "chat.permission.allowedCommand", "chat.permission.denied", "chat.permission.expired"]

    /// An answered card's one line. A switch, like the failures. "Always"
    /// says what it kept: the chat's rules, or this command for the session.
    nonisolated static func outcomeKey(_ outcome: ChatSession.PermissionCard.Outcome,
                                       always: ChatCapabilities.AlwaysOption = .rules) -> String {
        switch outcome {
        case .allowed: return "chat.permission.allowed"
        case .allowedAlways:
            return always == .thisCommand ? "chat.permission.allowedCommand" : "chat.permission.allowedAlways"
        case .denied: return "chat.permission.denied"
        case .expired: return "chat.permission.expired"
        }
    }

    /// The third button's title: a folder to reach, a rule for the chat, or
    /// this command again.
    nonisolated static func alwaysKey(_ card: ChatSession.PermissionCard) -> String {
        switch card.always {
        case .thisCommand: return "chat.permission.always.command"
        case .rules: return card.directories.isEmpty ? "chat.permission.always" : "chat.permission.access"
        }
    }

    /// The agent's name, from the catalogue.
    var agentName: String { L10n.t(agent.agent.display.nameKey) }

    func setAgent(_ id: AgentID) {
        if agent != id { agent = id }
    }

    /// A failure's line. A switch, so a new reason does not compile without one.
    nonisolated static func failureKey(_ failure: ChatSession.Failure) -> String {
        switch failure {
        case .noBinary: return "chat.failure.noBinary"
        case .launch: return "chat.failure.launch"
        case .exited: return "chat.failure.exited"
        case .result: return "chat.failure.result"
        case .interrupted: return "chat.failure.interrupted"
        case .noListener: return "chat.failure.noListener"
        }
    }

    /// The process's own words under the line, when it left any.
    nonisolated static func failureDetail(_ failure: ChatSession.Failure) -> String? {
        switch failure {
        case .launch(let detail): return detail
        case .exited(_, let detail): return detail
        case .result(_, let text): return text
        case .noListener(let status): return status
        case .noBinary, .interrupted: return nil
        }
    }

    /// The chat's state; `nil` is a balloon with nothing sent yet. Only what
    /// changed is written.
    func update(from chat: ChatSession?) {
        let messages = chat?.messages ?? []
        if self.messages != messages { self.messages = messages }
        let running = chat?.isRunning ?? false
        if isRunning != running { isRunning = running }
        let failure = chat?.failure
        if self.failure != failure { self.failure = failure }
    }

    /// Sends a prompt: `false` for a blank line, while a turn runs, or
    /// unless the program to send it to is there (`backendState`) — while
    /// it is looked for too, so a chat is not made on a backend the search
    /// is about to replace.
    @discardableResult
    func submit(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, backendState == .ready, let onSend else { return false }
        draft = ""
        onSend(prompt)
        return true
    }

    func answer(_ id: String, _ decision: Action.Decision) {
        onAnswer?(id, decision)
    }

    func stop() {
        guard isRunning else { return }
        onStop?()
    }

    func opened() {
        openings &+= 1
    }

    /// Dropped files, after those already there; one dropped twice is kept
    /// once.
    func add(_ items: [ChatFolder.Item]) {
        let new = items.reduce(into: [ChatFolder.Item]()) { kept, item in
            if !attachments.contains(item), !kept.contains(item) { kept.append(item) }
        }
        guard !new.isEmpty else { return }
        attachments += new
        onAttachmentsChange?()
    }

    func remove(_ item: ChatFolder.Item) {
        guard let index = attachments.firstIndex(of: item) else { return }
        attachments.remove(at: index)
        onAttachmentsChange?()
    }

    /// The files going out with a prompt: handed over and cleared.
    func takeAttachments() -> [ChatFolder.Item] {
        defer { if !attachments.isEmpty { attachments = [] } }
        return attachments
    }

    func setMode(_ mode: ChatMode) {
        if self.mode != mode { self.mode = mode }
    }

    func modeTapped() {
        onMode?()
    }

    func retry(_ line: ChatSession.NotDone) {
        guard canRetry(line) else { return }
        onRetry?(line)
    }

    func setFolder(_ path: String?, locked: Bool) {
        if folder != path { folder = path }
        if folderLocked != locked { folderLocked = locked }
    }

    func folderTapped() {
        onFolder?()
    }

    // MARK: - History and made files

    func setHasChat(_ value: Bool) {
        if hasChat != value { hasChat = value }
    }

    func setHistory(_ items: [HistoryItem]) {
        if history != items { history = items }
    }

    func setFiles(_ paths: [String]) {
        if files != paths { files = paths }
    }

    /// Is there anything "Clear history" would take? Pinned chats stay.
    var canClearHistory: Bool { history.contains { !$0.pinned } }

    func newChat() { onNew?() }
    func open(_ id: String) { onOpen?(id) }
    func pin(_ id: String, _ pinned: Bool) { onPin?(id, pinned) }
    func removeFromHistory(_ id: String) { onRemove?(id) }
    func clearHistory() { onClearHistory?() }
    func save(_ path: String) { onSaveFile?(path) }
    func reveal(_ path: String) { onRevealFile?(path) }

    func openInstallPage(_ link: InstallLink) { onOpenInstallPage?(link.url) }

    // MARK: - A reply's markdown

    func copy(_ text: String) { onCopy?(text) }

    /// The link schemes a reply may open. A reply is the model's text: a
    /// `file:` or an app's own scheme would launch something from a click
    /// the user took for a web page.
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Opens a reply's link when its scheme is one of `linkSchemes`; `false`
    /// for any other, which is left alone.
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), Self.linkSchemes.contains(scheme) else { return false }
        onOpenLink?(url)
        return true
    }
}
