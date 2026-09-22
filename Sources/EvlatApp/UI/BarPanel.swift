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

    public init(edge: Edge = .right, size: CGSize, content: some View) {
        self.edge = edge
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

        let hosting = NSHostingView(rootView: AnyView(content))
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
        let size = frame.size
        let origin: NSPoint

        switch edge {
        case .right:
            origin = NSPoint(x: usable.maxX - size.width,
                             y: full.midY - size.height / 2)
        case .left:
            origin = NSPoint(x: usable.minX,
                             y: full.midY - size.height / 2)
        case .top:
            origin = NSPoint(x: full.midX - size.width / 2,
                             y: usable.maxY - size.height)
        case .bottom:
            origin = NSPoint(x: full.midX - size.width / 2,
                             y: usable.minY)
        }
        setFrameOrigin(origin)
    }

    /// Not `orderFront`: the bar must appear even when the app is inactive.
    public func show() {
        reposition()
        orderFrontRegardless()
    }
}
