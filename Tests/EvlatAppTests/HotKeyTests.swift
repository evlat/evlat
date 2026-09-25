import XCTest
import AppKit
import Carbon.HIToolbox
@testable import EvlatApp

/// The balloon's shortcut (`011/phase-2`): a Carbon hot key, which asks for
/// no permission, its stored switch and its menu entry.
///
/// No test registers ⇧⌘Space itself: that would take the user's shortcut for
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
    private static let unused = HotKeyCombination(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .command])

    /// ⇧⌘Space, not ⌥Space: on this machine ⌥Space is Claude.app's,
    /// ChatGPT's and Gemini's too, and one press opened two apps.
    func testTheDefaultIsShiftCommandSpace() {
        XCTAssertEqual(HotKeyCombination.standard.keyCode, UInt16(kVK_Space))
        XCTAssertEqual(HotKeyCombination.standard.modifiers, [.shift, .command])
        XCTAssertEqual(HotKeyCombination.standard.carbonModifiers, UInt32(shiftKey | cmdKey))
        XCTAssertEqual(HotKeyCombination.standard.title, "⇧⌘Space")
        XCTAssertEqual(AppController.storedHotKey(defaults), .standard, "nothing stored")
        XCTAssertEqual(AppController.storedHotKey(nil), .standard)
    }

    /// ⌘ alone (or ⇧⌘) is offered only with Space and the F-keys.
    func testCommandWithACharacterKeyIsAnAppShortcut() {
        func combination(_ code: Int, _ flags: NSEvent.ModifierFlags) -> HotKeyCombination {
            HotKeyCombination(keyCode: UInt16(code), modifiers: flags)
        }
        XCTAssertTrue(combination(kVK_ANSI_V, [.command]).takesAnAppShortcut)
        XCTAssertTrue(combination(kVK_ANSI_Q, [.command]).takesAnAppShortcut)
        XCTAssertTrue(combination(kVK_ANSI_Z, [.command, .shift]).takesAnAppShortcut)
        XCTAssertTrue(combination(kVK_Tab, [.command]).takesAnAppShortcut)
        XCTAssertFalse(HotKeyCombination.standard.takesAnAppShortcut)
        XCTAssertFalse(combination(kVK_F6, [.command]).takesAnAppShortcut)
        XCTAssertFalse(combination(kVK_ANSI_V, [.command, .option]).takesAnAppShortcut)
        XCTAssertFalse(combination(kVK_ANSI_V, [.control]).takesAnAppShortcut)
    }

    func testTheTitleWritesTheModifiersInMacOSsOrder() {
        let all = HotKeyCombination(keyCode: UInt16(kVK_F5), modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(all.title, "⌃⌥⇧⌘F5")
        XCTAssertEqual(all.carbonModifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(HotKeyCombination(keyCode: UInt16(kVK_UpArrow), modifiers: [.control, .function]).title,
                       "⌃↑", "a device bit is not a modifier")
    }

    /// Stored under its own key; the old switch keeps what it held.
    func testTheCombinationIsStoredUnderItsOwnKey() {
        XCTAssertEqual(AppController.hotKeyCombinationKey, "chat.hotkey.combination")
        let combination = HotKeyCombination(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        defaults.set(combination.stored, forKey: AppController.hotKeyCombinationKey)
        XCTAssertEqual(AppController.storedHotKey(defaults), combination)
        for broken: Any in ["⌥Space", ["keyCode": 49], ["keyCode": 49, "modifiers": Int(NSEvent.ModifierFlags.shift.rawValue)],
                            ["keyCode": -1, "modifiers": Int(NSEvent.ModifierFlags.command.rawValue)]] {
            defaults.set(broken, forKey: AppController.hotKeyCombinationKey)
            XCTAssertEqual(AppController.storedHotKey(defaults), .standard, "\(broken): the default stands")
        }
    }

    /// Measured (`phase-2`): another **process** holding the combination
    /// does not fail the call; the same one twice does. That second case is
    /// the one reproducible failure, and the menu's line is built for it.
    func testRegisteringTwiceIsRefusedAndUnregisteringFreesIt() {
        let first = HotKey()
        let second = HotKey()
        defer {
            first.unregister()
            second.unregister()
        }
        XCTAssertEqual(first.register(Self.unused), noErr)
        XCTAssertEqual(first.register(Self.unused), noErr, "registering again is a no-op")
        XCTAssertEqual(second.register(Self.unused), OSStatus(eventHotKeyExistsErr))
        first.unregister()
        XCTAssertEqual(second.register(Self.unused), noErr, "unregistering frees the combination")
    }

    /// A new combination replaces the old: the old one is free again.
    func testRegisteringAnotherCombinationFreesTheFirst() {
        let other = HotKeyCombination(keyCode: UInt16(kVK_F18), modifiers: [.control, .option, .command])
        let hotKey = HotKey()
        let probe = HotKey()
        defer {
            hotKey.unregister()
            probe.unregister()
        }
        XCTAssertEqual(hotKey.register(Self.unused), noErr)
        XCTAssertEqual(hotKey.register(other), noErr)
        XCTAssertEqual(hotKey.combination, other)
        XCTAssertEqual(probe.register(Self.unused), noErr, "the first combination was let go")
    }

    // MARK: - The switch and the menu

    private final class FakeHotKey: HotKeyRegistration {
        var status: OSStatus = noErr
        var registered: HotKeyCombination?
        var registrations = 0
        func register(_ combination: HotKeyCombination) -> OSStatus {
            registrations += 1
            registered = status == noErr ? combination : nil
            return status
        }
        func unregister() { registered = nil }
    }

    private func controller(_ fake: FakeHotKey) -> AppController {
        let controller = AppController(defaults: defaults)
        controller.installPanel()
        controller.hotKey = fake
        controller.applyHotKey()
        return controller
    }

    /// The shortcut's entry: the one whose submenu turns it off or on.
    private func entry(_ menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first {
            $0.submenu?.items.contains { $0.action == #selector(AppController.toggleHotKey(_:)) } == true
        })
    }

    private func perform(_ selector: Selector, in menu: NSMenu) throws {
        let actions = try XCTUnwrap(try entry(menu).submenu)
        actions.performActionForItem(at: try XCTUnwrap(actions.items.firstIndex { $0.action == selector }))
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
        XCTAssertEqual(fake.registered, .standard)
        for diagnostics in [false, true] {
            let menu = controller.makeMenu(diagnostics: diagnostics, in: "en")
            let item = try entry(menu)
            XCTAssertEqual(item.title, "Shortcut: ⇧⌘Space")
            XCTAssertEqual(item.state, .on)
            XCTAssertEqual(menu.items.firstIndex(of: item), 1, "under the edge")
            XCTAssertEqual(item.submenu?.items.map(\.title), ["Change…", "Turn Off"])
        }
        let turkish = try entry(controller.makeMenu(diagnostics: false, in: "tr"))
        XCTAssertEqual(turkish.title, "Kısayol: ⇧⌘Space")
        XCTAssertEqual(turkish.submenu?.items.map(\.title), ["Değiştir…", "Kapat"])
    }

    func testTheEntryTurnsTheShortcutOffAndOnAndTakesNoFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fake = FakeHotKey()
        let controller = controller(fake)
        defer { controller.panel?.close() }
        try perform(#selector(AppController.toggleHotKey(_:)), in: controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, false)
        XCTAssertNil(fake.registered)
        let off = try entry(controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(off.state, .off)
        XCTAssertEqual(off.submenu?.items.map(\.title), ["Change…", "Turn On"])
        try perform(#selector(AppController.toggleHotKey(_:)), in: controller.makeMenu(diagnostics: false, in: "en"))
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, true)
        XCTAssertEqual(fake.registered, .standard)
        XCTAssertFalse(NSApp.isActive)
    }

    /// A refused registration: one attention line (`014`), dim but live —
    /// it opens the settings at the chat section — until a registration
    /// succeeds or the shortcut is turned off.
    func testARefusedRegistrationLeavesOneAttentionLine() throws {
        let fake = FakeHotKey()
        fake.status = OSStatus(eventHotKeyExistsErr)
        let controller = controller(fake)
        defer { controller.panel?.close() }
        func lines() -> [NSMenuItem] {
            controller.makeMenu(diagnostics: false, in: "en").items.filter { $0.representedObject is SetupAttention }
        }
        let line = try XCTUnwrap(lines().first)
        XCTAssertEqual(line.title, "The shortcut is not registered")
        XCTAssertTrue(line.isEnabled)
        XCTAssertEqual(line.action, #selector(AppController.openAttention(_:)))
        XCTAssertEqual((line.representedObject as? SetupAttention)?.section, .chat)

        fake.status = noErr
        controller.applyHotKey()
        XCTAssertEqual(lines(), [])

        fake.status = OSStatus(eventHotKeyExistsErr)
        defaults.set(false, forKey: AppController.hotKeyKey)
        controller.applyHotKey()
        XCTAssertEqual(lines(), [], "turned off, there is no failure to show")
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

    // MARK: - The system's shortcuts

    /// Shaped as `com.apple.symbolichotkeys` holds them (read from this
    /// machine): `[character, keyCode, modifiers]`, arrows with the device bit.
    private static let system: [String: Any] = [
        "61": ["enabled": true, "value": ["parameters": [32, 49, 786_432], "type": "standard"]],
        "64": ["enabled": true, "value": ["parameters": [65_535, 49, 1_048_576], "type": "standard"]],
        "32": ["enabled": true, "value": ["parameters": [65_535, 126, 8_650_752], "type": "standard"]],
        "119": ["enabled": false, "value": ["parameters": [65_535, 19, 262_144], "type": "standard"]],
        "160": ["enabled": false, "value": ["parameters": [65_535, 65_535, 0], "type": "standard"]],
        "176": ["enabled": false],
        "999": ["enabled": 1, "value": ["parameters": [107, 40, 1_179_648], "type": "standard"]],
    ]

    func testAnEnabledSystemShortcutIsFoundAndADisabledOneIsNot() {
        let table = SystemHotKeys(entries: Self.system)
        let space = UInt16(kVK_Space)
        XCTAssertEqual(table.conflict(with: HotKeyCombination(keyCode: space, modifiers: [.control, .option])), 61)
        XCTAssertEqual(table.conflict(with: HotKeyCombination(keyCode: space, modifiers: [.command])), 64)
        XCTAssertEqual(table.conflict(with: HotKeyCombination(keyCode: UInt16(kVK_UpArrow),
                                                              modifiers: [.control, .function, .numericPad])), 32,
                       "the arrow's device bits are masked on both sides")
        XCTAssertEqual(table.conflict(with: HotKeyCombination(keyCode: UInt16(kVK_ANSI_K), modifiers: [.shift, .command])),
                       999, "a numeric `enabled`")
        XCTAssertNil(table.conflict(with: HotKeyCombination(keyCode: UInt16(kVK_ANSI_2), modifiers: [.control])),
                     "disabled")
        XCTAssertNil(table.conflict(with: .standard), "⇧⌘Space is not the system's")
        XCTAssertNil(SystemHotKeys(entries: [:]).conflict(with: .standard))
        XCTAssertEqual(SystemHotKeys.nameKey(61), "hotkey.system.inputSource")
        XCTAssertEqual(SystemHotKeys.nameKey(999), "hotkey.system.other")
    }

    func testEveryRecorderTextIsInBothTables() {
        let keys = SystemHotKeys.nameKeys + ["hotkey.recorder.hint", "hotkey.recorder.needsModifier",
                                             "hotkey.recorder.appShortcut",
                                             "hotkey.recorder.system"]
        for lang in ["en", "tr"] {
            for key in keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
        XCTAssertEqual(Set((0...200).map(SystemHotKeys.nameKey)), Set(SystemHotKeys.nameKeys))
    }

    // MARK: - The recorder (Settings → Chat's row, `014/phase-2`)

    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: UInt16(code)))
    }

    /// The rules, apart from any window.
    func testTheClassifierRefusesWhatCannotBeAShortcut() {
        let system = SystemHotKeys(entries: Self.system)
        func verdict(_ code: Int, _ flags: NSEvent.ModifierFlags) -> HotKeyVerdict {
            HotKeyVerdict.classify(keyCode: UInt16(code), modifiers: flags, system: system)
        }
        XCTAssertEqual(verdict(kVK_Escape, []), .cancel)
        XCTAssertEqual(verdict(kVK_Escape, [.command]), .cancel)
        XCTAssertEqual(verdict(kVK_ANSI_K, []), .needsModifier)
        XCTAssertEqual(verdict(kVK_ANSI_K, [.shift]), .needsModifier, "⇧ alone types capitals")
        XCTAssertEqual(verdict(kVK_ANSI_V, [.command]),
                       .appShortcut(HotKeyCombination(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command])))
        XCTAssertEqual(verdict(kVK_ANSI_Z, [.command, .shift]),
                       .appShortcut(HotKeyCombination(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift])))
        let optionControlSpace = HotKeyCombination(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])
        XCTAssertEqual(verdict(kVK_Space, [.control, .option]), .system(optionControlSpace, id: 61))
        XCTAssertEqual(verdict(kVK_F5, [.control, .option, .function]),
                       .accept(HotKeyCombination(keyCode: UInt16(kVK_F5), modifiers: [.control, .option])))
        XCTAssertEqual(verdict(kVK_Space, [.command, .shift]), .accept(.standard))
    }

    private func recording(_ fake: FakeHotKey) throws -> AppController {
        let controller = controller(fake)
        controller.settingsActivation = { }
        controller.systemHotKeys = { SystemHotKeys(entries: Self.system) }
        controller.recordHotKey(nil)
        return controller
    }

    /// Change… opens Settings at Chat, recording; the shortcut is let go
    /// while it listens, and comes back when it ends.
    func testChangeOpensTheSettingsAtChatRecordingAndLetsTheShortcutGo() throws {
        let fake = FakeHotKey()
        let controller = try recording(fake)
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        XCTAssertEqual(controller.settings?.section, .chat)
        XCTAssertTrue(try XCTUnwrap(controller.settingsWindow).isVisible)
        XCTAssertTrue(controller.hotKeyRecorder.isRecording)
        XCTAssertNil(fake.registered, "a registered key would never reach the recorder")
        controller.hotKeyRecorder.cancel()
        XCTAssertEqual(fake.registered, .standard, "a cancel registers the kept one again")
        XCTAssertFalse(try XCTUnwrap(controller.panel).isKeyWindow, "the bar is never key")
    }

    /// The keys arrive through the settings window: a refusal keeps it
    /// recording, a good one is stored, registered and named by the menu.
    func testASystemShortcutIsRefusedAndAnotherIsStored() throws {
        let fake = FakeHotKey()
        let controller = try recording(fake)
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        let window = try XCTUnwrap(controller.settingsWindow?.window)
        window.sendEvent(try key(kVK_Space, [.control, .option]))
        let recorder = controller.hotKeyRecorder
        XCTAssertTrue(recorder.isRecording, "refused, not stored")
        XCTAssertEqual(recorder.text(in: "en")?.0,
                       "macOS uses ⌃⌥Space for switching input sources. Press another · Esc cancels")
        window.sendEvent(try key(kVK_ANSI_K, [.shift]))
        XCTAssertEqual(recorder.line, .needsModifier)
        XCTAssertNil(defaults.object(forKey: AppController.hotKeyCombinationKey))

        let chosen = HotKeyCombination(keyCode: UInt16(kVK_F5), modifiers: [.control, .option])
        window.sendEvent(try key(kVK_F5, [.control, .option, .function]))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(AppController.storedHotKey(defaults), chosen)
        XCTAssertEqual(fake.registered, chosen)
        XCTAssertEqual(try entry(controller.makeMenu(diagnostics: false, in: "en")).title, "Shortcut: ⌃⌥F5")
    }

    /// Esc while recording cancels the recording, not the window; losing
    /// the keyboard cancels too; a recorded one turns an off shortcut on.
    func testEscCancelsTheRecordingAndKeepsTheWindow() throws {
        let fake = FakeHotKey()
        defaults.set(false, forKey: AppController.hotKeyKey)
        let controller = try recording(fake)
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        let window = try XCTUnwrap(controller.settingsWindow?.window)
        window.sendEvent(try key(kVK_Escape))
        XCTAssertFalse(controller.hotKeyRecorder.isRecording)
        XCTAssertTrue(window.isVisible, "Esc was the recorder's")
        XCTAssertNil(fake.registered, "off stays off")

        controller.recordHotKey(nil)
        window.resignKey()
        XCTAssertFalse(controller.hotKeyRecorder.isRecording, "losing the keyboard cancels")

        controller.recordHotKey(nil)
        window.sendEvent(try key(kVK_ANSI_J, [.command, .option]))
        XCTAssertEqual(defaults.object(forKey: AppController.hotKeyKey) as? Bool, true)
        XCTAssertEqual(fake.registered, HotKeyCombination(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option]))

        window.sendEvent(try key(kVK_Escape))
        XCTAssertFalse(window.isVisible, "not recording: Esc closes")
    }

    /// Change… closes the balloon: one window has the keyboard.
    func testTheRecorderClosesTheBalloon() throws {
        let fake = FakeHotKey()
        let controller = controller(fake)
        controller.settingsActivation = { }
        defer {
            controller.settingsWindow?.close()
            controller.chatPanel?.close()
            controller.panel?.close()
        }
        controller.systemHotKeys = { SystemHotKeys(entries: [:]) }
        controller.openChat()
        XCTAssertTrue(controller.isChatOpen)
        controller.recordHotKey(nil)
        XCTAssertFalse(controller.isChatOpen)
        XCTAssertTrue(controller.hotKeyRecorder.isRecording)
    }
}

extension HotKeyTests {
    /// Leaving Chat stops the recording; a recorded shortcut's refusal
    /// shows at once, without reopening the window.
    func testLeavingChatStopsTheRecordingAndARefusalShowsAtOnce() throws {
        let fake = FakeHotKey()
        let controller = controller(fake)
        controller.settingsActivation = { }
        controller.systemHotKeys = { SystemHotKeys(entries: [:]) }
        defer {
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        controller.recordHotKey(nil)
        controller.settings?.section = .remote
        XCTAssertFalse(controller.hotKeyRecorder.isRecording)
        XCTAssertEqual(fake.registered, .standard)

        controller.settings?.section = .chat
        controller.recordHotKey(nil)
        fake.status = OSStatus(eventHotKeyExistsErr)
        let window = try XCTUnwrap(controller.settingsWindow?.window)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_J))))
        XCTAssertEqual(controller.settings?.dots, [.chat], "the refusal is a dot while the window is open")
    }
}
