import AppKit
import EvlatCore

/// The menu-bar entry's image: the app icon (`scripts/make-icon.swift`) reduced
/// to a template — the frame as an outline, the two eyes filled and looking
/// toward the screen edge. A template so macOS tints it for a light or dark
/// menu bar and for the highlighted state; drawn from code, like the app icon,
/// so there is no image to keep in step.
///
/// Proportions follow the icon's 1024 grid (body 824, eyes at 49.5 % and
/// 67.7 % across, 34 % down); the eyes are a little wider than the grid says,
/// because at 18 pt the grid's width is under 2 pt and reads as a hairline.
///
/// The amber copy is the same drawing, not a template, in the rings' waiting
/// colour: Hidden takes the sliver and the peek away, so waiting — the one
/// signal the product is for — would otherwise be nowhere.
enum TrayIcon {
    static let side: CGFloat = 18

    /// The rings' waiting colour (`SessionIndicator.amber`).
    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.18, alpha: 1)

    /// Whether the icon carries the waiting signal: only Hidden takes it
    /// from the edge by design. Smart and Tucked show it on the sliver's dot
    /// or the peek (Smart also on the full body while the edge is clear);
    /// turning both off is a choice Settings warns about beside the
    /// switch (`SettingsModel.peekWarningKey`).
    static func isAmber(mode: BodyPresence.Mode, phase: Phase) -> Bool {
        mode == .hidden && phase == .waiting
    }

    static func image(amber: Bool = false) -> NSImage {
        let ink = amber ? Self.amber : NSColor.black
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let frame = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75),
                                       xRadius: 4.2, yRadius: 4.2)
            outline.lineWidth = 1.5
            ink.setStroke()
            outline.stroke()
            ink.setFill()
            for x in [8.0, 11.2] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 6.4, width: 2, height: 5.2),
                             xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = !amber
        image.accessibilityDescription = "Evlat"
        return image
    }
}
