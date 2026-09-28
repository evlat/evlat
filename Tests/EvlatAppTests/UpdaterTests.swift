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
}
