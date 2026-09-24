import AppKit
import Carbon.HIToolbox
import SwiftUI
import EvlatCore

/// The balloon's window (`011`, Karar 7): the one Evlat window that takes the
/// keyboard — and still never makes Evlat the active app.
///
/// `.nonactivatingPanel` with `canBecomeKey` is the Spotlight pattern: the
/// panel becomes key and gets the keys typed, `NSApp.isActive` stays false,
/// and the app in front never falls back. When the balloon goes, the keyboard
/// is that app's again with nothing to hand back. The bar (`BarPanel`) keeps
/// `canBecomeKey == false`; this is a second window, not a relaxed bar.
///
/// It closes on Esc, on losing the keyboard (a click elsewhere), and on the
/// controller's word (the mascot clicked again, the shortcut, a new edge).
/// Built once and ordered out between uses.
final class ChatPanel: NSPanel {
    /// The balloon wants to close: Esc, or the keyboard went elsewhere. The
    /// controller closes it, so every way out passes one place.
    var onClose: (() -> Void)?
    /// Files dropped on the balloon (`011/phase-4`): added to the next prompt.
    var onFiles: (([ChatFolder.Item]) -> Void)? {
        get { drop.onFiles }
        set { drop.onFiles = newValue }
    }
    /// A file drag came over the balloon (`true`) or left it.
    var onDropTarget: ((Bool) -> Void)? {
        get { drop.onTarget }
        set { drop.onTarget = newValue }
    }
    private let drop: ChatDropView

    /// The balloon's own width; the window adds the tail and the shadow's room.
    static let balloonWidth: CGFloat = 320
    /// How far the tail reaches out of the balloon, toward the bar.
    static let tailDepth: CGFloat = 8
    /// The tail's middle, down from the balloon's top: level with the
    /// mascot's eyes.
    static let tailCenter: CGFloat = 24
    /// Between the tail's tip and the drawn bar's inner edge.
    static let gapToBar: CGFloat = 4
    /// Room for the shadow on the three sides away from the bar.
    static let outerMargin: CGFloat = 24
    /// On the bar's side the window stops just past the tail's tip: a wider
    /// margin would lay the window's shadow over the mascot and take the
    /// click meant to close the balloon.
    static let barSideMargin: CGFloat = 2
    /// The tallest the balloon grows; its window is this tall, transparent
    /// under a shorter balloon, so it never resizes while a reply streams.
    static let maxBalloonHeight: CGFloat = 420

    static let size = CGSize(width: outerMargin + balloonWidth + tailDepth + barSideMargin,
                             height: outerMargin + maxBalloonHeight + outerMargin)

    init(content: some View) {
        drop = ChatDropView(frame: NSRect(origin: .zero, size: Self.size))
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   // `.nonactivatingPanel`: taking the keyboard does not bring
                   // Evlat forward (`canBecomeKey` below).
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // The bar's level and spaces: the balloon comes out of it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // The balloon draws its own; the window's would outline the
        // transparent envelope.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(content))
        // The window's size is this class's: see `BarPanel`.
        hosting.sizingOptions = []
        // The content and, over it, the drop layer (`ChatDropView`).
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        for layer in [hosting, drop] as [NSView] {
            layer.frame = container.bounds
            layer.autoresizingMask = [.width, .height]
            container.addSubview(layer)
        }
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc on its way to the text field: taken here, because a field editor
    /// answers Esc with completion rather than passing `cancelOperation`
    /// up. Not while an input method is composing — there Esc is the
    /// composition's.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onClose?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// The keyboard went elsewhere: the user clicked another app or window.
    /// Closing here is safe to re-enter — ordering out resigns key again and
    /// the controller ignores a balloon that is already closed.
    override func resignKey() {
        super.resignKey()
        if isVisible { onClose?() }
    }

    /// Placed and shown with the keyboard: `makeKey` and `orderFrontRegardless`,
    /// never `makeKeyAndOrderFront` with an activation — the app stays where
    /// it is.
    func present(beside bar: NSWindow, edge: BarPanel.Edge) {
        let visible = (bar.screen ?? NSScreen.screens.first)?.visibleFrame ?? bar.frame
        setFrameOrigin(Self.origin(barFrame: bar.frame, edge: edge, size: frame.size, visible: visible))
        orderFrontRegardless()
        makeKey()
    }

    /// Where the balloon's window goes: its tail's tip `gapToBar` in from the
    /// drawn bar's inner edge (the bar's width, not its window's), its tail
    /// level with the mascot's eyes (`AppController.gazeAnchor`). The top is
    /// held under the menu bar — only a bar whose head is within a tail's
    /// length of it, which the centred bar never is; the tail then points a
    /// little below the eyes. The left is the right's mirror.
    static func origin(barFrame: NSRect, edge: BarPanel.Edge, size: CGSize, visible: NSRect) -> NSPoint {
        let tip = edge.x(atInset: AppController.barWidth + gapToBar, in: barFrame)
        let x = edge.isLeft ? tip - barSideMargin : tip + barSideMargin - size.width
        let eyes = AppController.gazeAnchor(frame: barFrame, edge: edge).y
        let top = min(eyes + tailCenter, visible.maxY) + outerMargin
        return NSPoint(x: x, y: top - size.height)
    }
}

/// Files dropped on the balloon (`011/phase-4`): the open balloon takes
/// more. A transparent layer **over** the SwiftUI content, not the hosting
/// view itself: the line's field editor sits deepest under the cursor and
/// registers for text — which a file URL also offers — so it won the drop
/// and typed the path into the line (seen by eye). SwiftUI's text field will
/// not take another field editor (it crashed on one), so the drop is caught
/// above it instead. Clicks pass through (`hitTest` is `nil`); drags do
/// not, because AppKit finds a drag's target by registered type and frame.
/// Event-driven like the bar's: it runs only while a drag is over the window.
final class ChatDropView: NSView {
    var onFiles: (([ChatFolder.Item]) -> Void)?
    var onTarget: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard FileDrop.hasFiles(sender.draggingPasteboard) else { return [] }
        onTarget?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.hasFiles(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTarget?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTarget?(false) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let items = FileDrop.items(from: sender.draggingPasteboard)
        onTarget?(false)
        guard !items.isEmpty else { return false }
        onFiles?(items)
        return true
    }
}
