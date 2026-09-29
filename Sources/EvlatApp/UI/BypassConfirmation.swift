import AppKit
import EvlatCore

/// The one question bypass mode asks before it is switched on, from the
/// balloon's mode menu, Settings or Setup (`AppController.mayPick`).
///
/// Cancel is the default button: a hasty Return keeps the safeguards, and
/// only a deliberate click on the red button removes them.
enum BypassConfirmation {
    static let keys = ["chat.mode.bypass.confirm.title", "chat.mode.bypass.confirm.message",
                       "chat.mode.bypass.confirm.confirm", "chat.mode.bypass.confirm.cancel"]

    @MainActor
    static func run() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.t("chat.mode.bypass.confirm.title")
        alert.informativeText = L10n.t("chat.mode.bypass.confirm.message")
        alert.addButton(withTitle: L10n.t("chat.mode.bypass.confirm.cancel"))
        let confirm = alert.addButton(withTitle: L10n.t("chat.mode.bypass.confirm.confirm"))
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
