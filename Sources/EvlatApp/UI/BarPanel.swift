import AppKit
import SwiftUI
import EvlatCore

/// The bar window: docked to a screen edge, never steals focus.
///
/// Ported from v1's `PetWindow`; every setting there had a reason and the
/// reasons still hold. The one deliberate difference is `level`: v1 uses
/// `.floating` because the mascot was a figure in the corner that must not
/// cover menus. The bar behaves like a **system strip**, so it sits one level
/// higher.
public final class BarPanel: NSPanel {
    /// Which edge the bar is docked to. Right and left are built — the left
    /// is the right's mirror; top and bottom are a design of their own (where
    /// names open and the list scrolls along a horizontal bar) and are not.
    public enum Edge: Sendable { case right, left, top, bottom }

    /// Changed in place (`AppController.dock`): the same panel moves, so
    /// everything wired to it at launch — hover, the gaze anchor, the screen
    /// observer — stays wired. The focus settings above do not change.
    public var edge: Edge {
        didSet {
            hosting.edge = edge
            reposition()
        }
    }
    /// The screen the bar is pinned to, by `BarDisplay.id`; `nil` is the
    /// main screen. Changed in place like `edge`. A pinned screen that is
    /// not connected leaves the bar on the main one, and the value stays:
    /// the next `reposition` after the screen returns puts the bar back.
    public var display: String? {
        didSet {
            if display != oldValue { reposition() }
        }
    }
    /// The two sizes the window can take. The panel is their only owner: the
    /// hosting view never resizes the window (see `sizingOptions` below). The
    /// app builds both at the envelope's size and never resizes; the
    /// body's length along the edge is drawn, not the window's.
    public private(set) var collapsedSize: CGSize
    public private(set) var expandedSize: CGSize
    /// The length the bar's position is laid out for. The bar's head (the
    /// mascot's end) sits where a bar of this length, centred on the edge,
    /// would start, and the window hangs from it: a window longer than this
    /// reaches further past the far end, the head does not move. `nil` centres
    /// the window as it is.
    public let anchorLength: CGFloat?
    /// Transparent room above the head, inside the window: where a tall
    /// card rises so it stays on the screen (`AppController.headroom`).
    /// The head is placed where it was; the window's top is this far above.
    public let headroom: CGFloat
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

    /// A scroll over the bar: where, in the content view's (flipped)
    /// coordinates, `scrollingDeltaY`, and whether it is in points (a
    /// trackpad) or lines (a notched wheel). `true` means it was taken;
    /// otherwise SwiftUI gets it.
    public var onScroll: ((CGPoint, CGFloat, Bool) -> Bool)? {
        get { hosting.onScroll }
        set { hosting.onScroll = newValue }
    }

    /// A right click (or ctrl-click) on the bar, in the content view's
    /// (flipped) coordinates: the menu to open there, or `nil` for none.
    public var onMenu: ((CGPoint) -> NSMenu?)? {
        get { hosting.onMenu }
        set { hosting.onMenu = newValue }
    }

    /// A file drag over the bar, in the content view's
    /// (flipped) coordinates. `true` takes it; see `BarHostingView.Drag`.
    public var onDrag: ((BarHostingView.Drag) -> Bool)? {
        get { hosting.onDrag }
        set { hosting.onDrag = newValue }
    }

    private let hosting: BarHostingView

    /// - Parameter trackingInset: the transparent margin on the bar's inner
    ///   side (the shadow gutter). The cursor over it sees nothing, so it is
    ///   left out of the hover area.
    public init(edge: Edge = .right, size: CGSize, expandedSize: CGSize? = nil,
                anchorLength: CGFloat? = nil, headroom: CGFloat = 0,
                trackingInset: CGFloat = 0, content: some View) {
        self.edge = edge
        self.collapsedSize = size
        self.expandedSize = expandedSize ?? size
        self.anchorLength = anchorLength
        self.headroom = headroom
        self.hosting = BarHostingView(rootView: AnyView(content))
        hosting.edge = edge
        hosting.headroom = headroom
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
        WindowStage.stage(self)

        reposition()
    }

    /// Focus never reaches this window. `.nonactivatingPanel` alone is not
    /// enough; with `canBecomeKey` left open the panel can still take key focus.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Places the bar on the pinned screen (`display`) while it is
    /// connected, or else on the **main screen** — the first, the one with
    /// the menu bar. Not `NSScreen.main`, which is the key window's screen
    /// and moves with focus, and not the window's own screen, which is no
    /// screen at all once its display is gone. With no screen the bar stays
    /// where it is. A `screen` handed in wins over both.
    public func reposition(on screen: NSScreen? = nil) {
        let frames: (frame: NSRect, visibleFrame: NSRect)
        if let screen {
            frames = (screen.frame, screen.visibleFrame)
        } else if let chosen = BarDisplay.chosen(display, among: BarDisplay.connected) {
            frames = (chosen.frame, chosen.visibleFrame)
        } else {
            return
        }
        // The size it has now, not the one it was built with: a screen
        // change while the bar is open keeps it open.
        setFrameOrigin(Self.origin(edge: edge, visibleFrame: frames.visibleFrame, frame: frames.frame,
                                   size: frame.size, anchorLength: anchorLength, headroom: headroom))
    }

