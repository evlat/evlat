import AppKit
import SwiftUI

/// The setup's window: a panel beside the mascot (`BesidePanel`), its tail on
/// the eyes — the mascot is the one speaking.
///
/// Unlike the balloon it stays: a click in another app does not close it
/// (the second step sends the user to a terminal and has to be there when
/// they come back), Esc does not either (a run of Returns must not end it
/// by mistake), and a new edge or screen moves it with the bar. The × and
/// "Finish" fold it into the mascot (`fold`); both come through the
/// controller (`AppController.closeSetup`).
final class SetupPanel: BesidePanel {
    /// The view inside: `SetupView`, always this size.
    static let contentSize = SetupLayout.size
    /// The body's rounded corners, and half of the tail's base.
    static let corner: CGFloat = 20
    static let tailHalf: CGFloat = 7
    /// The nearest the tail's middle comes to the body's top or bottom: it
    /// stays inside the corners.
    static let tailReach = corner + tailHalf

    static let size = CGSize(width: outerMargin + contentSize.width + tailDepth + barSideMargin,
                             height: outerMargin + contentSize.height + outerMargin)

    /// Where the tail points, for the view to draw.
    let tail: SetupTail

    init(model: SetupFlowModel) {
        let tail = SetupTail()
        self.tail = tail
        let hosting = FirstClickHostingView(rootView: AnyView(SetupPanelView(model: model, tail: tail)))
        // The window's size is this class's: see `BesidePanel.hosting`.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        super.init(size: Self.size, content: hosting)
    }

    /// Esc does nothing: taken here, so it neither closes the panel nor beeps.
    override func cancelOperation(_ sender: Any?) {}

    override func origin(barFrame: NSRect, edge: BarPanel.Edge, visible: NSRect) -> NSPoint {
        Self.origin(barFrame: barFrame, edge: edge, size: frame.size, visible: visible)
    }

    /// Placed, and the tail follows: another edge turns it around and a
    /// body held to the screen moves the eyes along it.
    override func place(beside bar: NSWindow, edge: BarPanel.Edge) {
        super.place(beside: bar, edge: edge)
        tail.set(edge: edge, center: Self.tailCenter(barFrame: bar.frame, edge: edge,
                                                     bodyTop: frame.maxY - Self.outerMargin))
    }

    /// Where the window goes: the body centred on the mascot's eyes
    /// (`AppController.gazeAnchor`), its tail's tip `gapToBar` in from the
    /// drawn bar's inner edge, as the balloon's. Held to what is visible:
    /// the bottom above the Dock first, then the top under the menu bar —
    /// on a screen too short for the body the top wins, where the title and
    /// the × are, and the footer falls under the Dock (a visible height under
    /// 460 pt was not met; Return still presses the primary button).
    static func origin(barFrame: NSRect, edge: BarPanel.Edge, size: CGSize, visible: NSRect) -> NSPoint {
        let height = contentSize.height
        let eyes = AppController.gazeAnchor(frame: barFrame, edge: edge).y
        let top = min(max(eyes + height / 2, visible.minY + height), visible.maxY)
        return NSPoint(x: x(barFrame: barFrame, edge: edge, width: size.width),
                       y: top + outerMargin - size.height)
    }

    /// The tail's middle, down from the body's top: level with the eyes, and
    /// kept inside the corners when the body had to move off them.
    static func tailCenter(barFrame: NSRect, edge: BarPanel.Edge, bodyTop: CGFloat) -> CGFloat {
        let eyes = AppController.gazeAnchor(frame: barFrame, edge: edge).y
        return min(max(bodyTop - eyes, tailReach), contentSize.height - tailReach)
    }

    /// "Finish" and the ×: a picture of the panel shrinks into the mascot and
    /// fades. The panel itself goes at once (`close`) — the app in front has
    /// the keyboard again without waiting — and the picture, in a borderless
    /// window of its own that takes no click, makes the flight. Without a bar
    /// to fly to, with reduced motion and offstage, it only closes.
    func fold(into target: NSRect?, then close: () -> Void) {
        guard let target, isVisible, !WindowStage.isOffstage,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let frameView = contentView?.superview,
              let picture = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return close()
        }
        frameView.cacheDisplay(in: frameView.bounds, to: picture)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(picture)
        let ghost = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isReleasedWhenClosed = false
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        // The picture carries the panel's own shadow.
        ghost.hasShadow = false
        ghost.ignoresMouseEvents = true
        ghost.level = level
        // The panel's spaces: over a full-screen app too.
        ghost.collectionBehavior = collectionBehavior
        WindowStage.stage(ghost)
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        ghost.contentView = view
        ghost.orderFront(nil)
        close()
        let end = NSRect(x: target.midX - 12, y: target.midY - 12, width: 24, height: 24)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
            ghost.animator().setFrame(end, display: true)
            ghost.animator().alphaValue = 0
        }, completionHandler: {
            ghost.orderOut(nil)
        })
    }
}

/// A hosted view that takes the click that brings its window the keyboard:
/// the panel is not key until it is clicked (or while it opened without the
/// keyboard), and that first click must press the button under it, not only
/// raise the panel.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the tail points: the bar's side and its height on the body. The
/// panel writes it when it is placed; the view draws it.
@MainActor
final class SetupTail: ObservableObject {
    @Published private(set) var edge: BarPanel.Edge = .right
    @Published private(set) var center: CGFloat = SetupPanel.tailReach

    /// Written when it changed: a panel placed again where it was draws nothing.
    func set(edge: BarPanel.Edge, center: CGFloat) {
        if self.edge != edge { self.edge = edge }
        if abs(self.center - center) > 0.25 { self.center = center }
    }
}

/// The panel's content: `SetupView` as a body with rounded corners and a
/// tail toward the bar, in the balloon's drawing (`BalloonShape`), over the
/// window's transparent room for the shadow.
struct SetupPanelView: View {
    @ObservedObject var model: SetupFlowModel
    @ObservedObject var tail: SetupTail

    private var isLeft: Bool { tail.edge.isLeft }

    var body: some View {
        let shape = BalloonShape(tailOnLeft: isLeft, tailCenter: tail.center, tailDepth: SetupPanel.tailDepth,
                                 corner: SetupPanel.corner, tailHalf: SetupPanel.tailHalf)
        ZStack {
            // The ground reaches into the tail, and the shadow is this
            // shape's alone: the live ring on the second step must not make
            // it draw again.
            shape.fill(LinearGradient(colors: [SetupPalette.groundTop, SetupPalette.groundBottom],
                                      startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
            SetupView(model: model)
                .padding(isLeft ? .leading : .trailing, SetupPanel.tailDepth)
                .clipShape(shape)
            shape.stroke(SetupPalette.pillLine, lineWidth: 1)
        }
        .frame(width: SetupPanel.contentSize.width + SetupPanel.tailDepth, height: SetupPanel.contentSize.height)
        .padding(.top, SetupPanel.outerMargin)
        .padding(isLeft ? .leading : .trailing, SetupPanel.barSideMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLeft ? .topLeading : .topTrailing)
    }
}
