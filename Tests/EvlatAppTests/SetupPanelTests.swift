import XCTest
import AppKit
import Carbon.HIToolbox
import EvlatCore
@testable import EvlatApp

/// The setup's panel beside the mascot: the machine-verifiable half of "it
/// takes the keyboard, stays where it is put, and nothing else". Like the
/// balloon it never makes Evlat the active app and the bar never takes focus;
/// unlike it, it stays when the keyboard goes elsewhere and when Esc is
/// pressed, and goes with the bar. Whether the user's real click and key leave
/// the app in front in front is looked at by eye (`ChatPanelTests`' split).
@MainActor
final class SetupPanelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // The app's own policy: under the test runner's default `.prohibited`
        // nothing could activate, and "did not activate" would prove nothing.
        NSApplication.shared.setActivationPolicy(.accessory)
        suiteName = "evlat.tests.setuppanel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func controller(edge: BarPanel.Edge = .right, frontmost: Bool = true) -> AppController {
        let controller = AppController(defaults: defaults)
        controller.installPanel(edge: edge)
        controller.isFrontmost = { frontmost }
        controller.hover.onChange = { [unowned controller] open in
            open ? controller.openBar() : controller.closeBar()
        }
        return controller
    }

    private func close(_ controller: AppController) {
        controller.closeSetup()
        controller.setupPanel?.close()
        controller.closeChat()
        controller.chatPanel?.close()
        controller.panel?.close()
    }

    private var front: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// "Evlat was not brought forward", as the system sees it (see
    /// `ChatPanelTests`: not `NSApp.isActive`, which a key panel makes true).
    private func assertNotBroughtForward(_ front: pid_t?, _ message: String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(NSRunningApplication.current.isActive, message, file: file, line: line)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front,
                       "the app in front stays in front \(message)", file: file, line: line)
        XCTAssertNotEqual(NSWorkspace.shared.menuBarOwningApplication?.processIdentifier,
                          ProcessInfo.processInfo.processIdentifier, message, file: file, line: line)
    }

    /// A point on the drawn bar, in the content view's coordinates.
    private func onBar(_ controller: AppController, fromEdge x: CGFloat, fromTop y: CGFloat) throws -> CGPoint {
        let panel = try XCTUnwrap(controller.panel)
        let bounds = try XCTUnwrap(panel.contentView?.bounds)
        return CGPoint(x: panel.edge.x(atInset: x, in: bounds), y: bounds.minY + AppController.headroom + y)
    }

    private func key(_ code: Int, characters: String, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    // MARK: - Focus

    func testThePanelTakesTheKeyboardAndTheBarStillDoesNot() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openSetup()
        let panel = try XCTUnwrap(controller.setupPanel)
        XCTAssertTrue(panel.canBecomeKey, "the setup is typed into")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "without it taking the keyboard would bring Evlat forward")
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.hidesOnDeactivate, "it stays when another app is in front")
        let bar = try XCTUnwrap(controller.panel)
        XCTAssertFalse(bar.canBecomeKey, "the bar never takes focus, setup or not")
        XCTAssertEqual(panel.level, bar.level, "above the other apps, at the bar's level")
        XCTAssertEqual(panel.collectionBehavior, bar.collectionBehavior)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), true,
                       "the click that brings the keyboard presses the button under it")
    }

    func testOpeningItFromTheMenuTakesTheKeyboardAndNotTheApp() throws {
        let controller = controller(frontmost: false)
        defer { close(controller) }
        controller.panel?.show()
        XCTAssertFalse(NSApp.isActive, "precondition: Evlat is not the active app")
        let before = front
        XCTAssertNotEqual(before, ProcessInfo.processInfo.processIdentifier, "precondition")
        let forward = WindowStage.forwardWindows
        controller.openSetupFromMenu(nil)
        let panel = try XCTUnwrap(controller.setupPanel)
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isKeyWindow, "asked for by the user: the keyboard comes with it")
        assertNotBroughtForward(before, "the setup takes the keyboard, never the app")
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "no icon in the Dock")
        XCTAssertEqual(WindowStage.forwardWindows, forward, "it is not a window that brings Evlat forward")
        XCTAssertFalse(try XCTUnwrap(controller.panel).isKeyWindow, "the bar is never key")
        controller.closeSetup()
        XCTAssertFalse(panel.isKeyWindow)
        assertNotBroughtForward(before)
    }

    /// A setup that opens by itself would otherwise take the Return the user
    /// types into a terminal, and that Return writes to their agents' files.
    func testASetupThatOpensByItselfTakesTheKeyboardOnlyWhenEvlatIsInFront() throws {
        let away = controller(frontmost: false)
        defer { close(away) }
        away.openSetup(byItself: true)
        let hidden = try XCTUnwrap(away.setupPanel)
        XCTAssertTrue(hidden.isVisible, "it is seen")
        XCTAssertFalse(hidden.isKeyWindow, "but the keyboard stays where it was")
        XCTAssertFalse(NSRunningApplication.current.isActive)
        away.openSetup()
        XCTAssertTrue(hidden.isKeyWindow, "asked for from the menu, the same panel takes it")

        let inFront = controller(frontmost: true)
        defer { close(inFront) }
        inFront.openSetup(byItself: true)
        XCTAssertTrue(try XCTUnwrap(inFront.setupPanel).isKeyWindow, "Evlat was opened on purpose")
    }

    func testEscapeAndLosingTheKeyboardDoNotCloseIt() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openSetup()
        let panel = try XCTUnwrap(controller.setupPanel)
        panel.cancelOperation(nil)
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(panel.isVisible)
        panel.sendEvent(try key(kVK_Escape, characters: "\u{1b}", in: panel))
        XCTAssertTrue(controller.isSetupOpen, "the Esc key does not close it either")
        XCTAssertTrue(panel.isVisible)
        // A click in another app or window: the keyboard goes, the panel stays
        // (the second step sends the user to a terminal).
        panel.resignKey()
        XCTAssertTrue(controller.isSetupOpen)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, controller.panel?.level, "and stays above the other apps")
    }

    /// Return presses the primary button: the one way on from the keyboard.
    /// SwiftUI registers its shortcut once the view has been laid out and has
    /// drawn, hence the turn of the run loop.
    func testReturnPressesThePrimaryButton() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openSetup()
        let panel = try XCTUnwrap(controller.setupPanel)
        let flow = try XCTUnwrap(controller.setupFlow)
        XCTAssertEqual(flow.step, .agents)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        // Until the shortcut answers: how long that takes depends on the load.
        let enter = try key(kVK_Return, characters: "\r", in: panel)
        var pressed = false
        for _ in 0..<40 where !pressed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            pressed = panel.performKeyEquivalent(with: enter)
        }
        XCTAssertTrue(pressed, "Return answered by the default action")
        XCTAssertEqual(flow.step, .bar, "no agent found here: on to the bar")
    }

    // MARK: - Out of the way of the others

    /// The setup is the one thing talking: the open list and the balloon
    /// close, the body comes out whole and hover does not open the bar
    /// under it.
    func testTheSetupBringsTheWholeBodyAndHoldsHoverOff() throws {
        let controller = controller()
        defer { close(controller) }
        controller.bodyMode = .hidden
        XCTAssertEqual(controller.presence.level, .none, "precondition: the body is out of the way")
        controller.hover.openNow()
        XCTAssertTrue(controller.barState.isOpen)
        controller.openChat()
        XCTAssertTrue(controller.isChatOpen)
        controller.openSetup()
        XCTAssertFalse(controller.isChatOpen, "the balloon closes")
        XCTAssertFalse(controller.barState.isOpen, "the list closes")
        XCTAssertFalse(controller.hover.isOpen, "through the intent")
        XCTAssertEqual(controller.presence.level, .full, "the body is out whole")
        XCTAssertEqual(controller.barState.presence.level, .full)
        XCTAssertTrue(controller.mascot.isShown)
        controller.pointer(.entered)
        controller.pointer(.moved(.zero))
        let waited = expectation(description: "the opening delay passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.openDelay * 3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertFalse(controller.hover.isOpen, "hover does not open the bar under the setup")
        XCTAssertFalse(controller.barState.isOpen)
        controller.closeSetup()
        XCTAssertEqual(controller.presence.level, .none, "closed, the body goes back to its mode")
        controller.pointer(.entered)
        let opened = expectation(description: "the bar opens again")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.openDelay * 3) { opened.fulfill() }
        wait(for: [opened], timeout: 2)
        XCTAssertTrue(controller.barState.isOpen, "once it is gone hover opens the bar again")
    }

    /// Every way into the balloon brings the setup's panel the keyboard
    /// instead, and none is kept for later.
    func testNoWayIntoTheBalloonOpensItWhileTheSetupIsOut() throws {
        let controller = controller(frontmost: false)
        defer { close(controller) }
        let bar = try XCTUnwrap(controller.panel)
        controller.openSetup(byItself: true)
        let panel = try XCTUnwrap(controller.setupPanel)
        XCTAssertFalse(panel.isKeyWindow, "precondition: it opened without the keyboard")
        let mascot = try onBar(controller, fromEdge: AppController.barWidth / 2,
                               fromTop: AppController.mascotTopInset + AppController.mascotSize / 2)

        XCTAssertEqual(bar.onClick?(mascot), true, "the mascot's click is taken")
        XCTAssertFalse(controller.isChatOpen)
        XCTAssertNil(controller.chatPanel, "no balloon is even made")
        XCTAssertTrue(panel.isKeyWindow, "the click brings the panel the keyboard")

        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        XCTAssertFalse(panel.isKeyWindow)
        controller.hotKeyPressed()
        XCTAssertFalse(controller.isChatOpen, "the shortcut neither")
        XCTAssertTrue(panel.isKeyWindow)

        panel.orderOut(nil)
        panel.orderFrontRegardless()
        controller.attach([ChatFolder.Item(path: "/tmp/q3/rapor.pdf", isDirectory: false)])
        XCTAssertFalse(controller.isChatOpen, "nor a dropped file")
        XCTAssertEqual(controller.chatModel.attachments, [], "and no chips wait for a balloon that is not there")
        XCTAssertTrue(panel.isKeyWindow)

        controller.setChatEnabled(false)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        XCTAssertEqual(bar.onClick?(mascot), true)
        XCTAssertTrue(panel.isKeyWindow, "chat switched off, the mascot still brings the panel the keyboard")
        controller.setChatEnabled(true)

        controller.closeSetup()
        controller.openChat()
        XCTAssertTrue(controller.isChatOpen, "once the setup is gone the balloon opens as ever")
    }

    // MARK: - Where it opens

    private static let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    private func bodyTop(_ origin: NSPoint) -> CGFloat { origin.y + SetupPanel.size.height - SetupPanel.outerMargin }

    /// Beside the drawn bar like the balloon, and the body centred on the
    /// eyes — its tail level with them in the middle of its side.
    func testThePanelIsCentredOnTheEyes() {
        let size = SetupPanel.size
        XCTAssertEqual(size.width, 24 + 380 + 8 + 2)
        XCTAssertEqual(size.height, 24 + 460 + 24)
        let right = NSRect(x: 1440 - 400, y: 200, width: 400, height: 500)
        let eyes = AppController.gazeAnchor(frame: right, edge: .right).y
        let origin = SetupPanel.origin(barFrame: right, edge: .right, size: size, visible: Self.screen)
        XCTAssertEqual(bodyTop(origin) - 230, eyes, accuracy: 0.5, "the body's middle is the eyes'")
        XCTAssertEqual(origin.x + size.width - SetupPanel.barSideMargin,
                       right.maxX - AppController.barWidth - SetupPanel.gapToBar, accuracy: 0.5,
                       "the tail's tip a gap in from the bar, as the balloon's")
        XCTAssertEqual(SetupPanel.tailCenter(barFrame: right, edge: .right, bodyTop: bodyTop(origin)), 230,
                       accuracy: 0.5, "the tail is level with the eyes")

        let left = NSRect(x: 0, y: 200, width: 400, height: 500)
        let mirrored = SetupPanel.origin(barFrame: left, edge: .left, size: size, visible: Self.screen)
        XCTAssertEqual(mirrored.x + SetupPanel.barSideMargin,
                       AppController.barWidth + SetupPanel.gapToBar, accuracy: 0.5, "the left is the right's mirror")
        XCTAssertEqual(mirrored.y, origin.y, accuracy: 0.5)
        XCTAssertEqual(ChatPanel.origin(barFrame: right, edge: .right, size: ChatPanel.size, visible: Self.screen).x
                       + ChatPanel.size.width,
                       origin.x + size.width, accuracy: 0.5, "the balloon and the setup meet the bar at one place")
    }

    /// Held to what is visible: under the menu bar, above the Dock — and on a
    /// screen too short for it, the top, where the title and the × are. The tail keeps
    /// to the eyes, inside the corners.
    func testThePanelFitsTheVisibleScreenAndTheTailFollowsTheEyes() {
        let size = SetupPanel.size
        let reach = SetupPanel.tailReach

        let high = NSRect(x: 1040, y: 600, width: 400, height: 500)
        let eyesHigh = AppController.gazeAnchor(frame: high, edge: .right).y
        XCTAssertGreaterThan(eyesHigh + 230, Self.screen.maxY, "precondition: it would reach past the top")
        let top = SetupPanel.origin(barFrame: high, edge: .right, size: size, visible: Self.screen)
        XCTAssertEqual(bodyTop(top), Self.screen.maxY, accuracy: 0.5, "the top stays under the menu bar")
        XCTAssertEqual(SetupPanel.tailCenter(barFrame: high, edge: .right, bodyTop: bodyTop(top)),
                       max(reach, bodyTop(top) - eyesHigh), accuracy: 0.5, "the tail slides toward the eyes")

        let low = NSRect(x: 1040, y: -100, width: 400, height: 500)
        let eyesLow = AppController.gazeAnchor(frame: low, edge: .right).y
        XCTAssertLessThan(eyesLow - 230, Self.screen.minY, "precondition: it would reach below the Dock")
        let bottom = SetupPanel.origin(barFrame: low, edge: .right, size: size, visible: Self.screen)
        XCTAssertEqual(bodyTop(bottom) - 460, Self.screen.minY, accuracy: 0.5, "the bottom stays above the Dock")
        XCTAssertEqual(SetupPanel.tailCenter(barFrame: low, edge: .right, bodyTop: bodyTop(bottom)),
                       bodyTop(bottom) - eyesLow, accuracy: 0.5, "the tail is level with the eyes")

        // The eyes off the body altogether: the tail stops inside the corners.
        let beyond = NSRect(x: 1040, y: 1400, width: 400, height: 500)
        let above = SetupPanel.origin(barFrame: beyond, edge: .right, size: size, visible: Self.screen)
        XCTAssertEqual(SetupPanel.tailCenter(barFrame: beyond, edge: .right, bodyTop: bodyTop(above)), reach,
                       accuracy: 0.5)
        let under = NSRect(x: 1040, y: -1500, width: 400, height: 500)
        let below = SetupPanel.origin(barFrame: under, edge: .right, size: size, visible: Self.screen)
        XCTAssertEqual(SetupPanel.tailCenter(barFrame: under, edge: .right, bodyTop: bodyTop(below)), 460 - reach,
                       accuracy: 0.5)

        let short = NSRect(x: 0, y: 0, width: 1280, height: 400)
        let squeezed = SetupPanel.origin(barFrame: NSRect(x: 880, y: 0, width: 400, height: 500), edge: .right,
                                         size: size, visible: short)
        XCTAssertEqual(bodyTop(squeezed), short.maxY, accuracy: 0.5, "too short for it: the top wins (title and ×)")
    }

    /// Opened, it sits where the static says, from the live bar.
    func testTheOpenPanelSitsBesideTheBar() throws {
        for edge: BarPanel.Edge in [.right, .left] {
            let controller = controller(edge: edge)
            defer { close(controller) }
            controller.openSetup()
            let bar = try XCTUnwrap(controller.panel)
            let panel = try XCTUnwrap(controller.setupPanel)
            let visible = try XCTUnwrap(NSScreen.screens.first).visibleFrame
            let expected = SetupPanel.origin(barFrame: bar.frame, edge: edge, size: panel.frame.size, visible: visible)
            XCTAssertEqual(panel.frame.origin.x, expected.x, accuracy: 0.5, "\(edge)")
            XCTAssertEqual(panel.frame.origin.y, expected.y, accuracy: 0.5, "\(edge)")
            XCTAssertEqual(panel.frame.size, SetupPanel.size)
            XCTAssertEqual(panel.tail.edge, edge, "the tail faces the bar")
            XCTAssertEqual(panel.tail.center,
                           SetupPanel.tailCenter(barFrame: bar.frame, edge: edge, bodyTop: bodyTop(expected)),
                           accuracy: 0.5)
        }
    }

    /// A new edge or screen moves it with the bar rather than closing it.
    func testAnotherEdgeOrScreenMovesThePanelWithTheBar() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openSetup()
        let bar = try XCTUnwrap(controller.panel)
        let panel = try XCTUnwrap(controller.setupPanel)
        let visible = try XCTUnwrap(NSScreen.screens.first).visibleFrame

        controller.dock(.left)
        XCTAssertTrue(controller.isSetupOpen, "docking does not close it")
        XCTAssertTrue(panel.isVisible)
        var expected = SetupPanel.origin(barFrame: bar.frame, edge: .left, size: panel.frame.size, visible: visible)
        XCTAssertEqual(panel.frame.origin.x, expected.x, accuracy: 0.5)
        XCTAssertEqual(panel.frame.origin.y, expected.y, accuracy: 0.5)
        XCTAssertEqual(panel.tail.edge, .left, "the tail turns around")
        XCTAssertTrue(panel.frame.minX < bar.frame.midX, "on the bar's inner side, the left one")

        // The screen's path reaches the same place: displaced by hand, it is
        // put back beside the bar.
        panel.setFrameOrigin(NSPoint(x: 5, y: 5))
        controller.setDisplay("a-screen-this-test-does-not-have")
        expected = SetupPanel.origin(barFrame: bar.frame, edge: .left, size: panel.frame.size, visible: visible)
        XCTAssertEqual(panel.frame.origin.x, expected.x, accuracy: 0.5)
        XCTAssertEqual(panel.frame.origin.y, expected.y, accuracy: 0.5)
        XCTAssertTrue(controller.isSetupOpen)
    }

    // MARK: - Strings

    func testTheXKeyIsInEveryTable() {
        for lang in L10nTests.languages {
            XCTAssertNotNil(L10n.catalog.tables[lang]?["setup.flow.close"], "\(lang) has no setup.flow.close")
            XCTAssertNil(L10n.catalog.tables[lang]?["setup.window.title"], "\(lang) still has the window's title")
        }
    }
}
