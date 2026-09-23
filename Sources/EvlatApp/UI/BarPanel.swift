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
    /// The two sizes the window can take. The panel is their only owner: the
    /// hosting view never resizes the window (see `sizingOptions` below). The
    /// app builds both at the envelope's size and never resizes (`005`); the
    /// body's length along the edge is drawn, not the window's.
    public private(set) var collapsedSize: CGSize
    public private(set) var expandedSize: CGSize
    /// The length the bar's position is laid out for. The bar's head (the
    /// mascot's end) sits where a bar of this length, centred on the edge,
    /// would start, and the window hangs from it: a window longer than this
    /// reaches further past the far end, the head does not move. `nil` centres
    /// the window as it is.
    public let anchorLength: CGFloat?
    public private(set) var isExpanded = false

    /// Enter, exit and move over the visible bar. The hover's timing is not
    /// decided here; this only reports where the cursor is.
    public var onPointer: ((BarHostingView.Pointer) -> Void)? {
        get { hosting.onPointer }
        set { hosting.onPointer = newValue }
    }

    /// A click on the bar, in the content view's (flipped) coordinates.
    /// `true` means it was taken; otherwise SwiftUI gets it.
    public var onClick: ((CGPoint) -> Bool)? {
        get { hosting.onClick }
        set { hosting.onClick = newValue }
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

    /// How much of the window, from the head, is drawn body. The window is
    /// longer than the bar — the card's room hangs below it — and the cursor
    /// under a short bar is over nothing. `nil`: the whole length.
    public func setVisibleLength(_ length: CGFloat?) {
        hosting.visibleLength = length
    }

    /// The card's rectangle, in the content view's coordinates, while it is
    /// drawn; `nil` otherwise. The second hover area: the cursor on the card
    /// is still on the bar.
    public func setCardRect(_ rect: NSRect?) {
        hosting.cardRect = rect
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

    /// The drawn parts the cursor can be over, one tracking area each.
    enum Region: String {
        case body, card
    }

    /// The tracking areas' owner. A separate object so the hosting view's own
    /// mouse handling (SwiftUI keeps tracking areas of its own) never has to
    /// tell its events from ours.
    ///
    /// **Two areas, one "inside".** The body and the card are separate
    /// rectangles — one rectangle around both would take in the transparent
    /// corner under a short bar — but hover asks one question. Crossing from
    /// one onto the other is not a leave; leaving the last one is.
    final class PointerRelay: NSResponder {
        var handler: ((Pointer) -> Void)?
        private var inside: Set<Region> = []

        override func mouseEntered(with event: NSEvent) {
            entered(Self.region(of: event))
        }
        override func mouseExited(with event: NSEvent) {
            exited(Self.region(of: event))
        }
        override func mouseMoved(with event: NSEvent) { handler?(.moved(NSEvent.mouseLocation)) }

        private static func region(of event: NSEvent) -> Region {
            (event.trackingArea?.userInfo?[BarHostingView.regionKey] as? String)
                .flatMap(Region.init(rawValue:)) ?? .body
        }

        func entered(_ region: Region) {
            let wasOutside = inside.isEmpty
            inside.insert(region)
            if wasOutside { handler?(.entered) }
        }

        /// Reported even without a matching enter: an area installed under
        /// the cursor never says "entered", and swallowing its exit would
        /// leave the bar open with nobody over it.
        func exited(_ region: Region) {
            inside.remove(region)
            if inside.isEmpty { handler?(.exited) }
        }

        /// Areas that are gone send no exit. Forgetting one the cursor was in
        /// is leaving it, if that was the last.
        func keep(_ regions: Set<Region>) {
            let wasInside = !inside.isEmpty
            inside.formIntersection(regions)
            if wasInside, inside.isEmpty { handler?(.exited) }
        }
    }

    static let regionKey = "region"

    var trackingInset: CGFloat = 0 {
        didSet { updateTrackingAreas() }
    }
    /// The drawn bar's width from the docked edge, when it is less than the
    /// window's; see `BarPanel.setVisibleWidth`.
    var visibleWidth: CGFloat? {
        didSet { if visibleWidth != oldValue { updateTrackingAreas() } }
    }
    /// The drawn body's length from the head; see `BarPanel.setVisibleLength`.
    var visibleLength: CGFloat? {
        didSet { if visibleLength != oldValue { updateTrackingAreas() } }
    }
    /// See `BarPanel.setCardRect`.
    var cardRect: NSRect? {
        didSet { if cardRect != oldValue { updateTrackingAreas() } }
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

    /// Both hover areas: the body — `trackingRect`'s width, and along the
    /// edge only as long as it is drawn, from the head — and the card when
    /// there is one. The head is at the top of a vertical bar; in a flipped
    /// view (a hosting view is) that is `minY`.
    nonisolated static func trackingRects(in bounds: NSRect, inset: CGFloat,
                                          visibleWidth: CGFloat? = nil,
                                          visibleLength: CGFloat?, card: NSRect?,
                                          flipped: Bool,
                                          edge: BarPanel.Edge) -> (body: NSRect, card: NSRect?) {
        var body = trackingRect(in: bounds, inset: inset, visible: visibleWidth, edge: edge)
        if let visibleLength, edge == .right || edge == .left {
            let length = min(max(0, visibleLength), bounds.height)
            body.origin.y = flipped ? bounds.minY : bounds.maxY - length
            body.size.height = length
        }
        return (body, card)
    }

    var onPointer: ((Pointer) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    /// See `BarPanel.onClick`.
    var onClick: ((CGPoint) -> Bool)?

    /// The app is never active, so every click on the bar is a "first" click
    /// — and AppKit swallows a first click into an inactive app's window
    /// unless the view accepts it. Accepting it activates nothing: the panel
    /// is `.nonactivatingPanel` and cannot become key.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks are read from geometry, like the hovered row: the rows are laid
    /// out from constants (`AppController.slotTop`), and one route for both
    /// means a click and a hover can never disagree about which row is where.
    /// A click on no row goes on to SwiftUI.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onClick?(point) == true { return }
        super.mouseDown(with: event)
    }

    private let relay = PointerRelay()
    private var areas: [NSTrackingArea] = []

    /// Rebuilt on every call, which AppKit makes whenever the view's geometry
    /// changes. An area installed once would keep the collapsed size: the
    /// strip revealed by opening would lie outside it, the cursor moving onto
    /// it would read as leaving, and the bar would fold under the cursor.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        areas.forEach(removeTrackingArea)
        let rects = Self.trackingRects(in: bounds, inset: trackingInset,
                                       visibleWidth: visibleWidth, visibleLength: visibleLength,
                                       card: cardRect, flipped: isFlipped, edge: edge)
        var parts: [(Region, NSRect)] = [(.body, rects.body)]
        if let card = rects.card { parts.append((.card, card)) }
        areas = parts.map { region, rect in
            NSTrackingArea(rect: rect,
                           options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                           owner: relay, userInfo: [Self.regionKey: region.rawValue])
        }
        areas.forEach(addTrackingArea)
        // A removed area sends no exit, and a shorter body can leave the
        // cursor outside without one — a session leaving the last row while
        // hovered. What the cursor is in is asked of the new rectangles.
        var kept = Set(parts.map(\.0))
        if let window {
            let cursor = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            kept = Set(parts.filter { $0.1.contains(cursor) }.map(\.0))
        }
        relay.keep(kept)
    }
}
