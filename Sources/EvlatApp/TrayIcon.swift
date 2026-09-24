import AppKit

/// The menu-bar entry's image: the app icon (`scripts/make-icon.swift`) reduced
/// to a template — the frame as an outline, the two eyes filled and looking
/// toward the screen edge. A template so macOS tints it for a light or dark
/// menu bar and for the highlighted state; drawn from code, like the app icon,
/// so there is no image to keep in step.
///
/// Proportions follow the icon's 1024 grid (body 824, eyes at 49.5 % and
/// 67.7 % across, 34 % down); the eyes are a little wider than the grid says,
/// because at 18 pt the grid's width is under 2 pt and reads as a hairline.
enum TrayIcon {
    static let side: CGFloat = 18

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let frame = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75),
                                       xRadius: 4.2, yRadius: 4.2)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            NSColor.black.setFill()
            for x in [8.0, 11.2] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 6.4, width: 2, height: 5.2),
                             xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Evlat"
        return image
    }
}
