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
/// - the balloon's keyboard is Evlat's own bookkeeping, not the window
///   server's (`ChatPanel.isKeyWindow`), so no keystroke ever reaches it;
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

    /// Brings another app forward; offstage nothing moves and the answer is
    /// `false`, as for an app that would not come.
    @MainActor
    @discardableResult
    static func activate(_ app: NSRunningApplication, options: NSApplication.ActivationOptions = []) -> Bool {
        guard !isOffstage else { return false }
        return app.activate(options: options)
    }
}
