import AppKit
import SwiftUI
import EvlatCore

// The setup's and the settings window's shared parts: one row
// value, one row view, and the model behind both. There is no protocol over
// the items: each reads its own thing (an agent's files, the link, the login
// item) and reduces it to `SetupStatus`.

/// What the user can have Evlat set up here. An agent is one item: its
/// hooks, approval hook and usage line are installed together
/// (`AgentIntegration`), so the catalogue (`AgentSource.allCases`) is the
/// list and nothing here names an agent.
enum SetupItem: Hashable, Identifiable {
    case agent(AgentSource), commandLink, loginItem

    static var allCases: [SetupItem] { AgentSource.allCases.map(SetupItem.agent) + [.commandLink, .loginItem] }

    var id: String {
        switch self {
        case .agent(let source): return "agent." + source.rawValue
        case .commandLink: return "commandLink"
        case .loginItem: return "loginItem"
        }
    }

    /// The agent the row installs; `nil` for the others.
    var agent: AgentSource? {
        if case .agent(let source) = self { return source }
        return nil
    }

    /// An agent's row is named by the agent (`source.*`, the names the bar
    /// uses too).
    var nameKey: String {
        switch self {
        case .agent(let source): return "source.\(source.rawValue)"
        case .commandLink: return "setup.item.commandLink"
        case .loginItem: return "setup.item.loginItem"
        }
    }
}

/// How a row reads at a glance.
enum SetupStatus: Equatable {
    case installed
    /// There, but not what this Evlat would write: an old hook command, an
    /// agent with a part missing, another copy's or a broken link.
    case outdated
    case missing
    /// Someone else's (a `evlat` that is not Evlat's) or changed by hand
    /// (the status line wrapper): drawn dim, never written over.
    case foreign
    /// Could not be read (a settings file that is not JSON), or a login item
    /// waiting for the user's approval.
    case unknown
    /// An agent whose folder is not on this Mac: drawn dim, nothing to
    /// press.
    case notFound

