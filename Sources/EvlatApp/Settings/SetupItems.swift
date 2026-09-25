import AppKit
import SwiftUI
import EvlatCore

// The setup's and the settings window's shared parts (`014`, R2/R3): one row
// value, one row view, and the model behind both. There is no protocol over
// the items: each reads its own thing (a settings file, the link, the login
// item) and reduces it to `SetupStatus`.

/// What the user can have Evlat set up here.
enum SetupItem: String, CaseIterable, Identifiable {
    case claudeHooks, codexHooks, usageRelay, commandLink, loginItem

    var id: String { rawValue }

    var nameKey: String { "setup.item.\(rawValue)" }
}

/// How a row reads at a glance.
enum SetupStatus: Equatable {
    case installed
    /// There, but not what this Evlat would write: an old hook command,
    /// another copy's or a broken link.
    case outdated
    case missing
    /// Someone else's (a `evlat` that is not Evlat's) or changed by hand
    /// (the status line wrapper): drawn dim, never written over.
    case foreign
    /// Could not be read (a settings file that is not JSON), or a login item
    /// waiting for the user's approval.
    case unknown

    var key: String {
        switch self {
        case .installed: return "setup.status.installed"
        case .outdated: return "setup.status.outdated"
        case .missing: return "setup.status.missing"
        case .foreign: return "setup.status.foreign"
        case .unknown: return "setup.status.unknown"
        }
    }
}

/// What a row's button does, from its status.
enum SetupAction: Equatable {
    case install, update, remove

    var key: String {
        switch self {
        case .install: return "setup.action.install"
        case .update: return "setup.action.update"
        case .remove: return "setup.action.remove"
        }
    }

    var installs: Bool { self != .remove }
}

/// One row, read fresh: nothing here is cached between reads.
struct SetupRow: Identifiable, Equatable {
    let item: SetupItem
    let status: SetupStatus
    let name: String
    /// The file it writes, or what it is.
    let detail: String
    /// A second line: where another copy's link goes, `PATH` missing the
    /// link's directory, the login item's copy.
    let note: String?
    /// The last refused write, until one succeeds.
    let failure: String?

    var id: String { item.rawValue }

    /// `nil`: nothing to press (someone else's, unreadable).
    var action: SetupAction? {
        switch status {
        case .missing: return .install
        case .outdated: return .update
        case .installed: return .remove
        case .foreign, .unknown: return nil
        }
    }
}

/// A block to paste instead of the automatic write, and how to take it out.
struct SetupManual: Equatable {
    /// The writer's own bytes (`RemoteSettings.manual`, `CommandLink`).
    let text: String
    /// For the status line: the wrapper around a command the user already
    /// has, with a placeholder in its place.
    let wrapping: String?
    let removal: String
}

/// Something the menu's dim lines and the settings list's dot are made of.
enum SetupAttention: Equatable {
    case hooksOutdated(AgentSource)
    case usageModified
    case refused(SetupItem)
    case hotKeyUnregistered
    case machineUnreachable(String)
    case commandLinkElsewhere

    /// Where the settings window shows it (`phase-2`'s sections).
    enum Section: Equatable { case general, sessions, chat, commandLine, remote }

    var section: Section {
        switch self {
        case .hooksOutdated, .usageModified: return .sessions
        case .refused(let item):
            switch item {
            case .claudeHooks, .codexHooks, .usageRelay: return .sessions
            case .commandLink: return .commandLine
            case .loginItem: return .general
            }
        case .hotKeyUnregistered: return .chat
        case .machineUnreachable: return .remote
        case .commandLinkElsewhere: return .commandLine
        }
    }
}

