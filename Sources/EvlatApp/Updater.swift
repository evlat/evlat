import AppKit
import Sparkle
import EvlatCore

/// "Check for Updates…": Sparkle, the only place it is imported.
///
/// Sparkle reads the feed (`SUFeedURL`) and the key that signs every update
/// (`SUPublicEDKey`) from Info.plist; `scripts/bundle-app.sh` writes both only
/// into a release build. A development bundle has no feed and so no updater:
/// a 0.0.0 build would otherwise offer to replace itself with the release.
///
/// Handed in like `LoginItem`: only `launch()` builds the real one, and not
/// even it in an isolated launch unless `EVLAT_FEED` names a feed — the way to
/// try an update against a local appcast without touching the installed app's
/// schedule. A test never starts Sparkle.
struct Updater {
    var check: () -> Void
    /// The version Sparkle found and holds, or nil: the menu line says it.
    var pendingVersion: () -> String? = { nil }
    /// Settings → General → "Install updates automatically": Sparkle's own
    /// `automaticallyDownloadsUpdates` (`SUAutomaticallyUpdate`), never a
    /// shadow of it, since Sparkle's window has a checkbox that writes it too.
    var automaticallyUpdates: () -> Bool = { false }
    var setAutomaticallyUpdates: (Bool) -> Void = { _ in }
    /// Whether Settings offers that switch: not in an isolated process,
    /// whose Sparkle shares the user's defaults domain.
    var offersAutomaticUpdates = false

    static let feedKey = "SUFeedURL"

    /// The feed this process checks, or nil for no updater at all.
    static func feed(info: [String: Any], environment: [String: String]) -> String? {
        if let forced = environment["EVLAT_FEED"], !forced.isEmpty { return forced }
        if Isolation.isIsolated(environment) { return nil }
        guard let feed = info[feedKey] as? String, !feed.isEmpty else { return nil }
        return feed
    }

    /// The real updater, started. Sparkle checks on its own schedule (hourly,
    /// `SUScheduledCheckInterval`), so nobody is asked on the second launch;
    /// what it finds is shown by `UpdateReminder`'s rule. `defaults` keeps
    /// that rule's memory; nil keeps it for this process only.
    @MainActor
    static func sparkle(feed: String, defaults: UserDefaults?) -> Updater {
        let delegate = SparkleDelegate(feed: feed, store: UpdateReminder.Store(defaults: defaults))
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate,
                                                      userDriverDelegate: delegate)
        delegate.show = { controller.checkForUpdates(nil) }
        // The closures hold both: Sparkle keeps only weak delegates.
        return Updater(check: { [delegate] in
                           _ = delegate
                           controller.checkForUpdates(nil)
                       },
                       pendingVersion: { [delegate] in delegate.pending },
                       automaticallyUpdates: { controller.updater.automaticallyDownloadsUpdates },
                       setAutomaticallyUpdates: { on in
                           guard defaults != nil else { return }
                           controller.updater.automaticallyDownloadsUpdates = on
                       },
                       offersAutomaticUpdates: defaults != nil)
    }

    /// Hands Sparkle the feed chosen above, so `EVLAT_FEED` wins over the
    /// plist, and takes over when a scheduled check's window opens: Sparkle
    /// asks again at every check, so an update put off is held quietly until
    /// `UpdateReminder` says a day has passed. While Sparkle holds a window
    /// it checks nothing more, so the day's end is Evlat's own timer.
    @MainActor
    private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
        let feed: String
        let store: UpdateReminder.Store
        /// Brings the held window forward (a user-initiated check does).
        var show: () -> Void = {}
        /// The version a window is held for, else one downloaded and waiting
        /// for Evlat to quit (kept: the install is still ahead).
        var pending: String? { held ?? readyOnQuit }
        private var held: String?
        private var readyOnQuit: String?
        private var timer: Timer?
        /// The app in front when the timer brought the window forward; it
        /// gets the keyboard back when the window is answered.
        private var previous: NSRunningApplication?

        init(feed: String, store: UpdateReminder.Store) {
            self.feed = feed
            self.store = store
        }

        nonisolated func feedURLString(for updater: SPUUpdater) -> String? { feed }

        /// A download waiting for Evlat to quit is pending too: the menu line
        /// brings its "install and relaunch" window. Sparkle carries on.
        nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
            let version = item.displayVersionString
            MainActor.assumeIsolated { readyOnQuit = version }
            return false
        }

        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

        /// A version not put off is Sparkle's to show, its own way for a
        /// background app: drawn without taking the keyboard. One put off
        /// within the day is held; reading the store changes nothing.
        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
            let version = update.displayVersionString
            return MainActor.assumeIsolated { UpdateReminder.wait(for: version, last: store.shown, now: Date()) == 0 }
        }

        nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                                  state: SPUUserUpdateState) {
            let version = update.displayVersionString
            MainActor.assumeIsolated {
                held = version
                guard !handleShowingUpdate else {
                    // Sparkle draws it now: that is a showing.
                    store.shown = UpdateReminder.Shown(version: version, at: Date())
                    return
                }
                let wait = UpdateReminder.wait(for: version, last: store.shown, now: Date())
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.bringForward(version) }
                }
            }
        }

        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            let version = update.displayVersionString
            MainActor.assumeIsolated { store.shown = UpdateReminder.Shown(version: version, at: Date()) }
        }

        nonisolated func standardUserDriverWillFinishUpdateSession() {
            MainActor.assumeIsolated {
                timer?.invalidate()
                timer = nil
                held = nil
                if let previous, NSApp.isActive { WindowStage.activate(previous) }
                previous = nil
            }
        }

        /// The timer's end: only the window still held, never a new check
        /// (which would say "up to date" out of nowhere).
        private func bringForward(_ version: String) {
            timer = nil
            guard held == version else { return }
            store.shown = UpdateReminder.Shown(version: version, at: Date())
            let front = NSWorkspace.shared.frontmostApplication
            previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            show()
        }
    }
}

/// When a found update's window opens: at once for a version not shown
/// before, else a day after it was last shown. The window's "Remind Me Later"
/// only ends Sparkle's session, and the next hourly check would ask again.
enum UpdateReminder {
    static let interval: TimeInterval = 24 * 60 * 60

    struct Shown: Equatable {
        var version: String
        var at: Date
    }

    /// Seconds until the window may open; 0 is now.
    static func wait(for version: String, last: Shown?, now: Date) -> TimeInterval {
        guard let last, last.version == version else { return 0 }
        return max(0, last.at.addingTimeInterval(interval).timeIntervalSince(now))
    }

    /// The last showing, kept in `defaults` across launches, or in memory.
    @MainActor
    final class Store {
        static let versionKey = "update.shown.version"
        static let dateKey = "update.shown.at"
        private let defaults: UserDefaults?
        private var memory: Shown?

        init(defaults: UserDefaults?) { self.defaults = defaults }

        var shown: Shown? {
            get {
                guard let defaults else { return memory }
                guard let version = defaults.string(forKey: Self.versionKey),
                      let at = defaults.object(forKey: Self.dateKey) as? Date else { return nil }
                return Shown(version: version, at: at)
            }
            set {
                guard let defaults else { memory = newValue; return }
                defaults.set(newValue?.version, forKey: Self.versionKey)
                defaults.set(newValue?.at, forKey: Self.dateKey)
            }
        }
    }
}
