import AppKit
import SwiftUI

/// The update window's size and place: `AppWindow`'s focus pattern, sized
/// by its content.
///
/// The window grows with what it shows — a failure that wraps, a "Why?"
/// opened — and is never larger than the visible part of its screen (the
/// menu bar and the Dock left out) less `margin`. Past that only the two
/// lists scroll; the heading, its paragraph and the footer stay put.
enum UpdatesWindow {
    /// The design's width.
    static let width: CGFloat = 740
    /// Kept clear between the window and every edge of the visible frame.
    static let margin: CGFloat = 40

    struct Fit: Equatable {
        /// The window's size, its title bar inside it (a full-size content
        /// view).
        let size: CGSize
        /// The lists' viewport.
        let listsHeight: CGFloat
        /// The lists are taller than their viewport.
        let scrolls: Bool
    }

    /// The width on a screen `visible` wide: the design's, or what fits.
    static func width(visible: CGFloat) -> CGFloat {
        max(0, min(width, (visible - 2 * margin).rounded(.down)))
    }

    /// The size for content measured at `width(visible:)`: `fixed` is the
    /// heading and the footer, `lists` the two lists at their full height.
    /// All of it while it fits; past that the lists get what is left, and
    /// scroll. Even when the fixed part alone would not fit (a screen a few
    /// hundred points high), the window does not leave the screen.
    static func fit(fixed: CGFloat, lists: CGFloat, visible: CGSize) -> Fit {
        let cap = max(0, (visible.height - 2 * margin).rounded(.down))
        let fixed = fixed.rounded(.up), lists = lists.rounded(.up)
        let height = min(fixed + lists, cap)
        let viewport = max(0, height - fixed)
        return Fit(size: CGSize(width: width(visible: visible.width), height: height),
                   listsHeight: viewport, scrolls: viewport < lists)
    }

    /// Where a window of `size` goes on the visible frame: centred when it
    /// opens; afterwards (`current`) its top left corner stays where it is
    /// unless the new size would leave the screen, when it moves just
    /// enough. Always `margin` inside the visible frame.
    static func frame(_ size: CGSize, in visible: CGRect, current: CGRect? = nil) -> CGRect {
        var origin: CGPoint
        if let current {
            origin = CGPoint(x: current.minX, y: current.maxY - size.height)
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let inner = visible.insetBy(dx: margin, dy: margin)
        origin.x = min(max(origin.x, inner.minX), max(inner.minX, inner.maxX - size.width))
        origin.y = min(max(origin.y, inner.minY), max(inner.minY, inner.maxY - size.height))
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// Titled for the keyboard and the close button; not resizable — its
    /// content decides its size. The title bar is see-through, as Setup's.
    ///
    /// `visible`: the visible frame to fit — of the screen the window is on
    /// once placed (it may have been moved), of the one it opens on before
    /// (`nil`).
    @MainActor
    static func make(model: UpdatesModel,
                     visible: @escaping (NSWindow?) -> CGRect? = { window in
                         (window?.screen ?? NSScreen.main)?.visibleFrame
                     }) -> AppKeyWindow {
        let opening = visible(nil) ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let measure = UpdatesMeasure(width: width(visible: opening.width))
        let start = CGSize(width: measure.width, height: max(0, opening.height - 2 * margin))
        let window = AppKeyWindow(contentRect: NSRect(origin: .zero, size: start),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        // Kept for the next open (`AppWindow` says so too): released on
        // close, the next touch would reach a freed window.
        window.isReleasedWhenClosed = false
        window.title = model.t("updates.window.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        var placed = false
        func apply(_ window: NSWindow) {
            guard let fixed = measure.fixed, let lists = measure.lists else { return }
            let screen = (placed ? visible(window) : nil) ?? visible(nil) ?? opening
            let fit = fit(fixed: fixed, lists: lists, visible: screen.size)
            if measure.listsHeight != fit.listsHeight { measure.listsHeight = fit.listsHeight }
            let frame = frame(fit.size, in: screen, current: placed ? window.frame : nil)
            placed = true
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        // Set before the content goes in, which measures at once; applied
        // after the view's pass, not inside it: the frame and the viewport
        // it sets lay the view out again.
        measure.onChange = { [weak window] in
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                apply(window)
            }
        }
        // Each opening is centred again: its first placing is a new one.
        model.onStart = { [weak window] in
            placed = false
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                apply(window)
            }
        }
        let host = NSHostingController(rootView: UpdatesView(model: model, measure: measure))
        // The window's size is this rule's, not the hosting view's.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(start)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

/// The heights the view measures and the viewport the rule gives back. Set
/// by the view as it lays out; read by the window (`UpdatesWindow.make`).
@MainActor
final class UpdatesMeasure: ObservableObject {
    let width: CGFloat
    /// The lists' viewport; `nil` until the first measure, when they take
    /// what the window has.
    @Published var listsHeight: CGFloat?
    private(set) var header: CGFloat?
    private(set) var footer: CGFloat?
    private(set) var lists: CGFloat?
    var onChange: () -> Void = {}

    init(width: CGFloat, listsHeight: CGFloat? = nil) {
        self.width = width
        self.listsHeight = listsHeight
    }

    /// Heading and footer.
    var fixed: CGFloat? {
        guard let header, let footer else { return nil }
        return header + footer
    }

    func set(header: CGFloat? = nil, footer: CGFloat? = nil, lists: CGFloat? = nil) {
        var changed = false
        if let header, header != self.header { self.header = header; changed = true }
        if let footer, footer != self.footer { self.footer = footer; changed = true }
        if let lists, lists != self.lists { self.lists = lists; changed = true }
        if changed { onChange() }
    }
}
