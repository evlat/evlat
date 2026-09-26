import AppKit
import Carbon.HIToolbox

/// What one key means to the recorder, apart from any window: the
/// shortcut's rules, as a pure function a test calls with a
/// key code and flags.
///
/// Esc cancels; a key with ⌃, ⌥ or ⌘ is taken; ⇧ alone is not a shortcut
/// (it types capitals); ⌘ or ⇧⌘ with a character key is refused (it would
/// take ⌘V or ⌘Q from every app); a combination macOS itself uses
/// (`SystemHotKeys`) is **refused** with a line naming what for — it would
/// register (`noErr`) and still never fire.
enum HotKeyVerdict: Equatable {
    case cancel
    /// A key without ⌃, ⌥ or ⌘.
    case needsModifier
    /// ⌘ or ⇧⌘ with a character key: an app's shortcut (⌘V), refused.
    case appShortcut(HotKeyCombination)
    /// macOS takes this combination: refused, another is waited for.
    case system(HotKeyCombination, id: Int)
    case accept(HotKeyCombination)

    static func classify(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                         system: SystemHotKeys) -> HotKeyVerdict {
        if keyCode == UInt16(kVK_Escape) { return .cancel }
        let modifiers = modifiers.intersection(HotKeyCombination.modifierMask)
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return .needsModifier }
        let combination = HotKeyCombination(keyCode: keyCode, modifiers: modifiers)
        if combination.takesAnAppShortcut { return .appShortcut(combination) }
        if let id = system.conflict(with: combination) { return .system(combination, id: id) }
        return .accept(combination)
    }
}

/// The one shortcut recorder: Settings → Chat's row. The
/// settings window feeds it its keys (`AppKeyWindow.keyInterceptor`) — a
/// window key of Evlat's own, so no Accessibility and no monitor; losing
/// the keyboard cancels.
///
/// The system check sees only what reaches the window: a system shortcut
/// macOS acts on first (⌘Space opens Spotlight) never arrives, and the
/// window then loses the keyboard and the recording is cancelled — nothing
/// is stored either way.
@MainActor
final class HotKeyRecorder: ObservableObject {
    /// What the row says under the shortcut while recording; the words are
    /// the catalogue's.
    enum Line: Equatable {
        /// Waiting for a key.
        case prompt
        case needsModifier
        case appShortcut(HotKeyCombination)
        case system(HotKeyCombination, id: Int)
    }

    @Published private(set) var isRecording = false
    @Published private(set) var line: Line = .prompt
    /// Called before a recording starts (the shortcut is let go, so the
    /// current one can be pressed again) and with its answer — `nil` for a
    /// cancel — once it ends.
    var onStart: () -> Void = {}
    var onFinish: (HotKeyCombination?) -> Void = { _ in }
    private let systemHotKeys: () -> SystemHotKeys
    private var system = SystemHotKeys(entries: [:])

    init(systemHotKeys: @escaping () -> SystemHotKeys = SystemHotKeys.current) {
        self.systemHotKeys = systemHotKeys
    }

    func start() {
        guard !isRecording else { return }
        system = systemHotKeys()
        line = .prompt
        isRecording = true
        onStart()
    }

    /// One key: `true` when it was the recorder's — every key is while it
    /// records, none leaks into a field or the window.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        guard event.type == .keyDown else { return true }
        switch HotKeyVerdict.classify(keyCode: event.keyCode, modifiers: event.modifierFlags, system: system) {
        case .cancel: finish(nil)
        case .needsModifier: line = .needsModifier
        case .appShortcut(let combination): line = .appShortcut(combination)
        case .system(let combination, let id): line = .system(combination, id: id)
        case .accept(let combination): finish(combination)
        }
        return true
    }

    /// Ends without an answer: Vazgeç (Cancel), the window closing or losing
    /// the keyboard.
    func cancel() { finish(nil) }

    private func finish(_ combination: HotKeyCombination?) {
        guard isRecording else { return }
        isRecording = false
        line = .prompt
        onFinish(combination)
    }

    /// The row's line under the shortcut, or `nil` for none.
    func text(in lang: String) -> (String, trouble: Bool)? {
        guard isRecording else { return nil }
        switch line {
        case .prompt: return (L10n.t("hotkey.recorder.hint", in: lang), false)
        case .needsModifier: return (L10n.t("hotkey.recorder.needsModifier", in: lang), true)
        case .appShortcut(let combination):
            return (L10n.t("hotkey.recorder.appShortcut", ["shortcut": combination.title], in: lang), true)
        case .system(let combination, let id):
            return (L10n.t("hotkey.recorder.system",
                           ["shortcut": combination.title,
                            "use": L10n.t(SystemHotKeys.nameKey(id), in: lang)], in: lang), true)
        }
    }
}
