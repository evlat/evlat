import AppKit

/// A screen the bar can be pinned to, as the choice of one sees it: a
/// stable id, a name to show and the two frames the bar is laid out from.
///
/// The id is the display's UUID (`CGDisplayCreateUUIDFromDisplayID`), not
/// its `CGDirectDisplayID`: the number is handed out at connection time and
/// can change across a restart or a replug, the UUID stays with the panel.
/// Reading it asks for no permission.
struct BarDisplay: Equatable, Sendable {
    let id: String
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect

    /// The connected screens, the main one — the menu bar's — first, as
    /// `NSScreen.screens` orders them.
    @MainActor
    static var connected: [BarDisplay] {
        NSScreen.screens.map { screen in
            BarDisplay(id: screen.displayID, name: screen.localizedName,
                       frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    /// Which of `displays` the bar goes on: the one with `preferred`'s id,
    /// or else the first, the main one. `nil` only with no screen at all.
    ///
    /// A pinned screen that is not connected is **not forgotten**: the bar
    /// waits on the main screen, and the screen observer's `reposition`
    /// brings it back when the screen returns.
    static func chosen(_ preferred: String?, among displays: [BarDisplay]) -> BarDisplay? {
        preferred.flatMap { id in displays.first { $0.id == id } } ?? displays.first
    }

    /// Whether another screen lies past `display`'s `edge`. The bar is then
    /// docked on a seam, not a wall: the cursor runs on into the other
    /// screen instead of stopping at the bar, so the hover that opens it
    /// is hard to hit. Said in Settings, never prevented.
    static func hasNeighbour(beyond edge: BarPanel.Edge, of display: BarDisplay,
                             among displays: [BarDisplay]) -> Bool {
        let own = display.frame
        return displays.contains { other in
            guard other.id != display.id else { return false }
            let touches: Bool
            let overlap: CGFloat
            switch edge {
            case .right: touches = abs(other.frame.minX - own.maxX) < 1
            case .left: touches = abs(other.frame.maxX - own.minX) < 1
            case .top: touches = abs(other.frame.minY - own.maxY) < 1
            case .bottom: touches = abs(other.frame.maxY - own.minY) < 1
            }
            switch edge {
            case .right, .left: overlap = min(own.maxY, other.frame.maxY) - max(own.minY, other.frame.minY)
            case .top, .bottom: overlap = min(own.maxX, other.frame.maxX) - max(own.minX, other.frame.minX)
            }
            return touches && overlap > 0
        }
    }

    /// The names to show for `displays`, in order: two monitors of the same
    /// model have the same `localizedName`, so a repeated name is numbered
    /// ("DELL U2720Q", "DELL U2720Q 2").
    static func titles(_ displays: [BarDisplay]) -> [String] {
        var seen: [String: Int] = [:]
        return displays.map { display in
            let count = (seen[display.name] ?? 0) + 1
            seen[display.name] = count
            return count == 1 ? display.name : "\(display.name) \(count)"
        }
    }
}

extension NSScreen {
    /// The display's UUID, or — on the rare screen that has none — its
    /// number, which is at least right until the next replug.
    var displayID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "screen:\(localizedName)"
        }
        let display = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) else {
            return "display:\(display)"
        }
        return text as String
    }
}
