import XCTest
import AppKit
@testable import EvlatApp

/// Who gets an updater, and the menu line it brings. Sparkle itself is never
/// started here.
@MainActor
final class UpdaterTests: XCTestCase {
    private let feed = "https://example.invalid/appcast.xml"

    func testOnlyABundleWithAFeedHasAnUpdater() {
        XCTAssertEqual(Updater.feed(info: [Updater.feedKey: feed], environment: [:]), feed)
        XCTAssertNil(Updater.feed(info: [:], environment: [:]), "a development build has no feed")
        XCTAssertNil(Updater.feed(info: [Updater.feedKey: ""], environment: [:]))
    }

    func testAnIsolatedLaunchChecksNothingUnlessAFeedIsNamed() {
        XCTAssertNil(Updater.feed(info: [Updater.feedKey: feed], environment: ["EVLAT_PORT": "48999"]))
        XCTAssertEqual(Updater.feed(info: [Updater.feedKey: feed],
                                    environment: ["EVLAT_PORT": "48999", "EVLAT_FEED": "http://localhost:8000/a.xml"]),
                       "http://localhost:8000/a.xml")
        XCTAssertEqual(Updater.feed(info: [:], environment: ["EVLAT_FEED": "http://localhost:8000/a.xml"]),
                       "http://localhost:8000/a.xml")
    }

    func testTheMenuLineComesWithTheUpdaterAndCallsIt() throws {
        _ = NSApplication.shared
        let plain = AppController(defaults: nil, home: nil)
        XCTAssertFalse(plain.makeMenu(diagnostics: false, in: "en").items.map(\.title).contains("Check for Updates…"))

        var checks = 0
        let controller = AppController(defaults: nil, home: nil, loginItem: nil,
                                       updater: Updater(check: { checks += 1 }))
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(Array(titles.suffix(3)), ["Setup…", "Check for Updates…", "Quit Evlat"])
        let item = try XCTUnwrap(menu.items.first { $0.title == "Check for Updates…" })
        _ = (item.target as AnyObject).perform(item.action, with: item)
        XCTAssertEqual(checks, 1)
    }

    func testThePutOffUpdateIsSaidOnTheSameLine() throws {
        _ = NSApplication.shared
        var checks = 0
        let controller = AppController(defaults: nil, home: nil, loginItem: nil,
                                       updater: Updater(check: { checks += 1 }, pendingVersion: { "0.9.0" }))
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(Array(titles.suffix(3)), ["Setup…", "Update Available: 0.9.0…", "Quit Evlat"])
        let item = try XCTUnwrap(menu.items.first { $0.title == "Update Available: 0.9.0…" })
        _ = (item.target as AnyObject).perform(item.action, with: item)
        XCTAssertEqual(checks, 1, "the same click brings the held window")
    }

    func testAVersionIsShownAtOnceThenADayAfterItWasLastShown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UpdateReminder.wait(for: "0.9.0", last: nil, now: now), 0, "never shown")
        let shown = UpdateReminder.Shown(version: "0.9.0", at: now.addingTimeInterval(-3600))
        XCTAssertEqual(UpdateReminder.wait(for: "0.9.0", last: shown, now: now), 23 * 3600,
                       "put off an hour ago: the next hourly check holds it")
        XCTAssertEqual(UpdateReminder.wait(for: "0.9.1", last: shown, now: now), 0, "a newer version is news")
        let old = UpdateReminder.Shown(version: "0.9.0", at: now.addingTimeInterval(-25 * 3600))
        XCTAssertEqual(UpdateReminder.wait(for: "0.9.0", last: old, now: now), 0)
    }

    func testTheLastShowingOutlivesTheProcessOnlyWithDefaults() throws {
        let suite = "evlat.updater.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shown = UpdateReminder.Shown(version: "0.9.0", at: Date(timeIntervalSince1970: 1_000_000))
        UpdateReminder.Store(defaults: defaults).shown = shown
        XCTAssertEqual(UpdateReminder.Store(defaults: defaults).shown, shown)

        let memory = UpdateReminder.Store(defaults: nil)
        memory.shown = shown
        XCTAssertEqual(memory.shown, shown)
        XCTAssertNil(UpdateReminder.Store(defaults: nil).shown, "an isolated process keeps it to itself")
    }
}
