import AppKit
import Carbon.HIToolbox
import SwiftUI
import EvlatCore

/// The balloon's window: a panel beside the mascot (`BesidePanel`, which
/// holds what it shares with the setup — taking the keyboard without making
/// Evlat the active app).
///
/// It closes on Esc, on losing the keyboard (a click elsewhere), and on the
/// controller's word (the mascot clicked again, the shortcut, a new edge).
/// Built once and ordered out between uses.
final class ChatPanel: BesidePanel {
    /// The balloon wants to close: Esc, or the keyboard went elsewhere. The
    /// controller closes it, so every way out passes one place.
    var onClose: (() -> Void)?
    /// Files dropped on the balloon: added to the next prompt.
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
    /// The tail's middle, down from the balloon's top: level with the
    /// mascot's eyes.
    static let tailCenter: CGFloat = 24
    /// The tallest the balloon grows; its window is this tall, transparent
    /// under a shorter balloon, so it never resizes while a reply streams.
    static let maxBalloonHeight: CGFloat = 420

    static let size = CGSize(width: outerMargin + balloonWidth + tailDepth + barSideMargin,
                             height: outerMargin + maxBalloonHeight + outerMargin)

    init(content: some View) {
        drop = ChatDropView(frame: NSRect(origin: .zero, size: Self.size))
        // The content and, over it, the drop layer (`ChatDropView`).
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        for layer in [Self.hosting(content), drop] as [NSView] {
            layer.frame = container.bounds
            layer.autoresizingMask = [.width, .height]
            container.addSubview(layer)
        }
        super.init(size: Self.size, content: container)
    }

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
        keyWentElsewhere()
    }

    override func keyWentElsewhere() {
        if isVisible { onClose?() }
    }

    override func origin(barFrame: NSRect, edge: BarPanel.Edge, visible: NSRect) -> NSPoint {
        Self.origin(barFrame: barFrame, edge: edge, size: frame.size, visible: visible)
    }

    /// Where the balloon's window goes: its tail's tip `gapToBar` in from the
    /// drawn bar's inner edge (the bar's width, not its window's), its tail
    /// level with the mascot's eyes (`AppController.gazeAnchor`). The top is
    /// held under the menu bar — only a bar whose head is within a tail's
    /// length of it, which the centred bar never is; the tail then points a
    /// little below the eyes. The left is the right's mirror.
    static func origin(barFrame: NSRect, edge: BarPanel.Edge, size: CGSize, visible: NSRect) -> NSPoint {
        let eyes = AppController.gazeAnchor(frame: barFrame, edge: edge).y
        let top = min(eyes + tailCenter, visible.maxY) + outerMargin
        return NSPoint(x: x(barFrame: barFrame, edge: edge, width: size.width), y: top - size.height)
    }
}

/// Files dropped on the balloon: the open balloon takes
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