/// The rows' state for both windows. Reads when asked (`reload`) and after
/// each write; writes only through `Host`, whose closures are the
/// controller's writers (`AppController.setupHost`). Main queue only.
@MainActor
final class SetupModel: ObservableObject {
    /// What the model needs from the app — closures, so a test hands a
    /// recorder (`RemoteMachinesModel.Host`'s pattern).
    struct Host {
        /// `nil` (every test's controller): no row that writes a file, and
        /// no write.
        var home: () -> URL?
        /// This process's binary, what the link points at.
        var binary: () -> URL?
        /// `nil`: no login item row.
        var loginStatus: () -> LoginItem.Status?
        /// The login shell's `PATH` once read; `nil` says nothing about it.
        var loginPath: () -> String?
        var hotKeyRefused: () -> Bool
        /// Names of the machines whose tunnel is failing.
        var unreachableMachines: () -> [String]

        var setHooks: (AgentSource, Bool) -> Void
        var setUsageRelay: (Bool) -> Void
        /// Installed?, replacing another copy's or a broken link?
        var setCommandLink: (Bool, Bool) -> Void
        var setLoginItem: (Bool) -> Void

        var hookFailure: (AgentSource) -> SettingsFile.Failure?
        var usageFailure: () -> SettingsFile.Failure?
        var commandLinkFailure: () -> CommandLinkWriter.Failure?
        var loginItemFailed: () -> Bool
    }

    @Published private(set) var rows: [SetupRow] = []
    /// The setup's "install these": what one press writes (`applyQueue`).
    @Published var queued: Set<SetupItem> = []
    /// The one open "by hand" block. Opening another closes it.
    @Published private(set) var manualOpen: SetupItem?
    @Published private(set) var attention: [SetupAttention] = []

    private let host: Host
    let lang: String
    /// The link's state as last read: the consent line and the write must
    /// agree on whether another copy's link is replaced.
    private var linkState: CommandLink.State?

    init(host: Host, lang: String = L10n.language) {
        self.host = host
        self.lang = lang
        reload()
    }

    // MARK: - Reading

    /// Reads every item again. "I added it, check" is this: it only reads.
    func reload() {
        var rows: [SetupRow] = []
        var attention: [SetupAttention] = []
        let home = host.home()
        linkState = nil
        if let home {
            for source in AppController.presentSources(home: home) {
                let item: SetupItem = source == .claude ? .claudeHooks : .codexHooks
                let status: SetupStatus
                switch try? HookSettings.state(at: source.settingsFile(home: home), for: source) {
                case .current?: status = .installed
                case .outdated?: status = .outdated; attention.append(.hooksOutdated(source))
                case .missing?: status = .missing
                case nil: status = .unknown
                }
                rows.append(row(item, status, detail: "~/" + source.settingsPath,
                                failure: host.hookFailure(source).map { L10n.t(AppController.failureKey($0), in: lang) }))
                if host.hookFailure(source) != nil { attention.append(.refused(item)) }
                guard source == .claude else { continue }
                let usage: SetupStatus
                switch try? StatusLineRelay.state(at: source.settingsFile(home: home)) {
                case .current?: usage = .installed
                case .modified?: usage = .foreign; attention.append(.usageModified)
                case .missing?: usage = .missing
                case nil: usage = .unknown
                }
                rows.append(row(.usageRelay, usage, detail: "~/" + source.settingsPath,
                                failure: host.usageFailure().map { L10n.t(AppController.failureKey($0), in: lang) }))
                if host.usageFailure() != nil { attention.append(.refused(.usageRelay)) }
            }
            if let binary = host.binary() {
                let state = CommandLink.state(at: CommandLink.link(home: home), binary: binary)
                linkState = state
                let status: SetupStatus
                var note: String?
                switch state {
                case .current: status = .installed
                case .otherCopy(let target):
                    status = .outdated
                    note = L10n.t("setup.command.otherCopy", ["target": target], in: lang)
                    attention.append(.commandLinkElsewhere)
                case .broken(let target):
                    status = .outdated
                    note = L10n.t("setup.command.broken", ["target": target], in: lang)
                    attention.append(.commandLinkElsewhere)
                case .foreign:
                    status = .foreign
                    note = L10n.t("setup.command.foreign", in: lang)
                case .missing: status = .missing
                }
                if note == nil, let path = host.loginPath(), !CommandLink.isOnPath(path, home: home) {
                    note = L10n.t("setup.command.notOnPath", ["directory": CommandLink.directoryDisplayPath], in: lang)
                }
                rows.append(row(.commandLink, status, detail: CommandLink.displayPath, note: note,
                                failure: host.commandLinkFailure().map { L10n.t(Self.failureKey($0), in: lang) }))
                if host.commandLinkFailure() != nil { attention.append(.refused(.commandLink)) }
            }
        }
        if let login = host.loginStatus() {
            let status: SetupStatus
            switch login {
            case .on: status = .installed
            case .off: status = .missing
            case .needsApproval: status = .unknown
            }
            let path = host.binary().map { Self.bundlePath(of: $0) }
            rows.append(row(.loginItem, status, detail: L10n.t("setup.login.detail", in: lang),
                            note: login == .needsApproval ? L10n.t("setup.login.needsApproval", in: lang)
                                : path.map { L10n.t("setup.login.copy", ["path": $0], in: lang) },
                            failure: host.loginItemFailed() ? L10n.t("setup.login.failed", in: lang) : nil))
            if host.loginItemFailed() { attention.append(.refused(.loginItem)) }
        }
        if host.hotKeyRefused() { attention.append(.hotKeyUnregistered) }
        attention += host.unreachableMachines().map(SetupAttention.machineUnreachable)
        self.rows = rows
        self.attention = attention
        if let manualOpen, !rows.contains(where: { $0.item == manualOpen }) { self.manualOpen = nil }
    }

