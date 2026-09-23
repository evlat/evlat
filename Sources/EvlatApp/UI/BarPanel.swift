import AppKit
import SwiftUI

/// The bar window: docked to a screen edge, never steals focus.
///
/// Ported from v1's `PetWindow`; every setting there had a reason and the
/// reasons still hold. The one deliberate difference is `level`: v1 uses
/// `.floating` because the mascot was a figure in the corner that must not
/// cover menus. The bar behaves like a **system strip**, so it sits one level
/// higher.
public final class BarPanel: NSPanel {
    /// Which edge the bar is docked to. Only `right` is used today; the
    /// abstraction that draws all four with one code path is `003`'s work.
    public enum Edge: Sendable { case right, left, top, bottom }

    public let edge: Edge
    /// The two sizes the bar takes. The panel is their only owner: the
    /// hosting view never resizes the window (see `sizingOptions` below).
    /// Their length along the docked edge follows the content (`setLength`).
    public private(set) var collapsedSize: CGSize
    public private(set) var expandedSize: CGSize
    /// The length the bar's position is laid out for. The bar's head (the
    /// mascot's end) sits where a bar of this length, centred on the edge,
    /// would start, and the body hangs from it: the length changes with the
    /// content, the head does not move. `nil` centres the bar as it is.
    public let anchorLength: CGFloat?
    public private(set) var isExpanded = false

    /// Enter, exit and move over the visible bar. The hover's timing is not
    /// decided here; this only reports where the cursor is.
    public var onPointer: ((BarHostingView.Pointer) -> Void)? {
        get { hosting.onPointer }
        set { hosting.onPointer = newValue }
    }

    private let hosting: BarHostingView

    /// - Parameter trackingInset: the transparent margin on the bar's inner
    ///   side (the shadow gutter). The cursor over it sees nothing, so it is
    ///   left out of the hover area.
    public init(edge: Edge = .right, size: CGSize, expandedSize: CGSize? = nil,
                anchorLength: CGFloat? = nil,
                trackingInset: CGFloat = 0, content: some View) {
        self.edge = edge
        self.collapsedSize = size
        self.expandedSize = expandedSize ?? size
        self.anchorLength = anchorLength
        self.hosting = BarHostingView(rootView: AnyView(content))
        hosting.edge = edge
        hosting.trackingInset = trackingInset
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   // .nonactivatingPanel: clicking the bar does not bring Evlat
                   // forward, so the user's terminal keeps focus. Not negotiable
                   // for a bar — a strip that steals focus kills the product.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The bar must not vanish when Evlat goes to the background: staying
        // visible is its whole job.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden

        // This class is the sole owner of the window size. With the default
        // sizingOptions `NSHostingView` resizes the window to fit its content
        // and AppKit pins that to the TOP-LEFT corner — measured in v1 (bottom
        // 96→51, top unchanged). A bar that unfolds leftward on hover hits the
        // same wall.
        hosting.sizingOptions = []
        contentView = hosting

        reposition()
    }

    /// Focus never reaches this window. `.nonactivatingPanel` alone is not
    /// enough; with `canBecomeKey` left open the panel can still take key focus.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// `visibleFrame` along the docked axis (above the Dock, below the menu
    /// bar), the full `frame` along the other one. The second half is
    /// deliberate: centring off `visibleFrame` would make the bar shift
    /// whenever the Dock appears or hides.
    public func reposition(on screen: NSScreen? = nil) {
        guard let screen = screen ?? self.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        let full = screen.frame
        // The size it has now, not the one it was built with: a screen
        // change while the bar is open keeps it open.
        let size = frame.size
        let origin: NSPoint

        // The head: the top of a vertical bar, the leading end of a
        // horizontal one, placed as if the bar were `anchorLength` long.
        let vertical = (anchorLength ?? size.height) / 2
        let horizontal = (anchorLength ?? size.width) / 2
        switch edge {
        case .right:
            origin = NSPoint(x: usable.maxX - size.width,
                             y: full.midY + vertical - size.height)
        case .left:
            origin = NSPoint(x: usable.minX,
                             y: full.midY + vertical - size.height)
        case .top:
            origin = NSPoint(x: full.midX - horizontal,
                             y: usable.maxY - size.height)
        case .bottom:
            origin = NSPoint(x: full.midX - horizontal,
                             y: usable.minY)
        }
        setFrameOrigin(origin)
    }

