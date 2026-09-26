import Foundation

/// How much a chat's turn does without asking: the
/// value of `claude -p --permission-mode`, chosen per chat in the balloon.
///
/// Three of Claude Code's modes and no more. `bypassPermissions` and
/// `dontAsk` are not here on purpose: one skips every check, the other
/// denies what would ask — neither leaves the user a card to press.
///
/// In every mode the turn still carries Evlat's own `permissions.ask`
/// rules (`PermissionHook.askRules`): what cannot be undone asks, in auto
/// mode too (documented: an explicit ask rule prompts "even in auto mode").
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

    /// A new chat's mode when nothing was chosen.
    public static let standard: PermissionMode = .auto

    /// A stored value read back; anything else — an old file, a mode this
    /// build does not offer — is `nil`, and the caller's default applies.
    public init?(stored: String?) {
        guard let stored, let mode = PermissionMode(rawValue: stored) else { return nil }
        self = mode
    }
}