    private func row(_ item: SetupItem, _ status: SetupStatus, detail: String, note: String? = nil,
                     failure: String?) -> SetupRow {
        SetupRow(item: item, status: status, name: L10n.t(item.nameKey, in: lang), detail: detail,
                 note: note, failure: failure)
    }

    func row(_ item: SetupItem) -> SetupRow? { rows.first { $0.item == item } }

    /// `…/Evlat.app` for a binary inside one, else the binary.
    nonisolated static func bundlePath(of binary: URL) -> String {
        let app = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app.path : binary.path
    }

    nonisolated static func failureKey(_ failure: CommandLinkWriter.Failure) -> String {
        switch failure {
        case .foreign: return "setup.command.error.foreign"
        case .notAgreed: return "setup.command.error.changed"
        case .nothingToRemove: return "setup.command.error.nothingToRemove"
        case .unwritable: return "setup.command.error.unwritable"
        }
    }

    // MARK: - Consent (R3)

    /// What pressing `action` on `item` writes, one line per file. Nothing
    /// is written before the press; nothing but these lines is.
    func consent(_ item: SetupItem, _ action: SetupAction) -> [String] {
        switch item {
        case .claudeHooks, .codexHooks, .usageRelay:
            let file = item == .codexHooks ? AgentSource.codex.settingsPath : AgentSource.claude.settingsPath
            return [L10n.t("setup.consent.line", ["file": "~/" + file, "what": what(item, action)], in: lang)]
        case .commandLink:
            guard action.installs else {
                return [L10n.t("setup.consent.command.remove", ["file": CommandLink.displayPath], in: lang)]
            }
            switch linkState {
            case .otherCopy(let target)?:
                return [L10n.t("setup.consent.command.replace", ["file": CommandLink.displayPath, "target": target], in: lang)]
            case .broken(let target)?:
                return [L10n.t("setup.consent.command.broken", ["file": CommandLink.displayPath, "target": target], in: lang)]
            default:
                return [L10n.t("setup.consent.command", ["file": CommandLink.displayPath], in: lang)]
            }
        case .loginItem:
            return [L10n.t(action.installs ? "setup.consent.login.on" : "setup.consent.login.off", in: lang)]
        }
    }

    private func what(_ item: SetupItem, _ action: SetupAction) -> String {
        let hooks = item != .usageRelay
        switch action {
        case .install, .update: return L10n.t(hooks ? "setup.consent.what.hooks" : "setup.consent.what.usage", in: lang)
        case .remove: return L10n.t(hooks ? "setup.consent.what.hooks.remove" : "setup.consent.what.usage.remove", in: lang)
        }
    }

