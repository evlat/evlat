import Foundation

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
public enum PermissionMode: String, CaseIterable, Codable, Equatable {
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
    /// its mode name. Only the ask rules above still ask. The shell asks the
    /// user before it is picked (`asksBeforePicking`).
    case bypass = "bypassPermissions"

    /// A new chat's mode when nothing was chosen.
    public static let standard: PermissionMode = .auto

    /// The order Settings and Setup list the modes in: the recommended one
    /// first, the one that skips every check last.
    public static let offered: [PermissionMode] = [.auto, .acceptEdits, .ask, .bypass]

    /// Picking it takes the user's explicit yes, every time it is switched
    /// on: nothing but the ask rules stands between Claude and the machine.
    public var asksBeforePicking: Bool { self == .bypass }

    /// A stored value read back; anything else — an old file, a mode this
    /// build does not offer — is `nil`, and the caller's default applies.
    public init?(stored: String?) {
        guard let stored, let mode = PermissionMode(rawValue: stored) else { return nil }
        self = mode
    }
}
