import AppKit

/// Where Evlat's windows are drawn: on the user's screen, or — under the
/// test runner — off it.
///
/// `EvlatAppTests` build real bars, balloons and windows. On the screen they
/// flashed over the user's work (a left-docked bar at `.statusBar` level,
/// opaque, measured) and the balloon — a key `.nonactivatingPanel` — took
/// the keys the user was typing while the front app never changed.
/// Offstage:
/// - every Evlat window is drawn fully transparent and lets clicks through
///   (`stage`);
/// - a panel beside the mascot has its keyboard as Evlat's own bookkeeping,
///   not the window server's (`BesidePanel.isKeyWindow`), so no keystroke
///   ever reaches it;
/// - Evlat activates no app, its own or another (`activate`).
///
/// What a test reads — frames, levels, visibility, `isKeyWindow`, the close
/// on a lost keyboard — behaves as on the screen.
///
/// Offstage only when XCTest is loaded, which the app never does.
/// `EVLAT_TEST_DESKTOP=1` puts a test run back on the real desktop, to check
/// the window server's side on purpose (`make test-desktop`).
enum WindowStage {
    static let isOffstage: Bool = NSClassFromString("XCTestCase") != nil
        && ProcessInfo.processInfo.environment["EVLAT_TEST_DESKTOP"] != "1"

    /// The alpha a window is drawn with: the one asked for on the screen,
    /// none offstage.
    static func alpha(_ requested: CGFloat) -> CGFloat { isOffstage ? 0 : requested }

    /// Takes a freshly made window off the screen when offstage.
    @MainActor
    static func stage(_ window: NSWindow) {
        guard isOffstage else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    /// Brings Evlat forward — never offstage.
    @MainActor
    static func activate() {
        guard !isOffstage else { return }
        NSApp.activate()
    }

    /// The windows that brought Evlat forward and are still open.
    @MainActor private(set) static var forwardWindows: Set<ObjectIdentifier> = []

    /// Brings Evlat forward for a window the user asked for, as a regular app
    /// while it is open. An accessory app's `activate()` is a request the
    /// front app may refuse (cooperative activation, macOS 14): opened from
    /// the menu, the settings window was drawn behind the app in front, which
    /// kept the keyboard (`AGENTS.md` → Pitfalls). The window is counted
    /// offstage too, so the bookkeeping is testable; only the policy and the
    /// activation stay off the test runner.
    @MainActor
    static func comeForward(for window: AnyObject) {
        forwardWindows.insert(ObjectIdentifier(window))
        guard !isOffstage else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    /// The window closed: Evlat is an accessory again once no other window
    /// that brought it forward is open.
    @MainActor
    static func stepBack(for window: AnyObject) {
        forwardWindows.remove(ObjectIdentifier(window))
        guard !isOffstage, forwardWindows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Brings another app forward; offstage nothing moves and the answer is
    /// `false`, as for an app that would not come.
    @MainActor
    @discardableResult
    static func activate(_ app: NSRunningApplication, options: NSApplication.ActivationOptions = []) -> Bool {
        guard !isOffstage else { return false }
        return app.activate(options: options)
    }
}