    /// The queued items one press would install: each row still missing or
    /// old, not being set up by hand.
    var queuedWrites: [SetupItem] {
        rows.filter { queued.contains($0.item) && $0.item != manualOpen }
            .filter { $0.action == .install || $0.action == .update }
            .map(\.item)
    }

    /// The queue's consent: the queued items' files and nothing else. Two
    /// items in one file are one line ("hooks and the usage line").
    var queueConsent: [String] {
        let writes = queuedWrites
        var lines: [String] = []
        var claude: [String] = []
        for item in writes {
            switch item {
            case .claudeHooks, .usageRelay: claude.append(what(item, .install))
            default: lines += consent(item, .install)
            }
        }
        if !claude.isEmpty {
            let joined = claude.joined(separator: L10n.t("setup.consent.and", in: lang))
            lines.insert(L10n.t("setup.consent.line", ["file": "~/" + AgentSource.claude.settingsPath,
                                                        "what": joined], in: lang), at: 0)
        }
        return lines
    }

    /// Whether a line about the `.evlat.bak` copy belongs under the consent:
    /// only a settings file is backed up.
    func backsUp(_ items: [SetupItem]) -> Bool {
        items.contains { [.claudeHooks, .codexHooks, .usageRelay].contains($0) }
    }

    // MARK: - Writing

    /// The row's button: the action its status offers, then a fresh read.
    func perform(_ item: SetupItem) {
        guard let action = row(item)?.action else { return }
        write(item, action)
        reload()
    }

    /// The setup's one press: every queued write, then a fresh read.
    func applyQueue() {
        for item in queuedWrites { write(item, .install) }
        reload()
    }

    private func write(_ item: SetupItem, _ action: SetupAction) {
        // The login item is not a file; everything else needs a home.
        guard item == .loginItem || host.home() != nil else { return }
        switch item {
        case .claudeHooks: host.setHooks(.claude, action.installs)
        case .codexHooks: host.setHooks(.codex, action.installs)
        case .usageRelay: host.setUsageRelay(action.installs)
        case .commandLink:
            let replacing: Bool
            switch linkState {
            case .otherCopy?, .broken?: replacing = true
            default: replacing = false
            }
            host.setCommandLink(action.installs, replacing)
        case .loginItem: host.setLoginItem(action.installs)
        }
    }

    // MARK: - By hand

    /// Opens `item`'s block, closing any other; the open one closes.
    func toggleManual(_ item: SetupItem) {
        manualOpen = manualOpen == item ? nil : item
    }

    /// "I added it, check": reads, writes nothing.
    func check() { reload() }

    /// The block to paste: the bytes the writer would write into an empty
    /// file (`RemoteSettings.manual` — the name says remote, the bytes are
    /// the writers'), or the link's `ln -s` line.
    func manual(_ item: SetupItem) -> SetupManual? {
        let manual = RemoteSettings.manual
        let hooksRemoval = L10n.t("setup.manual.remove.hooks", ["marker": manual.marker], in: lang)
        switch item {
        case .claudeHooks: return SetupManual(text: manual.claudeHooks, wrapping: nil, removal: hooksRemoval)
        case .codexHooks: return SetupManual(text: manual.codexHooks, wrapping: nil, removal: hooksRemoval)
        case .usageRelay:
            return SetupManual(text: manual.statusLine, wrapping: manual.wrapping,
                               removal: L10n.t("setup.manual.remove.usage", in: lang))
        case .commandLink:
            guard let binary = host.binary() else { return nil }
            return SetupManual(text: CommandLink.manualLine(binary: binary), wrapping: nil,
                               removal: L10n.t("setup.manual.remove.command", ["line": CommandLink.removeLine], in: lang))
        case .loginItem: return nil
        }
    }

    // MARK: - Attention

