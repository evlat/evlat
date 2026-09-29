import AppKit
import SwiftUI

/// The setup's stage: the whole screen, the desktop behind it blurred and
/// dimmed, the story in the middle (`SetupView`). One level under the bar,
/// so the real bar stays in sight above it — the edge chapter moves it —
/// and over everything else, the menu bar and the Dock included.
///
/// Borderless, so it takes the keyboard by `acceptsKey`; the focus comes
/// and goes through `AppWindow` as any Evlat window's.
enum SetupWindow {
    /// Just under the bar's `.statusBar`.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    /// The backdrop and the content come in together over this long.
    static let entrance: TimeInterval = 0.5

    @MainActor
    static func make(model: SetupFlowModel, screen: NSScreen?) -> AppKeyWindow {
        let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = SetupStageWindow(contentRect: frame, styleMask: [.borderless, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.acceptsKey = true
        window.title = model.t("setup.window.title")
        window.level = level
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // The story is told in the bar's own dark, whatever the system's.
        window.appearance = NSAppearance(named: .darkAqua)

        // The desktop, blurred: AppKit's own material behind the window.
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: SetupView(model: model))
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        window.contentView = backdrop
        window.setFrame(frame, display: false)
        return window
    }
}

/// The stage fades in when it comes up: the blur arrives with it, the
/// content lands from blurred to sharp (`SetupView`).
final class SetupStageWindow: AppKeyWindow {
    /// Already the whole screen. `AppWindow` centres every window it builds,
    /// which set the stage 30 pt low — centred in the visible area, under
    /// the menu bar (measured in `SetupFlowTests`).
    override func center() {}

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard !isVisible else { return super.makeKeyAndOrderFront(sender) }
        alphaValue = 0
        super.makeKeyAndOrderFront(sender)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = still ? 0.2 : SetupWindow.entrance
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Offstage it stays at none (`WindowStage`).
            animator().alphaValue = WindowStage.alpha(1)
        }
    }
}

extension SetupWindow {
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
