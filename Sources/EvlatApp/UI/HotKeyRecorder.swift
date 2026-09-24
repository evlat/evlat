import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the recorder shows; the words are the catalogue's.
final class HotKeyRecorderModel: ObservableObject {
    enum Line: Equatable {
        /// Waiting for a key.
        case prompt
        /// A key without ⌃, ⌥ or ⌘.
        case needsModifier
        /// ⌘ or ⇧⌘ with a character key: an app's shortcut (⌘V), refused.
        case appShortcut(HotKeyCombination)
        /// macOS takes this combination: refused, another is waited for.
        case system(HotKeyCombination, id: Int)
    }

    @Published var line: Line = .prompt
    @Published var current: String = ""
    var language = L10n.language
}

/// "Change…" of the shortcut's menu (`011`, after `phase-2`): the next key
/// combination pressed becomes the shortcut.
///
/// **No Accessibility:** the keys are read the way the balloon reads its
/// line — a `.nonactivatingPanel` that becomes key (so the app in front
/// stays in front) and a *local* monitor, which sees only the keys this
/// window is given. A global key monitor would need the permission.
///
/// Rules: Esc cancels; a key with ⌃, ⌥ or ⌘ is taken; ⇧ alone is not a
/// shortcut (it types capitals); ⌘ or ⇧⌘ with a character key is refused
/// (it would take ⌘V or ⌘Q from every app); a combination macOS itself uses
/// (`SystemHotKeys`) is **refused** with a line naming what for, and the
/// recorder waits for another — it would register (`noErr`) and still never
/// fire. Losing the keyboard (a click elsewhere) cancels.
///
/// The system check sees only what reaches the recorder: a system shortcut
/// macOS acts on first (⌘Space opens Spotlight) never arrives, and the
/// recorder then loses the keyboard and cancels — nothing is stored either
/// way. The line is for the ones that do arrive (measured: ⌃⌥Space sent to
/// the process).
final class HotKeyRecorder {
    /// The chosen combination, or `nil` for a cancel. Called once per show.
    var onFinish: ((HotKeyCombination?) -> Void)?
    let model = HotKeyRecorderModel()
    let panel: HotKeyRecorderPanel
    private let systemHotKeys: () -> SystemHotKeys
    private var system = SystemHotKeys(entries: [:])
    private var monitor: Any?

    init(systemHotKeys: @escaping () -> SystemHotKeys = SystemHotKeys.current) {
        self.systemHotKeys = systemHotKeys
        panel = HotKeyRecorderPanel(content: HotKeyRecorderView(model: model))
        panel.onResign = { [weak self] in self?.finish(nil) }
    }

    var isRecording: Bool { panel.isVisible }

    /// Beside the bar where the balloon would be, with the keyboard, Evlat
    /// still in the background.
    func show(current: HotKeyCombination, beside bar: NSWindow, edge: BarPanel.Edge, in lang: String) {
        system = systemHotKeys()
        model.language = lang
        model.current = current.title
        model.line = .prompt
        if monitor == nil {
            // Local: the keys sent to this app only, while it has the
            // keyboard — which is while this panel is key.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.handle(event) ? nil : event
            }
        }
        panel.present(beside: bar, edge: edge)
    }

    /// One key: `true` when it was the recorder's (every key is while it
    /// is up — none leaks into another window).
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            finish(nil)
            return true
        }
        guard let combination = HotKeyCombination(event: event) else {
            model.line = .needsModifier
            return true
        }
        if combination.takesAnAppShortcut {
            model.line = .appShortcut(combination)
            return true
        }
        if let id = system.conflict(with: combination) {
            model.line = .system(combination, id: id)
            return true
        }
        finish(combination)
        return true
    }

    /// Closes without an answer; the controller's way to take it down.
    func cancel() { finish(nil) }

    private func finish(_ combination: HotKeyCombination?) {
        guard panel.isVisible else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        onFinish?(combination)
    }
}

/// The recorder's window: the balloon's recipe (`ChatPanel`) — key without
/// activating Evlat — without its tail, drop layer or size.
final class HotKeyRecorderPanel: NSPanel {
    var onResign: (() -> Void)?

    static let size = CGSize(width: 280, height: 150)

    init(content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isVisible { onResign?() }
    }

    /// Where the balloon goes, its top level with the balloon's; `makeKey`
    /// and `orderFrontRegardless`, never an activation.
    func present(beside bar: NSWindow, edge: BarPanel.Edge) {
        let visible = (bar.screen ?? NSScreen.screens.first)?.visibleFrame ?? bar.frame
        setFrameOrigin(Self.origin(barFrame: bar.frame, edge: edge, size: frame.size, visible: visible))
        orderFrontRegardless()
        makeKey()
    }

    /// The balloon's side and its top, without the balloon's shadow margin.
    static func origin(barFrame: NSRect, edge: BarPanel.Edge, size: CGSize, visible: NSRect) -> NSPoint {
        let x = ChatPanel.origin(barFrame: barFrame, edge: edge, size: size, visible: visible).x
        let eyes = AppController.gazeAnchor(frame: barFrame, edge: edge).y
        let top = min(eyes + ChatPanel.tailCenter, visible.maxY)
        return NSPoint(x: x, y: top - size.height)
    }
}

struct HotKeyRecorderView: View {
    @ObservedObject var model: HotKeyRecorderModel

    var body: some View {
        let lang = model.language
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("hotkey.recorder.prompt", in: lang))
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.t("hotkey.recorder.current", ["shortcut": model.current], in: lang))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Group {
                switch model.line {
                case .prompt:
                    Text(L10n.t("hotkey.recorder.hint", in: lang))
                        .foregroundStyle(.secondary)
                case .needsModifier:
                    Text(L10n.t("hotkey.recorder.needsModifier", in: lang))
                        .foregroundStyle(.orange)
                case let .appShortcut(combination):
                    Text(L10n.t("hotkey.recorder.appShortcut", ["shortcut": combination.title], in: lang))
                        .foregroundStyle(.orange)
                case let .system(combination, id):
                    Text(L10n.t("hotkey.recorder.system",
                                ["shortcut": combination.title,
                                 "use": L10n.t(SystemHotKeys.nameKey(id), in: lang)], in: lang))
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: HotKeyRecorderPanel.size.width - 16, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .frame(width: HotKeyRecorderPanel.size.width, height: HotKeyRecorderPanel.size.height, alignment: .top)
    }
}