    /// A dim line's text.
    func text(_ attention: SetupAttention) -> String {
        switch attention {
        case .hooksOutdated(let source):
            return L10n.t("setup.attention.hooksOutdated", ["source": L10n.t("source.\(source.rawValue)", in: lang)], in: lang)
        case .usageModified: return L10n.t("menu.usage.modified", in: lang)
        case .refused(let item):
            return L10n.t("setup.attention.refused", ["item": L10n.t(item.nameKey, in: lang)], in: lang)
        case .hotKeyUnregistered: return L10n.t("setup.attention.hotKey", in: lang)
        case .machineUnreachable(let name): return L10n.t("setup.attention.machine", ["machine": name], in: lang)
        case .commandLinkElsewhere: return L10n.t("setup.attention.commandLink", in: lang)
        }
    }

    /// Every key this file asks the catalogue for (`L10nTests`' pattern).
    static let keys: [String] = SetupItem.allCases.map(\.nameKey)
        + [SetupStatus.installed, .outdated, .missing, .foreign, .unknown].map(\.key)
        + [SetupAction.install, .update, .remove].map(\.key)
        + ["setup.command.otherCopy", "setup.command.broken", "setup.command.foreign", "setup.command.notOnPath",
           "setup.command.error.foreign", "setup.command.error.changed", "setup.command.error.nothingToRemove",
           "setup.command.error.unwritable",
           "setup.login.detail", "setup.login.copy", "setup.login.needsApproval", "setup.login.failed",
           "setup.consent.title", "setup.consent.line", "setup.consent.and", "setup.consent.backup",
           "setup.consent.nothing",
           "setup.consent.what.hooks", "setup.consent.what.usage", "setup.consent.what.hooks.remove",
           "setup.consent.what.usage.remove",
           "setup.consent.command", "setup.consent.command.replace", "setup.consent.command.broken",
           "setup.consent.command.remove", "setup.consent.login.on", "setup.consent.login.off",
           "setup.manual.open", "setup.manual.copy", "setup.manual.copied", "setup.manual.check",
           "setup.manual.auto", "setup.manual.wrapping",
           "setup.manual.remove.hooks", "setup.manual.remove.usage", "setup.manual.remove.command",
           "setup.attention.hooksOutdated", "setup.attention.refused", "setup.attention.hotKey",
           "setup.attention.machine", "setup.attention.commandLink", "menu.usage.modified"]
}

/// One row as both windows draw it: name and file, status, the button with
/// its consent line right above, and the "by hand" block. Holds no state of
/// its own; the model says what is open.
struct SetupRowView: View {
    let row: SetupRow
    @ObservedObject var model: SetupModel
    /// The setup writes with one press for all rows: its rows draw no
    /// button and no consent of their own.
    var showsButton = true
    @State private var copied = false

    private var lang: String { model.lang }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.system(size: 13, weight: .semibold))
                    Text(row.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(L10n.t(row.status.key, in: lang))
                    .font(.system(size: 12))
                    .foregroundStyle(row.status == .installed ? Color.green : .secondary)
            }
            .opacity(row.status == .foreign ? 0.55 : 1)
            if let note = row.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if let failure = row.failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if showsButton, let action = row.action, model.manualOpen != row.item {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.consent(row.item, action), id: \.self) { line in
                        Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Button(L10n.t(action.key, in: lang)) { model.perform(row.item) }
                        .controlSize(.small)
                }
            }
            manualPart
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var manualPart: some View {
        if let manual = model.manual(row.item), row.status != .installed, row.status != .foreign {
            if model.manualOpen == row.item {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(manual.text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 92)
                    if let wrapping = manual.wrapping {
                        Text(L10n.t("setup.manual.wrapping", in: lang)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(wrapping).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Button(L10n.t(copied ? "setup.manual.copied" : "setup.manual.copy", in: lang)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(manual.text, forType: .string)
                            copied = true
                        }
                        Button(L10n.t("setup.manual.check", in: lang)) { model.check() }
                        Button(L10n.t("setup.manual.auto", in: lang)) { model.toggleManual(row.item) }
                    }
                    .controlSize(.small)
                    Text(manual.removal).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            } else {
                Button(L10n.t("setup.manual.open", in: lang)) { copied = false; model.toggleManual(row.item) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }
}