    /// The origin on the first of `screens`; `nil` without one. Apart from
    /// `reposition` so the choice of screen is tested without real displays.
    nonisolated static func origin(edge: Edge, screens: [(frame: NSRect, visibleFrame: NSRect)],
                                   size: CGSize, anchorLength: CGFloat?,
                                   headroom: CGFloat = 0) -> NSPoint? {
        guard let main = screens.first else { return nil }
        return origin(edge: edge, visibleFrame: main.visibleFrame, frame: main.frame,
                      size: size, anchorLength: anchorLength, headroom: headroom)
    }

    /// Where a bar of `size` docked to `edge` goes: `visibleFrame` along the
    /// docked axis (above the Dock, below the menu bar), the full `frame`
    /// along the other one. The second half is deliberate: centring off
    /// `visibleFrame` would make the bar shift whenever the Dock appears or
    /// hides — only a Dock on the bar's own edge pushes it.
    nonisolated static func origin(edge: Edge, visibleFrame usable: NSRect, frame full: NSRect,
                                   size: CGSize, anchorLength: CGFloat?,
                                   headroom: CGFloat = 0) -> NSPoint {
        // The head: the top of a vertical bar, the leading end of a
        // horizontal one, placed as if the bar were `anchorLength` long.
        // The window's top is `headroom` above it.
        let vertical = (anchorLength ?? size.height) / 2 + headroom
        let horizontal = (anchorLength ?? size.width) / 2
        switch edge {
        case .right:
            return NSPoint(x: usable.maxX - size.width, y: full.midY + vertical - size.height)
        case .left:
            return NSPoint(x: usable.minX, y: full.midY + vertical - size.height)
        case .top:
            return NSPoint(x: full.midX - horizontal, y: usable.maxY - size.height)
        case .bottom:
            return NSPoint(x: full.midX - horizontal, y: usable.minY)
        }
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

    /// A drag carrying files. Other drags are not reported.
    public enum Drag {
        /// Over the window at `point` (content view, flipped); `screen` is
        /// the same point in the gaze monitor's space. Answer: is it taken
        /// here?
        case over(point: CGPoint, screen: CGPoint)
        /// Gone: out of the window, ended elsewhere, or cancelled.
        case left
        /// Let go at `point`: the files. Answer: were they taken?
        case drop(point: CGPoint, items: [ChatFolder.Item])
    }

    /// See `BarPanel.onDrag`.
    var onDrag: ((Drag) -> Bool)?

    public required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    /// The drag target is **event-driven**: AppKit calls these only while a
    /// drag is over the window, and `wantsPeriodicDraggingUpdates` is off, so
    /// AppKit sends no periodic updates while the cursor is still. With no drag
    /// on, nothing here runs at all.
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOver(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOver(sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = onDrag?(.left)
    }

    /// A drag that ends anywhere — dropped elsewhere, Esc — after passing
    /// over the bar; `draggingExited` is not promised for every one.
    public override func draggingEnded(_ sender: NSDraggingInfo) {
        _ = onDrag?(.left)
    }

    public override func wantsPeriodicDraggingUpdates() -> Bool { false }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileDrop.hasFiles(sender.draggingPasteboard)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let items = FileDrop.items(from: sender.draggingPasteboard)
        guard !items.isEmpty else { return false }
        return onDrag?(.drop(point: convert(sender.draggingLocation, from: nil), items: items)) ?? false
    }

    private func dragOver(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard FileDrop.hasFiles(sender.draggingPasteboard), let window else { return [] }
        let screen = window.convertPoint(toScreen: sender.draggingLocation)
        let taken = onDrag?(.over(point: convert(sender.draggingLocation, from: nil), screen: screen)) ?? false
        return taken ? .copy : []
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

        /// Whether the cursor is in that area now, by its rectangle. Asked of
        /// every exit before it is believed: rebuilt under a still cursor,
        /// an area got an enter and at once an exit from AppKit — while a
        /// card's frame moved through its transition the areas were rebuilt
        /// every few milliseconds, and the last such exit, with no move after
        /// it, closed the open bar under the cursor 0.25 s later (traced).
        var holds: ((Region) -> Bool)?
        /// After an exit not believed, AppKit counts the cursor out of the
        /// area and a jump straight off the bar would bring no exit at all:
        /// until an enter says otherwise, the cursor is looked for every
        /// `recheck` and the exit taken once it has gone. A few reads a
        /// second, only in that state.
        static let recheck: TimeInterval = 0.25
        private var doubted: Set<Region> = []
        private var recheckScheduled = false
        /// How a recheck is scheduled; a test runs it at once.
        var scheduleRecheck: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

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
            doubted.remove(region)
            let wasOutside = inside.isEmpty
            inside.insert(region)
            if wasOutside { handler?(.entered) }
        }

        /// Reported even without a matching enter: an area installed under
        /// the cursor never says "entered", and swallowing its exit would
        /// leave the bar open with nobody over it. Believed only once the
        /// cursor is out of the area (`holds`).
        func exited(_ region: Region) {
            if holds?(region) == true {
                doubted.insert(region)
                recheckLater()
                return
            }
            doubted.remove(region)
            inside.remove(region)
            if inside.isEmpty { handler?(.exited) }
        }

        private func recheckLater() {
            guard !recheckScheduled else { return }
            recheckScheduled = true
            scheduleRecheck(Self.recheck) { [weak self] in
                guard let self else { return }
                self.recheckScheduled = false
                for region in self.doubted { self.exited(region) }
            }
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
    /// The transparent room above the head (`BarPanel.headroom`): the body's
    /// hover area starts this far down.
    var headroom: CGFloat = 0 {
        didSet { if headroom != oldValue { updateTrackingAreas() } }
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
                                          flipped: Bool, headroom: CGFloat = 0,
                                          edge: BarPanel.Edge) -> (body: NSRect, card: NSRect?) {
        var body = trackingRect(in: bounds, inset: inset, visible: visibleWidth, edge: edge)
        if let visibleLength, edge == .right || edge == .left {
            let length = min(max(0, visibleLength), max(0, bounds.height - headroom))
            body.origin.y = flipped ? bounds.minY + headroom : bounds.maxY - headroom - length
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
    /// means a click and a hover can never disagree about where anything is.
    /// The clicks taken are `[Go to session]`'s and the mascot's; any other
    /// goes on to SwiftUI. A ctrl-click is a right click — the menu's
    /// (`menu(for:)`), never the mascot's balloon.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !event.modifierFlags.contains(.control), onClick?(point) == true { return }
        super.mouseDown(with: event)
    }

    /// See `BarPanel.onMenu`.
    var onMenu: ((CGPoint) -> NSMenu?)?

    /// AppKit's own route for a context menu: a right click and a
    /// ctrl-click both ask here. Read from geometry like a click; where
    /// nothing answers there is no menu — not SwiftUI's either.
    public override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(convert(event.locationInWindow, from: nil))
    }

    /// See `BarPanel.onScroll`.
    var onScroll: ((CGPoint, CGFloat, Bool) -> Bool)?

    /// The wheel reaches this panel although it is never key and the app is
    /// never active (measured), and taking it activates
    /// nothing. Where it counts — over the open list — is decided from
    /// geometry by the controller, like a click.
    public override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onScroll?(point, event.scrollingDeltaY, event.hasPreciseScrollingDeltas) == true { return }
        super.scrollWheel(with: event)
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
                                       card: cardRect, flipped: isFlipped, headroom: headroom, edge: edge)
        var parts: [(Region, NSRect)] = [(.body, rects.body)]
        if let card = rects.card { parts.append((.card, card)) }
        areas = parts.map { region, rect in
            NSTrackingArea(rect: rect,
                           options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                           owner: relay, userInfo: [Self.regionKey: region.rawValue])
        }
        areas.forEach(addTrackingArea)
        let rectsByRegion = Dictionary(uniqueKeysWithValues: parts)
        relay.holds = { [weak self] region in
            guard let self, let window = self.window, let rect = rectsByRegion[region] else { return false }
            return rect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
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

/// Distance in from the docked edge — the one measure every hit test, the
/// gaze anchor and the card's hover area take, so the left edge is the
/// right's mirror in one place instead of five. Top and bottom are measured
/// like the right: no horizontal bar is built.
extension BarPanel.Edge {
    var isLeft: Bool { self == .left }

    /// How far `x` is in from this edge of `rect`.
    func inset(of x: CGFloat, in rect: CGRect) -> CGFloat {
        isLeft ? x - rect.minX : rect.maxX - x
    }

    /// The `x` that is `inset` in from this edge of `rect`.
    func x(atInset inset: CGFloat, in rect: CGRect) -> CGFloat {
        isLeft ? rect.minX + inset : rect.maxX - inset
    }
}

/// Files on a drag's pasteboard: file URLs only — a file
/// promise (Mail, Photos) is not a path yet and is not taken.
enum FileDrop {
    private static let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    /// The files, and which of them are folders — the one thing the core's
    /// `ChatFolder` cannot tell from a path.
    ///
    /// A dropped link is named by what it points at: `ChatFolder`'s "never
    /// the home or above" reads paths only, and a link to the home would
    /// otherwise pass it and become a turn's folder.
    static func items(from pasteboard: NSPasteboard) -> [ChatFolder.Item] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter(\.isFileURL).map { dropped in
            let isLink = (try? dropped.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let url = isLink ? dropped.resolvingSymlinksInPath() : dropped
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return ChatFolder.Item(path: url.path, isDirectory: isDirectory.boolValue)
        }
    }
}
