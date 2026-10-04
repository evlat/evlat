import AppKit

/// Whether another app's window lies under the closed body — what Smart hide
/// reads (`BodyPresence.edgeClear`). Two parts: a pure rule over the window
/// list's dictionaries, held by tests with literals, and the live reading
/// that feeds it the window server's list.
///
/// Only bounds, layer, alpha, owner pid and number are read, never a name:
/// the list gives positions without Screen Recording (measured on macOS
/// 26.4.1: `CGPreflightScreenCaptureAccess()` false, every normal window
/// with its bounds and owner, none with its name, no prompt), and a name is
/// exactly what that permission guards.
enum EdgeCover {
    /// What to look for: the bar's own window, found in the same list by its
    /// number, and the closed body on it — `width` along the docked edge and
    /// `length` from the head, under the window's `headroom`. The area is
    /// taken from the bar's own bounds in the list's coordinates, so no
    /// translation between the window server's and Cocoa's is needed, and a
    /// bar on a second screen is read the same way.
    struct Strip: Equatable {
        var window: Int
        var edge: BarPanel.Edge
        var headroom: CGFloat
        var width: CGFloat
        var length: CGFloat
        /// Evlat's own pid: its other windows (the balloon, Settings) are
        /// never what covers the edge.
        var pid: Int32
    }

    /// Covered: a window on screen, in the normal layer, not fully
    /// transparent and not Evlat's, overlaps the strip. Z order is not read —
    /// the bar sits above all of them. `nil` when the bar's window is not in
    /// the list (not on screen yet), or on an edge no bar is built for:
    /// nothing is known, and the caller counts no reading.
    static func covered(_ windows: [[String: Any]], by strip: Strip) -> Bool? {
        guard let bar = windows.first(where: { number($0, kCGWindowNumber) == strip.window }),
              let frame = bounds(bar),
              let area = area(of: strip, in: frame) else { return nil }
        return windows.contains { window in
            guard number(window, kCGWindowLayer) == 0,
                  number(window, kCGWindowOwnerPID) != Int(strip.pid),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let rect = bounds(window) else { return false }
            // Overlapping, not touching: a window that ends where the strip
            // begins leaves it clear.
            let common = rect.intersection(area)
            return !common.isNull && common.width > 0 && common.height > 0
        }
    }

    /// The strip in the list's coordinates (origin top left, `y` down): the
    /// head is `headroom` below the window's top.
    static func area(of strip: Strip, in frame: CGRect) -> CGRect? {
        let top = frame.minY + strip.headroom
        let length = max(0, min(strip.length, frame.maxY - top))
        switch strip.edge {
        case .right: return CGRect(x: frame.maxX - strip.width, y: top, width: strip.width, height: length)
        case .left: return CGRect(x: frame.minX, y: top, width: strip.width, height: length)
        case .top, .bottom: return nil  // no horizontal bar is built yet
        }
    }

    /// The live reading: the windows on screen now, the desktop's left out.
    /// One call and the overlap took 1.2–4.5 ms in use (measured in a
    /// probe on this hardware); made only under Smart.
    static func read(_ strip: Strip) -> Bool? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return covered(list, by: strip)
    }

    private static func number(_ window: [String: Any], _ key: CFString) -> Int? {
        (window[key as String] as? NSNumber)?.intValue
    }

    private static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: value as CFDictionary)
    }
}