    /// Opens or closes the bar by resizing the window, **pinning the docked
    /// edge**: a right-docked bar grows leftward, into the screen, and its
    /// `maxX` — which the mascot, the rings and the gaze anchor are all laid
    /// out from — does not move. Pinned by construction from the current
    /// frame, not re-derived from the screen, so an open bar never jumps.
    public func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        let size = expanded ? expandedSize : collapsedSize
        setFrame(Self.frame(frame, resizedTo: size, pinning: edge), display: true)
    }

    /// Fits the bar's length along the docked edge to its content. The head
    /// stays where it is — the mascot and the gaze anchor are laid out from
    /// it — and the far end moves. Animated so the body slides rather than
    /// jumps when a session arrives or leaves.
    public func setLength(_ length: CGFloat, animated: Bool = true) {
        let vertical = edge == .right || edge == .left
        let current = vertical ? collapsedSize.height : collapsedSize.width
        guard abs(current - length) > 0.5 else { return }
        if vertical {
            collapsedSize.height = length
            expandedSize.height = length
        } else {
            collapsedSize.width = length
            expandedSize.width = length
        }
        let size = isExpanded ? expandedSize : collapsedSize
        let next = Self.frame(frame, lengthenedTo: size, keepingHeadOf: edge)
        guard animated else { return setFrame(next, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(next, display: true)
        }
    }

    /// The frame after a length change that keeps the bar's head: the top of
    /// a vertical bar, the leading end of a horizontal one.
    nonisolated static func frame(_ old: NSRect, lengthenedTo size: CGSize,
                                  keepingHeadOf edge: Edge) -> NSRect {
        switch edge {
        case .right: return NSRect(x: old.maxX - size.width, y: old.maxY - size.height,
                                   width: size.width, height: size.height)
        case .left: return NSRect(x: old.minX, y: old.maxY - size.height,
                                  width: size.width, height: size.height)
        case .top: return NSRect(x: old.minX, y: old.maxY - size.height,
                                 width: size.width, height: size.height)
        case .bottom: return NSRect(x: old.minX, y: old.minY,
                                    width: size.width, height: size.height)
        }
    }

    /// The frame after a resize that keeps the docked edge where it is and the
    /// bar centred along it.
    nonisolated static func frame(_ old: NSRect, resizedTo size: CGSize, pinning edge: Edge) -> NSRect {
        let origin: NSPoint
        switch edge {
        case .right: origin = NSPoint(x: old.maxX - size.width, y: old.midY - size.height / 2)
        case .left: origin = NSPoint(x: old.minX, y: old.midY - size.height / 2)
        case .top: origin = NSPoint(x: old.midX - size.width / 2, y: old.maxY - size.height)
        case .bottom: origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        }
        return NSRect(origin: origin, size: size)
    }

    /// How much of the window, from the docked edge, is bar the cursor can be
    /// over. The window may be wider than what is drawn — the open body's room
    /// is kept even while it is closed — and the transparent rest must not
    /// count as hovering. `nil`: the whole window minus the shadow gutter.
    public func setVisibleWidth(_ width: CGFloat?) {
        hosting.visibleWidth = width
    }

    /// Not `orderFront`: the bar must appear even when the app is inactive.
    public func show() {
        reposition()
        orderFrontRegardless()
    }
}

/// The panel's content view: SwiftUI, plus the one AppKit piece hover needs.
///
/// **Hover is noticed here, not with `.onHover`.** The app is `.accessory` and
/// is never the active app, and the panel never becomes key; SwiftUI's hover
/// tracking is not documented to fire in that situation and nothing here
/// proves it does. An `NSTrackingArea` with `.activeAlways` is documented to.
/// It also delivers moves over the bar, which the global gaze monitor never
/// sees — that monitor only hears events bound for other applications.
public final class BarHostingView: NSHostingView<AnyView> {
    public enum Pointer {
        case entered
        case exited
        /// A move over the bar, in screen coordinates — the space the gaze
        /// monitor reads.
        case moved(CGPoint)
    }

    /// The tracking area's owner. A separate object so the hosting view's own
    /// mouse handling (SwiftUI keeps tracking areas of its own) never has to
    /// tell its events from ours.
    final class PointerRelay: NSResponder {
        var handler: ((Pointer) -> Void)?
        override func mouseEntered(with event: NSEvent) { handler?(.entered) }
        override func mouseExited(with event: NSEvent) { handler?(.exited) }
        override func mouseMoved(with event: NSEvent) { handler?(.moved(NSEvent.mouseLocation)) }
    }

    var trackingInset: CGFloat = 0 {
        didSet { updateTrackingAreas() }
    }
    /// The drawn bar's width from the docked edge, when it is less than the
    /// window's; see `BarPanel.setVisibleWidth`.
    var visibleWidth: CGFloat? {
        didSet { if visibleWidth != oldValue { updateTrackingAreas() } }
    }
    /// Which side the gutter is on: the one away from the docked edge.
    var edge: BarPanel.Edge = .right {
        didSet { updateTrackingAreas() }
    }

    /// The bar's own rectangle: the bounds minus the gutter on the inner side,
    /// or — when the bar is narrower than the window — its visible width from
    /// the docked edge.
    nonisolated static func trackingRect(in bounds: NSRect, inset: CGFloat,
                                         visible: CGFloat? = nil,
                                         edge: BarPanel.Edge) -> NSRect {
        if let visible {
            switch edge {
            case .right:
                return NSRect(x: bounds.maxX - visible, y: bounds.minY,
                              width: visible, height: bounds.height)
            case .left:
                return NSRect(x: bounds.minX, y: bounds.minY, width: visible, height: bounds.height)
            case .top, .bottom:
                break  // no horizontal bar is built yet; fall back to the inset
            }
        }
        var rect = bounds
        switch edge {
        case .right:
            rect.origin.x += inset
            rect.size.width -= inset
        case .left:
            rect.size.width -= inset
        // A hosting view is flipped (y grows downward), so the top edge is
        // at minY and its inner side at maxY; the bottom edge the reverse.
        // No top or bottom bar is built yet, so this half is unexercised.
        case .top:
            rect.size.height -= inset
        case .bottom:
            rect.origin.y += inset
            rect.size.height -= inset
        }
        rect.size.width = max(0, rect.width)
        rect.size.height = max(0, rect.height)
        return rect
    }

    var onPointer: ((Pointer) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    private let relay = PointerRelay()
    private var area: NSTrackingArea?

    /// Rebuilt on every call, which AppKit makes whenever the view's geometry
    /// changes. An area installed once would keep the collapsed size: the
    /// strip revealed by opening would lie outside it, the cursor moving onto
    /// it would read as leaving, and the bar would fold under the cursor.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let rect = Self.trackingRect(in: bounds, inset: trackingInset,
                                     visible: visibleWidth, edge: edge)
        let next = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: relay, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
}
