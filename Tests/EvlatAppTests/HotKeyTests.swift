import XCTest
import AppKit
import Carbon.HIToolbox
@testable import EvlatApp

/// The balloon's shortcut (`011/phase-2`): a Carbon hot key, which asks for
/// no permission, its stored switch and its menu entry.
///
/// No test registers ⌥Space itself: that would take the user's shortcut for
/// as long as the suite runs. The real registration is tried on a
/// combination nobody uses; the controller's is a fake.
@MainActor
final class HotKeyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "evlat.tests.hotkey.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// ⌃⌥⌘F19: a combination no one holds.
    private static let unused = (key: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey))

    func testTheDefaultIsOptionSpace() {
        let hotKey = HotKey()
        XCTAssertEqual(hotKey.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(hotKey.modifiers, UInt32(optionKey))
    }

    /// Measured (`phase-2`): another **process** holding the combination
    /// does not fail the call; the same one twice does. That second case is
    /// the one reproducible failure, and the menu's line is built for it.
    func testRegisteringTwiceIsRefusedAndUnregisteringFreesIt() {
        let first = HotKey(keyCode: Self.unused.key, modifiers: Self.unused.modifiers)
        let second = HotKey(keyCode: Self.unused.key, modifiers: Self.unused.modifiers)
        defer {
            first.unregister()
            second.unregister()
        }
        XCTAssertEqual(first.register(), noErr)
        XCTAssertEqual(first.register(), noErr, "registering again is a no-op")
        XCTAssertEqual(second.register(), OSStatus(eventHotKeyExistsErr))
        first.unregister()
        XCTAssertEqual(second.register(), noErr, "unregistering frees the combination")
    }

    // MARK: - The switch and the menu

    private final class FakeHotKey: HotKeyRegistration {
        var status: OSStatus = noErr
        var registered = false
        var registrations = 0
        func register() -> OSStatus {
            registrations += 1
            registered = status == noErr
            return status
        }
        func unregister() { registered = false }
    }

    private func controller(_ fake: FakeHotKey) -> AppController {
        let controller = AppController(defaults: defaults)
        controller.installPanel()
        controller.hotKey = fake
        controller.applyHotKey()
        return controller
    }

    private func entry(_ menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.action == #selector(AppController.toggleHotKey(_:)) })
    }

    func testTheShortcutIsOnUnlessTurnedOff() {
        XCTAssertTrue(AppController.hotKeyEnabled(defaults), "nothing stored: on")
        XCTAssertTrue(AppController.hotKeyEnabled(nil))
        defaults.set(false, forKey: AppController.hotKeyKey)
        XCTAssertFalse(AppController.hotKeyEnabled(defaults))
        XCTAssertEqual(AppController.hotKeyKey, "chat.hotkey")
    }

    func testBothMenusCarryTheEntryAndItsMark() throws {
        let fake = FakeHotKey()
        let controller = controller(fake)
        defer { controller.panel?.close() }
        XCTAssertTrue(fake.registered)
        for diagnostics in [false, true] {
            let menu = controller.makeMenu(diagnostics: diagnostics, in: "en")
            let item = try entry(menu)
            XCTAssertEqual(item.title, "Shortcut ⌥Space")
            XCTAssertEqual(item.state, .on)
            XCTAssertEqual(menu.items.firstIndex(of: item), 1, "under the edge")
        }
        XCTAssertEqual(try entry(controller.makeMenu(diagnostics: false, in: "tr")).title, "Kısayol ⌥Space")
    }

    func testTheEntryTurnsTheShortcutOffAndOnAndTakesNoFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fake = FakeHotKey()
        let controller = controller(fake)
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        menu.performActionForItem(at: menu.index(of: try entry(menu)))
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, false)
        XCTAssertFalse(fake.registered)
        XCTAssertEqual(try entry(controller.makeMenu(diagnostics: false, in: "en")).state, .off)
        let again = controller.makeMenu(diagnostics: false, in: "en")
        again.performActionForItem(at: again.index(of: try entry(again)))
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, true)
        XCTAssertTrue(fake.registered)
        XCTAssertFalse(NSApp.isActive)
    }

    /// A refused registration: one dim line under the entry, the number
    /// Carbon gave, until a registration succeeds. It does not guess who
    /// holds the key — Carbon does not say (measured, `phase-2`).
    func testARefusedRegistrationLeavesOneDimLine() throws {
        let fake = FakeHotKey()
        fake.status = OSStatus(eventHotKeyExistsErr)
        let controller = controller(fake)
        defer { controller.panel?.close() }
        let menu = controller.makeMenu(diagnostics: false, in: "en")
        let index = menu.index(of: try entry(menu))
        let line = menu.items[index + 1]
        XCTAssertFalse(line.isEnabled)
        XCTAssertEqual(line.title, "Could not register the shortcut (\(eventHotKeyExistsErr))")
        XCTAssertEqual(line.indentationLevel, 1)

        fake.status = noErr
        controller.applyHotKey()
        let fixed = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertFalse(fixed.items[fixed.index(of: try entry(fixed)) + 1].title.hasPrefix("Could not"))

        fake.status = OSStatus(eventHotKeyExistsErr)
        defaults.set(false, forKey: AppController.hotKeyKey)
        controller.applyHotKey()
        let off = controller.makeMenu(diagnostics: false, in: "en")
        XCTAssertFalse(off.items[off.index(of: try entry(off)) + 1].title.hasPrefix("Could not"),
                       "turned off, there is no failure to show")
    }

    /// The press reaches the balloon: open, then closed.
    func testThePressTogglesTheBalloon() {
        let controller = AppController(defaults: defaults)
        controller.installPanel()
        defer {
            controller.closeChat()
            controller.chatPanel?.close()
            controller.panel?.close()
        }
        controller.hotKeyPressed()
        XCTAssertTrue(controller.isChatOpen)
        controller.hotKeyPressed()
        XCTAssertFalse(controller.isChatOpen)
    }
}
