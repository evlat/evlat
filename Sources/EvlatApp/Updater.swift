import Foundation
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

    static let feedKey = "SUFeedURL"

    /// The feed this process checks, or nil for no updater at all.
    static func feed(info: [String: Any], environment: [String: String]) -> String? {
        if let forced = environment["EVLAT_FEED"], !forced.isEmpty { return forced }
        if Isolation.isIsolated(environment) { return nil }
        guard let feed = info[feedKey] as? String, !feed.isEmpty else { return nil }
        return feed
    }

    /// The real updater, started: it checks on Sparkle's own schedule (daily,
    /// `SUEnableAutomaticChecks`), so nobody is asked on the second launch.
    @MainActor
    static func sparkle(feed: String) -> Updater {
        let delegate = FeedDelegate(feed: feed)
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate,
                                                      userDriverDelegate: nil)
        // The closure holds both: Sparkle keeps only a weak delegate.
        return Updater(check: { [delegate] in
            _ = delegate
            controller.checkForUpdates(nil)
        })
    }

    /// Hands Sparkle the feed chosen above, so `EVLAT_FEED` wins over the plist.
    private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
        let feed: String
        init(feed: String) { self.feed = feed }
        func feedURLString(for updater: SPUUpdater) -> String? { feed }
    }
}
