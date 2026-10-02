import Foundation
import EvlatCore

/// How much a chat's turn does without asking: the
/// value of `claude -p --permission-mode`, chosen per chat in the balloon.
///
/// Four of Claude Code's modes and no more. `dontAsk` is not here on
/// purpose: it denies what would ask, so it never leaves the user a card
/// to press.
///
/// In every mode the turn still carries Evlat's own `permissions.ask`
/// rules (`PermissionHook.askRules`): what cannot be undone asks, in auto
/// mode too (documented: an explicit ask rule prompts "even in auto mode"),
/// and in bypass mode too (measured on 2.1.284: `rm` under an ask rule
/// reached the permission hook; a plain command ran unasked).
enum PermissionMode: String, CaseIterable, Codable, Equatable {
    /// Manual: Claude asks before editing files or running commands. Its
    /// CLI value is `default` on every version (`manual` is only an alias
    /// from 2.1.200 on).
    case ask = "default"
    /// A classifier reviews each action instead of the user; what it blocks
    /// is denied, not asked (`permission-modes`, "When auto mode falls back").
    case auto
    /// File edits in the working folder go through; commands still ask.
    case acceptEdits
    /// Every other check is skipped: `--dangerously-skip-permissions` by
    /// its mode name. Only the ask rules above still ask, and they match a
    /// command's first words: `find -delete` or `git clean` runs unasked.
    /// The shell asks the user before it is picked (`asksBeforePicking`),
    /// for one chat: it is never a default (`mayBeDefault`).
    case bypass = "bypassPermissions"

    /// A new chat's mode when nothing was chosen.
    static let standard: PermissionMode = .auto

    /// The new chats' defaults Settings and Setup list, the recommended one
    /// first. Bypass is not among them (`mayBeDefault`).
    static let offered: [PermissionMode] = [.auto, .acceptEdits, .ask]

    /// Picking it takes the user's explicit yes, every time it is switched
    /// on: nothing but the ask rules stands between Claude and the machine.
    var asksBeforePicking: Bool { self == .bypass }

    /// Whether it may be the new chats' mode. Bypass is not: one yes in one
    /// chat would otherwise start every later chat — after a restart too —
    /// with nothing but the ask rules, and no question.
    var mayBeDefault: Bool { self != .bypass }

    /// A stored value read back; anything else — an old file, a mode this
    /// build does not offer — is `nil`, and the caller's default applies.
    init?(stored: String?) {
        guard let stored, let mode = PermissionMode(rawValue: stored) else { return nil }
        self = mode
    }
}

extension PermissionMode {
    /// The mode as the bubble sees it: its CLI value is its id, so the
    /// index and the defaults store what they always stored.
    var chatMode: ChatMode {
        ChatMode(id: rawValue, nameKey: nameKey, asksBeforePicking: asksBeforePicking, mayBeDefault: mayBeDefault,
                 // Only auto mode judges on its own; what its classifier
                 // turns down would come back as a card in Ask mode.
                 retryDenialAs: self == .auto ? PermissionMode.ask.rawValue : nil)
    }

    /// Each mode's name. A switch, so a new mode does not compile without one.
    var nameKey: String {
        switch self {
        case .ask: return "chat.mode.ask"
        case .auto: return "chat.mode.auto"
        case .acceptEdits: return "chat.mode.acceptEdits"
        case .bypass: return "chat.mode.bypass"
        }
    }
}
