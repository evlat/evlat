import AppKit
import SwiftUI

/// The setup's window: `AppWindow`'s focus pattern at a fixed
/// size. The steps scroll inside it and the footer stays put, so a long
/// step never grows the window and the buttons never move.
enum SetupWindow {
    /// The design's window size.
    static let width: CGFloat = 392
    static let maxHeight: CGFloat = 468

    /// At most 468 pt, and on a small screen 80 % of what is visible — the
    /// window never reaches the menu bar or the Dock.
    static func height(visible: CGFloat) -> CGFloat {
        min(maxHeight, (visible * 0.8).rounded(.down))
    }

    /// Titled for the keyboard and the close button; not resizable, and
    /// without the zoom and minimise buttons a fixed window has no use for.
    /// The title bar is see-through: the mascot sits at the top as drawn.
    @MainActor
    static func make(model: SetupFlowModel, screen: NSScreen?) -> AppKeyWindow {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let size = NSSize(width: width, height: height(visible: visible))
        let window = AppKeyWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = model.t("setup.window.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(rootView: SetupView(model: model))
        window.setContentSize(size)
        return window
    }

    /// "Close" on the last step: the window shrinks into the bar's mascot
    /// and fades. The window
    /// itself closes at once — the focus goes back to the app before it
    /// without waiting — and a picture of it, in a borderless window of
    /// its own that takes no click, makes the flight. Without a bar to fly
    /// to, or with reduced motion, it only closes.
    @MainActor
    static func fly(_ window: NSWindow, to target: NSRect?, then close: () -> Void) {
        guard let target, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let frameView = window.contentView?.superview,
              let picture = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return close()
        }
        frameView.cacheDisplay(in: frameView.bounds, to: picture)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(picture)
        let ghost = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isReleasedWhenClosed = false
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.level = window.level
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
