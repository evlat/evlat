import AppKit
import SwiftUI

/// What the windows that stand beside the mascot — the chat balloon and the
/// setup — have in common: the one Evlat window kind that takes the
/// keyboard, and still never makes Evlat the active app.
///
/// `.nonactivatingPanel` with `canBecomeKey` is the Spotlight pattern: the
/// panel becomes key and gets the keys typed, `NSApp.isActive` stays false,
/// and the app in front never falls back. When the panel goes, the keyboard
/// is that app's again with nothing to hand back. The bar (`BarPanel`) keeps
/// `canBecomeKey == false`; this is a second window, not a relaxed bar.
///
/// What each one does with the keyboard it loses, and with Esc, is the
/// subclass's: the balloon closes (`ChatPanel`), the setup stays
/// (`SetupPanel`). Built once and ordered out between uses.
class BesidePanel: NSPanel {
    /// How far the tail reaches out of the panel, toward the bar.
    static let tailDepth: CGFloat = 8
    /// Between the tail's tip and the drawn bar's inner edge.
    static let gapToBar: CGFloat = 4
    /// Room for the shadow on the three sides away from the bar.
    static let outerMargin: CGFloat = 24
    /// On the bar's side the window stops just past the tail's tip: a wider
    /// margin would lay the window's shadow over the mascot and take the
    /// click meant to close the balloon.
    static let barSideMargin: CGFloat = 2

    /// `content` fills the window, at `size`. The window's size is this
    /// class's alone: see `hosting`.
    init(size: CGSize, content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   // `.nonactivatingPanel`: taking the keyboard does not bring
                   // Evlat forward (`canBecomeKey` below).
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // The bar's level and spaces: the panel comes out of it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // The content draws its own shadow; the window's would outline the
        // transparent envelope.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = content
        WindowStage.stage(self)
    }

    /// SwiftUI `content` as a view that leaves the window's size alone: with
    /// the default `sizingOptions` the hosting view resizes the window and
    /// AppKit pins it to the top-left corner (see `BarPanel`). `type` is a
    /// subclass of the hosting view, for one that answers more than the
    /// default does.
    static func hosting(_ content: some View,
                        as type: NSHostingView<AnyView>.Type = NSHostingView<AnyView>.self) -> NSHostingView<AnyView> {
        let hosting = type.init(rootView: AnyView(content))
        hosting.sizingOptions = []
        return hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Offstage the keyboard is this flag rather than the window server's:
    /// a real key panel in a test run took the keys the user was typing.
    private var stagedKey = false

    override var isKeyWindow: Bool { WindowStage.isOffstage ? stagedKey : super.isKeyWindow }

    override func makeKey() {
        guard WindowStage.isOffstage else { return super.makeKey() }
        stagedKey = true
    }

    /// On the screen, ordering a key window out resigns it; offstage the
    /// flag does the same, down the same path.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        guard WindowStage.isOffstage, stagedKey else { return }
        stagedKey = false
        keyWentElsewhere()
    }

    /// The keyboard went elsewhere: a click in another app or window, or the
    /// panel ordered out. Nothing by default; the balloon closes.
    func keyWentElsewhere() {}

    /// Where the window goes for a bar at `barFrame` on `edge`, on a screen
    /// showing `visible`. The subclass's measures.
    func origin(barFrame: NSRect, edge: BarPanel.Edge, visible: NSRect) -> NSPoint {
        fatalError("a panel beside the mascot says where it goes")
    }

    /// Beside `bar`, on the screen the bar is on, and nothing else: a panel
    /// already out is moved with its bar.
    func place(beside bar: NSWindow, edge: BarPanel.Edge) {
        let visible = (bar.screen ?? NSScreen.screens.first)?.visibleFrame ?? bar.frame
        setFrameOrigin(origin(barFrame: bar.frame, edge: edge, visible: visible))
    }

    /// Placed and shown, with the keyboard unless `keyboard` is false:
    /// `orderFrontRegardless` and `makeKey`, never `makeKeyAndOrderFront`
    /// with an activation — the app stays where it is.
    func present(beside bar: NSWindow, edge: BarPanel.Edge, keyboard: Bool = true) {
        place(beside: bar, edge: edge)
        orderFrontRegardless()
        if keyboard { makeKey() }
    }

    /// A page opened in the browser behind the app in front: the panel keeps
    /// the keyboard and stays out, so what else it links is still there.
    static func openBehind(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// Where the window's left edge goes: its tail's tip `gapToBar` in from
    /// the drawn bar's inner edge (the bar's width, not its window's). The
    /// left is the right's mirror.
    static func x(barFrame: NSRect, edge: BarPanel.Edge, width: CGFloat) -> CGFloat {
        let tip = edge.x(atInset: AppController.barWidth + gapToBar, in: barFrame)
        return edge.isLeft ? tip - barSideMargin : tip + barSideMargin - width
    }
}