    var key: String {
        switch self {
        case .installed: return "setup.status.installed"
        case .outdated: return "setup.status.outdated"
        case .missing: return "setup.status.missing"
        case .foreign: return "setup.status.foreign"
        case .unknown: return "setup.status.unknown"
        case .notFound: return "setup.status.notFound"
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

/// One of an agent's parts, as its card's "What it writes" lists it.
struct SetupPart: Equatable {
    let name: String
    let file: String
    let status: SetupStatus
}

/// One row, read fresh: nothing here is cached between reads.
struct SetupRow: Identifiable, Equatable {
    let item: SetupItem
    let status: SetupStatus
    let name: String
    /// The files it writes, or what it is.
    let detail: String
    /// A second line: where another copy's link goes, `PATH` missing the
    /// link's directory, the login item's copy, a usage line changed by hand.
    let note: String?
    /// The last refused write, until one succeeds.
    let failure: String?
    /// An agent's parts, each with its file.
    var parts: [SetupPart] = []
    /// The agent's usage line is Evlat's and can be taken out alone.
    var removesRelay = false

    var id: String { item.id }

    /// `nil`: nothing to press (someone else's, unreadable, not here).
    var action: SetupAction? {
        switch status {
        case .missing: return .install
        case .outdated: return .update
        case .installed: return .remove
        case .foreign, .unknown, .notFound: return nil
        }
    }
}

/// A block to paste instead of the automatic write, and how to take it out.
struct SetupManual: Equatable {
    /// The writer's own bytes (`LocalHooks.manual`, `CommandLink`).
    let text: String
    /// For the status line: the wrapper around a command the user already
    /// has, with a placeholder in its place.
    let wrapping: String?
    let removal: String
    /// An agent's `statusLine`, when its usage line is a part: a second
    /// block under the hooks'.
    var statusLine: String? = nil
}

/// Something the menu's dim lines and the settings list's dot are made of.
enum SetupAttention: Equatable {
    /// The agent's hooks are an old copy's. A missing usage line is not
    /// attention: the card offers it, the menu stays quiet.
    case hooksOutdated(AgentSource)
    /// The agent's usage line was edited by hand and is left alone.
    case usageModified(AgentSource)
    case refused(SetupItem)
    case hotKeyUnregistered
    case machineUnreachable(String)
    /// A machine's tunnel stopped for the user's password (`needsUser`).
    case machineNeedsPassword(String)
    case commandLinkElsewhere

    /// Where the settings window shows it: its sections, in the side
    /// list's order. The raw value is `EVLAT_SETTINGS`'.
    enum Section: String, CaseIterable, Equatable {
        case general, agents, usage, chat, commandLine = "command", remote
    }

    var section: Section {
        switch self {
        case .hooksOutdated, .usageModified: return .agents
        case .refused(let item):
            switch item {
            case .agent: return .agents
            case .commandLink: return .commandLine
            case .loginItem: return .general
            }
        case .hotKeyUnregistered: return .chat
        case .machineUnreachable, .machineNeedsPassword: return .remote
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
        /// Names of the machines whose tunnel waits for the user's password.
        var machinesNeedingPassword: () -> [String] = { [] }

        /// An agent's parts installed (or updated) or removed, as one.
        var setAgent: (AgentSource, Bool) -> Void
        /// The agent's usage line alone, taken out.
        var removeUsageRelay: (AgentSource) -> Void = { _ in }
        /// Installed?, replacing another copy's or a broken link?
        var setCommandLink: (Bool, Bool) -> Void
        var setLoginItem: (Bool) -> Void

        var agentFailure: (AgentSource) -> AgentIntegration.Failure?
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
    /// Each agent's parts as last read: the consent lists only the parts
    /// the press changes, and the press is the one the row offered.
    private var agentStates: [AgentSource: AgentIntegration.State] = [:]

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
        agentStates = [:]
        if let home {
            for source in AgentSource.allCases {
                rows.append(agentRow(source, home: home, attention: &attention))
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
            // Registered and waiting in System Settings: on as far as Evlat
            // is concerned, so the switch can still take it back.
            case .needsApproval: status = .installed
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
        attention += host.machinesNeedingPassword().map(SetupAttention.machineNeedsPassword)
        self.rows = rows
        self.attention = attention
        // A block closes when its row goes, or once what it adds is there
        // ("I added it, check" found it): nothing is left to wait for.
        if let manualOpen, !rows.contains(where: { $0.item == manualOpen && $0.status != .installed }) {
            self.manualOpen = nil
        }
    }

    /// One agent's card: every catalogue agent has one, dim when it is not
    /// on this Mac. Only an old hook part asks for attention; a missing
    /// usage line is offered by the card alone.
    private func agentRow(_ source: AgentSource, home: URL, attention: inout [SetupAttention]) -> SetupRow {
        let item = SetupItem.agent(source)
        let files = AgentIntegration.files(home: home, for: source).map { "~/" + Self.relative($0, to: home) }
            .joined(separator: " · ")
        guard source.isPresent(home: home) else {
            return row(item, .notFound, detail: files, failure: nil)
        }
        let failure = host.agentFailure(source).map(failureText)
        if failure != nil { attention.append(.refused(item)) }
        guard let state = try? AgentIntegration.state(home: home, for: source) else {
            return row(item, .unknown, detail: files, failure: failure)
        }
        agentStates[source] = state
        if state.hooks == .outdated { attention.append(.hooksOutdated(source)) }
        var note: String?
        if state.relay == .modified {
            attention.append(.usageModified(source))
            note = L10n.t("setup.agent.usageModified", in: lang)
        }
        let status: SetupStatus
        switch state.status {
        case .current: status = .installed
        case .outdated: status = .outdated
        case .missing: status = .missing
        }
        var parts = [SetupPart(name: L10n.t(Self.hooksPartKey(source), in: lang), file: "~/" + source.settingsPath,
                               status: Self.status(state.hooks))]
        if let relay = state.relay, let path = source.statusLinePath {
            parts.append(SetupPart(name: L10n.t("setup.agent.part.usage", in: lang), file: "~/" + path,
                                   status: Self.status(relay)))
        }
        var result = row(item, status, detail: files, note: note, failure: failure)
        result.parts = parts
        result.removesRelay = state.relay == .current
        return result
    }

    private static func hooksPartKey(_ source: AgentSource) -> String {
        source.supportsApprovals ? "setup.agent.part.hooksApprovals" : "setup.agent.part.hooks"
    }

    private static func status(_ hooks: LocalHooks.State) -> SetupStatus {
        switch hooks {
        case .current: return .installed
        case .outdated: return .outdated
        case .missing: return .missing
        }
    }

    private static func status(_ relay: StatusLineRelay.State) -> SetupStatus {
        switch relay {
        case .current: return .installed
        case .missing: return .missing
        case .modified: return .foreign
        }
    }

    /// `file` under `home`, as the catalogue's paths spell it.
    private static func relative(_ file: URL, to home: URL) -> String {
        let base = home.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// "Hooks: <reason>": the part a refused write stopped in.
    private func failureText(_ failure: AgentIntegration.Failure) -> String {
        let part = failure.part == .hooks ? "setup.agent.part.hooks" : "setup.agent.part.usage"
        return L10n.t("setup.agent.failure", ["part": L10n.t(part, in: lang),
                                              "reason": L10n.t(AppController.failureKey(failure.reason), in: lang)],
                      in: lang)
    }

    /// The machines' part of the attention list moves with their tunnels:
    /// read again only when it would read differently, so the settings
    /// window's refresh reads no file while nothing changed.
    func reloadIfMachinesChanged() {
        let shown = attention.filter {
            switch $0 {
            case .machineUnreachable, .machineNeedsPassword: return true
            default: return false
            }
        }
        let now = host.unreachableMachines().map(SetupAttention.machineUnreachable)
            + host.machinesNeedingPassword().map(SetupAttention.machineNeedsPassword)
        if shown != now { reload() }
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
        case .agent(let source): return agentConsent(source, action)
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

    /// One line per file the press changes, naming only the parts that
    /// change there; and, when the usage line goes in, that the user's
    /// status line is wrapped (R3.4).
    private func agentConsent(_ source: AgentSource, _ action: SetupAction) -> [String] {
        guard let state = agentStates[source] else { return [] }
        var files: [(file: String, what: [String])] = []
        func add(_ file: String, _ key: String) {
            let what = L10n.t(key, in: lang)
            if let index = files.firstIndex(where: { $0.file == file }) {
                files[index].what.append(what)
            } else {
                files.append((file, [what]))
            }
        }
        let hooksFile = "~/" + source.settingsPath
        let relayFile = source.statusLinePath.map { "~/" + $0 }
        if action.installs {
            if state.hooks != .current { add(hooksFile, "setup.consent.what.hooks") }
            if state.installsRelay, let relayFile { add(relayFile, "setup.consent.what.usage") }
        } else {
            if state.hooks != .missing { add(hooksFile, "setup.consent.what.hooks.remove") }
            if state.relay == .current, let relayFile { add(relayFile, "setup.consent.what.usage.remove") }
        }
        var lines = files.map {
            L10n.t("setup.consent.line", ["file": $0.file,
                                          "what": $0.what.joined(separator: L10n.t("setup.consent.and", in: lang))],
                   in: lang)
        }
        if action.installs && state.installsRelay { lines.append(L10n.t("setup.consent.wraps", in: lang)) }
        return lines
    }

    /// The usage line's own "Remove": its file alone.
    func relayRemovalConsent(_ source: AgentSource) -> [String] {
        guard let path = source.statusLinePath else { return [] }
        return [L10n.t("setup.consent.line", ["file": "~/" + path,
                                              "what": L10n.t("setup.consent.what.usage.remove", in: lang)], in: lang)]
    }

    /// The queued items one press would install: each row still missing or
    /// old, not being set up by hand. `only` is one step's share of the
    /// queue: the setup's "Install" and "Finish" each write their own.
    func queuedWrites(only items: Set<SetupItem> = Set(SetupItem.allCases)) -> [SetupItem] {
        rows.filter { queued.contains($0.item) && items.contains($0.item) && $0.item != manualOpen }
            .filter { $0.action == .install || $0.action == .update }
            .map(\.item)
    }

    /// The queue's consent: the queued items' files and nothing else, each
    /// line once, the files first and the status line's wrapping under them.
    var queueConsent: [String] { queueConsent() }

    func queueConsent(only items: Set<SetupItem> = Set(SetupItem.allCases)) -> [String] {
        var lines: [String] = []
        for item in queuedWrites(only: items) {
            for line in consent(item, .install) where !lines.contains(line) { lines.append(line) }
        }
        let wraps = L10n.t("setup.consent.wraps", in: lang)
        return lines.filter { $0 != wraps } + lines.filter { $0 == wraps }
    }

    /// Whether a line about the `.evlat.bak` copy belongs under the consent:
    /// only a settings file is backed up.
    func backsUp(_ items: [SetupItem]) -> Bool {
        items.contains { $0.agent != nil }
    }

    // MARK: - Writing

    /// The row's button: the action its status offers, then a fresh read.
    func perform(_ item: SetupItem) {
        guard let action = row(item)?.action else { return }
        write(item, action)
        reload()
    }

    /// The card's "Remove the usage line": the relay alone, then a fresh
    /// read. The card then reads "needs update", which puts it back.
    func removeRelay(_ source: AgentSource) {
        guard host.home() != nil, row(.agent(source))?.removesRelay == true else { return }
        host.removeUsageRelay(source)
        reload()
    }

    /// The setup's one press: every queued write (of `items`), then a fresh
    /// read.
    func applyQueue(only items: Set<SetupItem> = Set(SetupItem.allCases)) {
        for item in queuedWrites(only: items) { write(item, .install) }
        reload()
    }

    private func write(_ item: SetupItem, _ action: SetupAction) {
        // The login item is not a file; everything else needs a home.
        guard item == .loginItem || host.home() != nil else { return }
        switch item {
        case .agent(let source): host.setAgent(source, action.installs)
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
    /// file — this Mac's, so Claude's include the approval hook, which a
    /// server's (`RemoteSettings.manual`) never do — and, where the usage
    /// line is a part, its `statusLine`; or the link's `ln -s` line.
    func manual(_ item: SetupItem) -> SetupManual? {
        switch item {
        case .agent(let source):
            // An agent whose file has a shape of its own names its own way
            // out (`setup.manual.remove.<agent>`); the rest share one.
            let own = "setup.manual.remove.\(source.rawValue)"
            var removal = L10n.catalog.tables[Catalog.source]?[own] != nil
                ? L10n.t(own, in: lang)
                : L10n.t("setup.manual.remove.hooks", ["marker": RemoteSettings.manual.marker], in: lang)
            let relay = agentStates[source]?.relay != nil ? RemoteSettings.Manual.statusLine(for: source) : nil
            if relay != nil { removal += " " + L10n.t("setup.manual.remove.usage", in: lang) }
            return SetupManual(text: LocalHooks.manual(for: source), wrapping: relay?.wrapping, removal: removal,
                               statusLine: relay?.text)
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
        case .usageModified(let source):
            return L10n.t("setup.attention.usageModified", ["source": L10n.t("source.\(source.rawValue)", in: lang)], in: lang)
        case .refused(let item):
            return L10n.t("setup.attention.refused", ["item": L10n.t(item.nameKey, in: lang)], in: lang)
        case .hotKeyUnregistered: return L10n.t("setup.attention.hotKey", in: lang)
        case .machineUnreachable(let name): return L10n.t("setup.attention.machine", ["machine": name], in: lang)
        case .machineNeedsPassword(let name):
            return L10n.t("setup.attention.machinePassword", ["machine": name], in: lang)
        case .commandLinkElsewhere: return L10n.t("setup.attention.commandLink", in: lang)
        }
    }

    /// Every key this file asks the catalogue for (`L10nTests`' pattern).
    static let keys: [String] = SetupItem.allCases.map(\.nameKey)
        + [SetupStatus.installed, .outdated, .missing, .foreign, .unknown, .notFound].map(\.key)
        + [SetupAction.install, .update, .remove].map(\.key)
        + ["setup.command.otherCopy", "setup.command.broken", "setup.command.foreign", "setup.command.notOnPath",
           "setup.command.error.foreign", "setup.command.error.changed", "setup.command.error.nothingToRemove",
           "setup.command.error.unwritable",
           "setup.login.detail", "setup.login.copy", "setup.login.needsApproval", "setup.login.failed",
           "setup.agent.part.hooks", "setup.agent.part.hooksApprovals", "setup.agent.part.usage",
           "setup.agent.details", "setup.agent.removeUsage", "setup.agent.usageModified", "setup.agent.failure",
           "setup.consent.title", "setup.consent.line", "setup.consent.and", "setup.consent.backup",
           "setup.consent.nothing", "setup.consent.wraps",
           "setup.consent.what.hooks", "setup.consent.what.usage", "setup.consent.what.hooks.remove",
           "setup.consent.what.usage.remove",
           "setup.consent.command", "setup.consent.command.replace", "setup.consent.command.broken",
           "setup.consent.command.remove", "setup.consent.login.on", "setup.consent.login.off",
           "setup.manual.open", "setup.manual.copy", "setup.manual.copied", "setup.manual.check",
           "setup.manual.auto", "setup.manual.wrapping",
           "setup.manual.remove.hooks", "setup.manual.remove.antigravity", "setup.manual.remove.usage",
           "setup.manual.remove.command",
           "setup.attention.hooksOutdated", "setup.attention.usageModified", "setup.attention.refused",
           "setup.attention.hotKey", "setup.attention.machine", "setup.attention.machinePassword",
           "setup.attention.commandLink"]
        + [HookSettings.Failure.unreadable, .malformed, .noDirectory, .changedUnderneath, .unwritable]
            .map(AppController.failureKey)
}

/// One row as both windows draw it: name and file, status; the button
/// inside a box that lists what it writes; an agent's parts under "What it
/// writes"; the "by hand" block. Holds no state of its own but "Copied"; the model
/// says what is open.
struct SetupRowView: View {
    let row: SetupRow
    @ObservedObject var model: SetupModel
    /// The setup writes with one press for all rows: its rows draw no
    /// button and no consent of their own.
    var showsButton = true
    /// The detail is a path (monospace), not a sentence.
    var monospaced = true
    /// The setup's switch: whether its one press writes this row. Drawn
    /// while there is something to write and the row is not set up by hand.
    var queued: Binding<Bool>?
    @State private var copied = false
    /// An agent's "What it writes" is open.
    @State private var details = false

    private var lang: String { model.lang }

    var body: some View {
        RowBox {
            HStack(alignment: .center, spacing: 10) {
                RowTitle(name: row.name, detail: row.detail, monospaced: monospaced,
                         code: row.item == .commandLink)
                trailing
            }
            .opacity(row.status == .foreign || row.status == .notFound ? 0.55 : 1)
            if let note = row.note {
                Text(note).font(.system(size: 11.5))
                    .foregroundStyle(row.item.agent != nil ? SettingsPalette.wait : SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let failure = row.failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.wait)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsButton, !row.parts.isEmpty {
                partsPart
            }
            if showsButton, let action = row.action, model.manualOpen != row.item {
                ConsentAction(lines: model.consent(row.item, action), title: L10n.t(action.key, in: lang)) {
                    model.perform(row.item)
                }
            }
            manualPart
        }
    }

    /// The status, or in the setup the switch: a missing row says nothing
    /// there but its switch, one set up by hand that it is waiting.
    @ViewBuilder private var trailing: some View {
        if queued != nil, model.manualOpen == row.item {
            Text(L10n.t("setup.flow.manual.waiting", in: lang))
                .font(.system(size: 12)).foregroundStyle(SettingsPalette.wait).fixedSize()
        } else if let queued, row.action?.installs == true {
            if row.status != .missing {
                StatusText(status: row.status, text: L10n.t(row.status.key, in: lang))
            }
            Toggle("", isOn: queued)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(row.name)
        } else {
            StatusText(status: row.status, text: L10n.t(row.status.key, in: lang))
        }
    }

    /// "What it writes": each part with its file and state, and the usage
    /// line's own "Remove" while it is Evlat's (R3.4).
    @ViewBuilder private var partsPart: some View {
        Button((details ? "▾ " : "▸ ") + L10n.t("setup.agent.details", in: lang)) { details.toggle() }
            .buttonStyle(LinkButtonStyle())
        if details {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(row.parts, id: \.name) { part in
                    HStack(spacing: 10) {
                        RowTitle(name: part.name, detail: part.file, monospaced: true)
                        StatusText(status: part.status, text: L10n.t(part.status.key, in: lang))
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.consent))
            if row.removesRelay, let source = row.item.agent {
                ConsentAction(lines: model.relayRemovalConsent(source),
                              title: L10n.t("setup.agent.removeUsage", in: lang)) {
                    model.removeRelay(source)
                }
            }
        }
    }

    @ViewBuilder private var manualPart: some View {
        if let manual = model.manual(row.item), row.status != .installed, row.status != .foreign,
           row.status != .notFound {
            if model.manualOpen == row.item {
                ManualBox(text: manual.text, footnote: manual.removal) {
                    Button(L10n.t(copied ? "setup.manual.copied" : "setup.manual.copy", in: lang)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manual.text, forType: .string)
                        copied = true
                    }
                    .buttonStyle(SmallButtonStyle())
                    Button(L10n.t("setup.manual.check", in: lang)) { model.check() }
                        .buttonStyle(SmallButtonStyle())
                    Button(L10n.t("setup.manual.auto", in: lang)) { model.toggleManual(row.item) }
                        .buttonStyle(LinkButtonStyle())
                }
                if let statusLine = manual.statusLine {
                    ManualBox(lead: L10n.t("setup.agent.part.usage", in: lang), text: statusLine, maxHeight: 60) {
                        EmptyView()
                    }
                }
                if let wrapping = manual.wrapping {
                    ManualBox(lead: L10n.t("setup.manual.wrapping", in: lang), text: wrapping, maxHeight: 60) {
                        EmptyView()
                    }
                }
            } else {
                Button(L10n.t("setup.manual.open", in: lang)) { copied = false; model.toggleManual(row.item) }
                    .buttonStyle(LinkButtonStyle())
            }
        }
    }
}
