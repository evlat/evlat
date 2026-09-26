import CoreGraphics
import EvlatCore

/// How much of the body is out of the screen's edge, and the geometry that
/// follows from it — one pure rule, read the way `MascotModel.isAwake` and
/// the `Aggregator` are: a function of its inputs, the same answer wherever
/// it is asked. The controller derives it after every input changes and is
/// the only one to write what it says; no call site sets a level by hand, so
/// hover, balloon, drag and phase can never race to be the last writer.
///
/// It reads no clock. How long a finish peeks is a one-shot timer in the
/// shell that clears `peekPhase`; the rule only sees whether it is set.
///
/// The level is **not** a `Phase`: `Phase` stays at five values.
struct BodyPresence: Equatable {
    /// The user's choice in Settings → General.
    enum Mode: CaseIterable, Equatable {
        /// Today's bar: the body is always out.
        case always
        /// The body is in; it comes out when something is asked of the user
        /// or the user reaches for the edge.
        case smart
        /// Not even the sliver: only reaching for the edge opens it.
        case hidden

        /// The stored form (`bar.body`). Anything else reads as `nil` and
        /// the caller falls back to `always`.
        init?(stored raw: String?) {
            switch raw {
            case "always": self = .always
            case "smart": self = .smart
            case "hidden": self = .hidden
            default: return nil
            }
        }

        var storedValue: String {
            switch self {
            case .always: return "always"
            case .smart: return "smart"
            case .hidden: return "hidden"
            }
        }
    }

    /// The three switches under the mode. Nothing stored means on.
    struct Toggles: Equatable, CustomStringConvertible {
        /// Show the sliver (and its dot).
        var sliver = true
        /// Come out as a peek while waiting.
        var peekWaiting = true
        /// Peek briefly on a review or a failure.
        var peekDone = true

        var description: String {
            "sliver \(sliver) · peekWaiting \(peekWaiting) · peekDone \(peekDone)"
        }
    }

    enum Level: Equatable {
        /// Nothing drawn; only the trigger strip listens.
        case none
        /// The 5 pt sliver at the mascot's height, with its dot.
        case sliver
        /// Half the mascot looks out of the edge.
        case peek
        /// Today's body, closed or open.
        case full
    }

    /// A rectangle measured from the docked edge (`width`) and from the
    /// window's top (`length`). One area serves hover and drop alike, so the
    /// two can never disagree about where the body is.
    struct Area: Equatable {
        var width: CGFloat
        var length: CGFloat

        /// The area in a flipped view's bounds (the head at `minY`), held
        /// against `edge`; the left edge is the right one mirrored. Built the
        /// way `BarHostingView.trackingRects` builds the body's today.
        func rect(in bounds: CGRect, edge: BarPanel.Edge) -> CGRect {
            let length = min(max(0, length), bounds.height)
            let x = edge.isLeft ? bounds.minX : bounds.maxX - width
            return CGRect(x: x, y: bounds.minY, width: width, height: length)
        }
    }

    // MARK: Geometry constants

    /// The sliver: 5 × 40 pt, centred on the mascot, so the body opens from
    /// the very place the eye has learned to look.
    static let sliverWidth: CGFloat = 5
    static let sliverLength: CGFloat = 40
    static let sliverTop: CGFloat =
        AppController.mascotTopInset + AppController.mascotSize / 2 - sliverLength / 2
    /// How far under the sliver the trigger reaches. Above it the window
    /// ends: the window's top is the body's head, so the trigger is
    /// asymmetric — from the top to 60 pt under the sliver.
    static let triggerReach: CGFloat = 60
    static let triggerLength: CGFloat = sliverTop + sliverLength + triggerReach
    /// How far the peek comes out of the edge: about half the mascot.
    static let peekWidth: CGFloat = 24

    // MARK: Inputs

    var mode: Mode
    var toggles: Toggles
    /// `MascotModel.effectivePhase`, not the aggregate: a forced phase
    /// (`EVLAT_PHASE`, "Force state") must peek like a real one.
    var phase: Phase
    /// The finish that outlives the phase: set on the way into review or
    /// failed (`latch(_:on:)`), dropped when the bar opens. Only colours the dot.
    var latch: Phase?
    /// The finish whose peek is running; the shell clears it when it ends.
    var peekPhase: Phase?
    var isOpen: Bool
    var chatOpen: Bool
    var dragging: Bool
    /// Today's sizes: the closed body's length and the open body's width and
    /// length (`BarState`). The full body's area is exactly these.
    var closedLength: CGFloat
    var openWidth: CGFloat
    var openLength: CGFloat

    // MARK: Outputs

    var level: Level {
        if mode == .always || isOpen || chatOpen || dragging { return .full }
        guard mode == .smart else { return .none }
        if phase == .waiting && toggles.peekWaiting { return .peek }
        if let peekPhase, Self.isFinish(peekPhase), toggles.peekDone { return .peek }
        return toggles.sliver ? .sliver : .none
    }

    /// The sliver's dot: the higher priority of the phase and the latch, as
    /// the `Aggregator` ranks them. No dot when that is idle, and none
    /// anywhere but on the sliver.
    var dot: Phase? {
        guard level == .sliver else { return nil }
        let top = [phase, latch].compactMap { $0 }.max { $0.priority < $1.priority } ?? .idle
        return top == .idle ? nil : top
    }

    /// Whether the mascot is on screen. When it is not, no clip plays and
    /// no gaze is written.
    var mascotShown: Bool { level == .peek || level == .full }

    /// Whether a click on the mascot's place is the mascot's. Hidden, it is
    /// not: the sliver and the trigger sit inside the mascot's hit box, and a
    /// click there would open the balloon and take the keyboard away.
    var takesMascotClick: Bool { mascotShown }

    /// Where hover and drops are heard. Each level's area holds at least
    /// what it draws: the trigger strip for none and sliver, the peek's width
    /// along the trigger, today's body for full.
    var area: Area {
        switch level {
        case .none, .sliver: return Area(width: Self.sliverWidth, length: Self.triggerLength)
        case .peek: return Area(width: Self.peekWidth, length: Self.triggerLength)
        case .full:
            return isOpen ? Area(width: openWidth, length: openLength)
                          : Area(width: AppController.barWidth, length: closedLength)
        }
    }

    // MARK: Latch

    /// The latch after the phase moves to `phase`: a review or a failure
    /// latches, a failure overrides a latched review, never the other way;
    /// anything else leaves it as it is.
    static func latch(_ current: Phase?, on phase: Phase) -> Phase? {
        guard isFinish(phase) else { return current }
        if current == .failed { return .failed }
        return phase
    }

    private static func isFinish(_ phase: Phase) -> Bool {
        phase == .review || phase == .failed
    }
}
