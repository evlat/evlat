import AppKit
import EvlatCore
import EvlatAgents

/// The one question a mode that asks before it is picked (bypass, full
/// access) asks before it is switched on, from the balloon's mode menu
/// (`AppController.mayPick`). Its title, message and button are the mode's
/// own (`<nameKey>.confirm.*`): each agent's says what it gives up.
///
/// Cancel is the default button: a hasty Return keeps the safeguards, and
/// only a deliberate click on the red button removes them.
enum BypassConfirmation {
    /// The one button every mode's question shares.
    static let cancelKey = "chat.mode.bypass.confirm.cancel"

    static func keys(_ mode: ChatMode) -> [String] {
        ["title", "message", "confirm"].map { mode.nameKey + ".confirm." + $0 }
    }

    /// Every backend's questions, and the shared button.
    static let keys = Agents.chatBackends.flatMap(\.modes).filter(\.asksBeforePicking).flatMap(keys) + [cancelKey]

    @MainActor
    static func run(_ mode: ChatMode) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.t(mode.nameKey + ".confirm.title")
        alert.informativeText = L10n.t(mode.nameKey + ".confirm.message")
        alert.addButton(withTitle: L10n.t(cancelKey))
        let confirm = alert.addButton(withTitle: L10n.t(mode.nameKey + ".confirm.confirm"))
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
