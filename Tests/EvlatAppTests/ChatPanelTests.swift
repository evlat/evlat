import XCTest
import AppKit
import Carbon.HIToolbox
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The balloon (`011/phase-2`): the machine-verifiable half of "it takes the
/// keyboard and nothing else". The bar never takes focus and still does not;
/// the balloon does, without making Evlat the active app, so the app in
/// front never falls back and gets the keyboard again once the balloon goes.
/// Whether the user's real click and key leave that app in front is looked at
/// by eye (`PanelConfigTests`' split).
@MainActor
final class ChatPanelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        // The app's own policy: under the test runner's default `.prohibited`
        // nothing could activate, and "did not activate" would prove nothing.
        NSApplication.shared.setActivationPolicy(.accessory)
        suiteName = "evlat.tests.chat.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-chat-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func controller(edge: BarPanel.Edge = .right) -> AppController {
        let controller = AppController(defaults: defaults)
        controller.installPanel(edge: edge)
        controller.hover.onChange = { [unowned controller] open in
            open ? controller.openBar() : controller.closeBar()
        }
        return controller
    }

    private func close(_ controller: AppController) {
        controller.chats?.stopAll()
        controller.closeChat()
        controller.chatPanel?.close()
        controller.panel?.close()
    }

    /// A click on the bar's content view, `x` in from the docked edge and
    /// `y` down from the top, through AppKit's own route.
    private func click(_ panel: BarPanel, fromEdge x: CGFloat, fromTop y: CGFloat,
                       flags: NSEvent.ModifierFlags = []) throws {
        let view = try XCTUnwrap(panel.contentView)
        let local = CGPoint(x: panel.edge.x(atInset: x, in: view.bounds), y: view.bounds.minY + y)
        panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(local, to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    }

    private var mascotMiddle: CGFloat { AppController.mascotTopInset + AppController.mascotSize / 2 }

    /// "Evlat was not brought forward", as the system sees it.
    ///
    /// **Not `NSApp.isActive`:** measured (`phase-2`), AppKit reports `true`
    /// for as long as a `.nonactivatingPanel` is key — the keys are this
    /// process's — while the system's frontmost app, the menu bar's owner
    /// and `NSRunningApplication.current.isActive` never move. The app in
    /// front stays in front; that is the claim. Once the balloon is gone
    /// `NSApp.isActive` is `false` again.
    private func assertNotBroughtForward(_ front: pid_t?, _ message: String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(NSRunningApplication.current.isActive, message, file: file, line: line)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front,
                       "the app in front stays in front \(message)", file: file, line: line)
        XCTAssertNotEqual(NSWorkspace.shared.menuBarOwningApplication?.processIdentifier,
                          ProcessInfo.processInfo.processIdentifier, message, file: file, line: line)
    }

    private var front: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    // MARK: - Focus

    func testTheBalloonTakesTheKeyboardAndTheBarStillDoesNot() {
        let panel = ChatPanel(content: EmptyView())
        XCTAssertTrue(panel.canBecomeKey, "the balloon is typed into")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "without it taking the keyboard would bring Evlat forward")
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.hidesOnDeactivate)
        let bar = BarPanel(size: CGSize(width: 54, height: 200), content: EmptyView())
        XCTAssertFalse(bar.canBecomeKey, "the bar never takes focus, balloon or not")
        XCTAssertEqual(panel.level, bar.level, "the balloon comes out of the bar, at its level")
        XCTAssertEqual(panel.collectionBehavior, bar.collectionBehavior)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
    }

    func testOpeningTheBalloonDoesNotActivateEvlat() throws {
        let controller = controller()
        defer { close(controller) }
        controller.panel?.show()
        XCTAssertFalse(NSApp.isActive, "precondition: Evlat is not the active app")
        let before = front
        XCTAssertNotEqual(before, ProcessInfo.processInfo.processIdentifier, "precondition")
        controller.openChat()
        let balloon = try XCTUnwrap(controller.chatPanel)
        XCTAssertTrue(balloon.isVisible)
        XCTAssertTrue(controller.isChatOpen)
        XCTAssertTrue(balloon.isKeyWindow, "the balloon has the keyboard")
        assertNotBroughtForward(before, "the balloon takes the keyboard, never the app")
        XCTAssertFalse(try XCTUnwrap(controller.panel).isKeyWindow, "the bar is never key")
        controller.closeChat()
        XCTAssertFalse(balloon.isKeyWindow)
        XCTAssertFalse(NSApp.isActive, "closed, AppKit's own flag is back too")
        assertNotBroughtForward(before)
    }

    /// Esc is the panel's `cancelOperation`, and the key itself on its way
    /// through the panel — a text field would otherwise keep it.
    func testEscapeClosesTheBalloon() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openChat()
        let balloon = try XCTUnwrap(controller.chatPanel)
        balloon.cancelOperation(nil)
        XCTAssertFalse(controller.isChatOpen)
        XCTAssertFalse(balloon.isVisible)

        controller.openChat()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: balloon.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)))
        balloon.sendEvent(escape)
        XCTAssertFalse(controller.isChatOpen, "the Esc key closes it")
        XCTAssertFalse(NSApp.isActive, "the keyboard is not Evlat's any more")
    }

    /// Clicking elsewhere takes the keyboard away: the balloon goes with it.
    func testLosingTheKeyboardClosesTheBalloon() throws {
        let controller = controller()
        defer { close(controller) }
        controller.openChat()
        try XCTUnwrap(controller.chatPanel).resignKey()
        XCTAssertFalse(controller.isChatOpen)
        XCTAssertFalse(try XCTUnwrap(controller.chatPanel).isVisible)
    }

    // MARK: - The mascot's click

    func testALeftClickOnTheMascotOpensAndClosesTheBalloon() throws {
        for edge: BarPanel.Edge in [.right, .left] {
            let controller = controller(edge: edge)
            defer { close(controller) }
            let bar = try XCTUnwrap(controller.panel)
            bar.show()
            let before = front
            try click(bar, fromEdge: AppController.barWidth / 2, fromTop: mascotMiddle)
            XCTAssertTrue(controller.isChatOpen, "\(edge): the mascot opens the balloon")
            assertNotBroughtForward(before, "\(edge)")
            XCTAssertFalse(bar.isKeyWindow, "\(edge)")
            try click(bar, fromEdge: AppController.barWidth / 2, fromTop: mascotMiddle)
            XCTAssertFalse(controller.isChatOpen, "\(edge): again closes it")
            try click(bar, fromEdge: AppController.barWidth / 2, fromTop: AppController.slotTop(0) + 5)
            XCTAssertFalse(controller.isChatOpen, "\(edge): a ring is not the mascot")
            try click(bar, fromEdge: AppController.barWidth * 2, fromTop: mascotMiddle)
            XCTAssertFalse(controller.isChatOpen, "\(edge): beside the bar is nothing")
            // The menu is built but not shown: nothing pops up on screen.
            bar.onMenu = { _ in nil }
            try click(bar, fromEdge: AppController.barWidth / 2, fromTop: mascotMiddle, flags: .control)
            XCTAssertFalse(controller.isChatOpen, "\(edge): a ctrl-click is the menu's, not the balloon's")
        }
    }

    /// The balloon is the one thing talking: the open list and its card
    /// close, and hover does not open the bar under it.
    func testTheBalloonClosesTheListAndHoldsHoverOff() throws {
        let controller = controller()
        defer { close(controller) }
        controller.hover.openNow()
        XCTAssertTrue(controller.barState.isOpen)
        controller.openChat()
        XCTAssertFalse(controller.barState.isOpen, "the list closes")
        XCTAssertFalse(controller.hover.isOpen, "through the intent")
        controller.pointer(.entered)
        controller.pointer(.moved(.zero))
        // Past the opening delay: an intent that heard the cursor would
        // have opened the bar by now.
        let waited = expectation(description: "the opening delay passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.openDelay * 3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertFalse(controller.hover.isOpen, "hover does not open the bar under the balloon")
        XCTAssertFalse(controller.barState.isOpen)
        controller.closeChat()
        controller.pointer(.entered)
        let opened = expectation(description: "the bar opens again")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.openDelay * 3) { opened.fulfill() }
        wait(for: [opened], timeout: 2)
        XCTAssertTrue(controller.barState.isOpen, "once it is gone hover opens the bar again")
    }

    /// The cursor on its way to the mascot has already asked hover to open
    /// the bar; the click that opens the balloon drops that (seen by eye:
    /// the list opened under a fresh balloon).
    func testTheClickDropsTheOpeningItsApproachAskedFor() {
        let controller = controller()
        defer { close(controller) }
        controller.pointer(.entered)
        controller.openChat()
        let waited = expectation(description: "the opening delay passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.openDelay * 3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertFalse(controller.hover.isOpen)
        XCTAssertFalse(controller.barState.isOpen)
    }

    func testDockingClosesTheBalloon() {
        let controller = controller()
        defer { close(controller) }
        controller.openChat()
        controller.dock(.left)
        XCTAssertFalse(controller.isChatOpen)
    }

    // MARK: - Where it opens

    private static let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    /// Beside the drawn bar, not the window: the tail's tip a gap in from
    /// the body's inner edge, and level with the mascot's eyes.
    func testTheBalloonComesOutOfTheMascot() {
        let size = ChatPanel.size
        let right = NSRect(x: 1440 - 400, y: 200, width: 400, height: 500)
        let origin = ChatPanel.origin(barFrame: right, edge: .right, size: size, visible: Self.screen)
        let tip = origin.x + size.width - ChatPanel.barSideMargin
        XCTAssertEqual(tip, right.maxX - AppController.barWidth - ChatPanel.gapToBar, accuracy: 0.5)
        let tail = origin.y + size.height - ChatPanel.outerMargin - ChatPanel.tailCenter
        XCTAssertEqual(tail, AppController.gazeAnchor(frame: right, edge: .right).y, accuracy: 0.5,
                       "the tail points at the mascot")

        let left = NSRect(x: 0, y: 200, width: 400, height: 500)
        let mirrored = ChatPanel.origin(barFrame: left, edge: .left, size: size, visible: Self.screen)
        XCTAssertEqual(mirrored.x + ChatPanel.barSideMargin,
                       AppController.barWidth + ChatPanel.gapToBar, accuracy: 0.5,
                       "the left is the right's mirror")
        XCTAssertEqual(mirrored.y, origin.y, accuracy: 0.5)
    }

    /// A mascot close under the menu bar keeps the balloon's top on the
    /// screen.
    func testTheBalloonStaysUnderTheMenuBar() {
        let size = ChatPanel.size
        let high = NSRect(x: 1040, y: Self.screen.maxY - 40, width: 400, height: 500)
        let origin = ChatPanel.origin(barFrame: high, edge: .right, size: size, visible: Self.screen)
        XCTAssertLessThanOrEqual(origin.y + size.height - ChatPanel.outerMargin, Self.screen.maxY + 0.5)
    }

    /// The panel opens where the static says, from the live bar.
    func testTheOpenBalloonSitsBesideTheBar() throws {
        for edge: BarPanel.Edge in [.right, .left] {
            let controller = controller(edge: edge)
            defer { close(controller) }
            controller.openChat()
            let bar = try XCTUnwrap(controller.panel)
            let balloon = try XCTUnwrap(controller.chatPanel)
            let visible = try XCTUnwrap(NSScreen.screens.first).visibleFrame
            let expected = ChatPanel.origin(barFrame: bar.frame, edge: edge, size: balloon.frame.size,
                                            visible: visible)
            XCTAssertEqual(balloon.frame.origin.x, expected.x, accuracy: 0.5, "\(edge)")
            XCTAssertEqual(balloon.frame.origin.y, expected.y, accuracy: 0.5, "\(edge)")
            XCTAssertEqual(controller.chatModel.edge, edge, "the tail faces the bar")
        }
    }

    // MARK: - Sending

    func testAPromptIsSentAsAnAction() throws {
        let controller = controller()
        defer { close(controller) }
        let fake = try fakeClaude()
        controller.chats = ChatStore(root: directory, platform: .unknown,
                                     locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": fake]),
                                     environment: ["PATH": "/usr/bin:/bin"])
        let listener = HookListener(port: 0) { _ in }
        listener.start()
        listener.awaitSettled(timeout: 5)
        defer { listener.stop() }
        controller.chats?.permissions = listener
        controller.openChat()
        XCTAssertFalse(controller.chatModel.submit("   "), "an empty line sends nothing")
        XCTAssertNil(controller.currentChat)
        XCTAssertTrue(controller.chatModel.submit("say ok"))
        let id = try XCTUnwrap(controller.currentChat, "the first prompt makes the chat")
        XCTAssertEqual(controller.chats?.chat(id)?.messages.first, .user(text: "say ok", attachments: []))
        XCTAssertEqual(controller.chatModel.messages.first, .user(text: "say ok", attachments: []),
                       "the balloon shows it at once")
        XCTAssertEqual(controller.chatModel.draft, "")
        XCTAssertFalse(controller.chatModel.submit("again"), "one turn at a time")
        let replied = expectation(description: "the reply streams in")
        func poll() {
            controller.refresh()
            if controller.chatModel.messages.contains(.reply("ok")), !controller.chatModel.isRunning {
                replied.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        wait(for: [replied], timeout: 10)
        XCTAssertFalse(NSRunningApplication.current.isActive)
    }

    /// The corner's mode: picked before the first prompt it is the new
    /// chat's; a "not done" line's retry switches that chat — not the
    /// default — to Ask and asks Claude to try the call again.
    func testAPickedModeAndARetryInAskMode() throws {
        let controller = controller()
        defer { close(controller) }
        let fake = try fakeClaude()
        controller.chats = ChatStore(root: directory, platform: .unknown,
                                     locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": fake]),
                                     environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_SCENARIO": "denied"],
                                     defaultMode: { [unowned controller] in
                                         MainActor.assumeIsolated { controller.defaultMode } })
        let listener = HookListener(port: 0) { _ in }
        listener.start()
        listener.awaitSettled(timeout: 5)
        defer { listener.stop() }
        controller.chats?.permissions = listener
        controller.openChat()
        XCTAssertEqual(controller.chatModel.mode, .auto, "auto until something else is picked")
        controller.choose(.acceptEdits)
        XCTAssertEqual(controller.chatModel.mode, .acceptEdits)
        XCTAssertNil(controller.currentChat, "picking makes no chat")
        controller.choose(.auto)
        XCTAssertEqual(controller.defaultMode, .auto, "the last pick is the default")
        controller.chatModel.add([ChatFolder.Item(path: "/tmp/a.pdf", isDirectory: false)])
        XCTAssertTrue(controller.chatModel.submit("install it"))
        let id = try XCTUnwrap(controller.currentChat)
        XCTAssertEqual(controller.chats?.chat(id)?.mode, .auto)
        controller.chatModel.add([ChatFolder.Item(path: "/tmp/b.pdf", isDirectory: false)])

        func settle(_ description: String) {
            let done = expectation(description: description)
            func poll() {
                controller.refresh()
                if !controller.chatModel.isRunning { done.fulfill() } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
                }
            }
            poll()
            wait(for: [done], timeout: 10)
        }
        settle("the turn ends")
        let line = try XCTUnwrap(controller.chatModel.messages.lazy.compactMap { message -> ChatSession.NotDone? in
            if case .notDone(let line) = message { return line } else { return nil }
        }.first)
        XCTAssertEqual(ChatModel.notDoneKey(line), "chat.notDone.auto")
        XCTAssertTrue(controller.chatModel.canRetry(line))
        XCTAssertFalse(controller.chatModel.canRetry(.init(toolUseID: "x", tool: "Bash", subject: "y", mode: .auto,
                                                           reason: "rule")),
                       "a deny rule denies in Ask mode too: no retry")

        controller.chatModel.retry(line)
        XCTAssertEqual(controller.chats?.chat(id)?.mode, .ask)
        XCTAssertEqual(controller.chatModel.mode, .ask)
        XCTAssertEqual(controller.defaultMode, .auto, "a retry changes this chat, not the default")
        XCTAssertEqual(controller.chatModel.attachments, [ChatFolder.Item(path: "/tmp/b.pdf", isDirectory: false)],
                       "the user's chips stay for the user's own next line")
        XCTAssertEqual(controller.chats?.chat(id)?.messages.last(where: {
            if case .user = $0 { return true } else { return false }
        }), .user(text: L10n.t("chat.notDone.prompt", ["command": line.subject ?? ""]), attachments: []))
        settle("the retry ends")
        XCTAssertFalse(controller.chatModel.canRetry, "a chat that asks has nothing to retry into")
    }

    /// A suggestion is sent as it is.
    func testASuggestionIsSent() throws {
        let model = ChatModel()
        var sent: [String] = []
        model.onSend = { sent.append($0) }
        XCTAssertTrue(model.submit(L10n.t(ChatModel.suggestionKeys[0], in: "en")))
        XCTAssertEqual(sent, ["What can you do?"])
        XCTAssertEqual(ChatModel.suggestionKeys.count, 3)
    }

    /// The fixture, copied with its exec bit (`ClaudeRunnerTests`' way).
    private func fakeClaude() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-claude")
        let copy = directory.appendingPathComponent("fake-claude")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return copy.path
    }

    /// No `claude`: the balloon says so instead of offering a line.
    func testWithoutClaudeTheBalloonSaysSo() throws {
        let controller = controller()
        defer { close(controller) }
        controller.chats = ChatStore(root: directory, platform: .unknown,
                                     locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        controller.openChat()
        XCTAssertTrue(controller.chatModel.claudeMissing)
    }

    // MARK: - Dropped files (`phase-4`)

    /// A point on the drawn bar, in the content view's coordinates.
    private func onBar(_ controller: AppController, fromEdge x: CGFloat, fromTop y: CGFloat) throws -> CGPoint {
        let panel = try XCTUnwrap(controller.panel)
        let bounds = try XCTUnwrap(panel.contentView?.bounds)
        return CGPoint(x: panel.edge.x(atInset: x, in: bounds), y: bounds.minY + y)
    }

    /// Over the drawn bar the mascot catches the file; off it, or when the
    /// drag leaves, it lets go. Catching is not a phase and wakes nothing.
    func testADragOverTheBarIsCaughtAndLetGo() throws {
        let controller = controller(edge: .left)
        defer { close(controller) }
        let mascot = try onBar(controller, fromEdge: AppController.barWidth / 2, fromTop: mascotMiddle)
        XCTAssertTrue(controller.drag(.over(point: mascot, screen: .zero)), "the mascot takes it")
        XCTAssertTrue(controller.mascot.catching)
        XCTAssertEqual(controller.mascot.phase, .idle, "not a phase")
        let beside = try onBar(controller, fromEdge: AppController.barWidth + 10, fromTop: mascotMiddle)
        XCTAssertFalse(controller.drag(.over(point: beside, screen: .zero)), "the room beside the bar is not bar")
        XCTAssertFalse(controller.mascot.catching)
        _ = controller.drag(.over(point: mascot, screen: .zero))
        _ = controller.drag(.left)
        XCTAssertFalse(controller.mascot.catching, "a drag that leaves is let go")
        XCTAssertFalse(controller.isChatOpen)

        // The right edge, the mirror: measured from the same helper.
        let right = self.controller(edge: .right)
        defer { close(right) }
        XCTAssertTrue(right.drag(.over(point: try onBar(right, fromEdge: AppController.barWidth / 2,
                                                        fromTop: mascotMiddle), screen: .zero)))
        XCTAssertFalse(right.drag(.over(point: try onBar(right, fromEdge: AppController.barWidth + 10,
                                                         fromTop: mascotMiddle), screen: .zero)))
        XCTAssertFalse(right.mascot.catching)
    }

    /// Let go on the bar: the balloon opens with the files as chips, the
    /// suggestions are the PDFs', and the folder is theirs.
    func testADropOpensTheBalloonWithTheFiles() throws {
        let controller = controller(edge: .left)
        defer { close(controller) }
        let items = [ChatFolder.Item(path: "/tmp/q3/rapor.pdf", isDirectory: false),
                     ChatFolder.Item(path: "/tmp/q3/fatura.pdf", isDirectory: false)]
        let mascot = try onBar(controller, fromEdge: AppController.barWidth / 2, fromTop: mascotMiddle)
        _ = controller.drag(.over(point: mascot, screen: .zero))
        XCTAssertTrue(controller.drag(.drop(point: mascot, items: items)))
        XCTAssertFalse(controller.mascot.catching, "caught and handed over")
        XCTAssertTrue(controller.isChatOpen)
        XCTAssertEqual(controller.chatModel.attachments, items)
        XCTAssertEqual(controller.chatModel.suggestions,
                       ["chat.suggestion.summarize", "chat.suggestion.tables", "chat.suggestion.compareTwo"])
        XCTAssertEqual(controller.chatModel.placeholderKey, "chat.placeholder.files")
        XCTAssertEqual(controller.chatModel.folder, "/tmp/q3")
        XCTAssertFalse(controller.chatModel.folderLocked)

        // The open balloon takes another; the same one twice is kept once.
        controller.attach([ChatFolder.Item(path: "/tmp/q4/photo.png", isDirectory: false), items[0]])
        XCTAssertEqual(controller.chatModel.attachments.count, 3)
        XCTAssertEqual(controller.chatModel.folder, "/tmp", "the folder follows the files until the first prompt")
        controller.chatModel.remove(controller.chatModel.attachments[2])
        XCTAssertEqual(controller.chatModel.folder, "/tmp/q3")

        let beside = try onBar(controller, fromEdge: AppController.barWidth + 10, fromTop: mascotMiddle)
        XCTAssertFalse(controller.drag(.drop(point: beside, items: items)), "not on the bar, not taken")
    }

    /// The first prompt makes the chat in the files' folder and names them
    /// from it; after it the folder is the chat's and the label only shows
    /// it — a file from elsewhere goes by its full path.
    func testTheFilesGoWithThePromptFromTheirFolder() throws {
        let controller = controller(edge: .left)
        defer { close(controller) }
        let folder = directory.appendingPathComponent("q3")
        // A `claude` that is found: no listener is handed in, so the turn
        // ends before anything runs — the prompt and its files are recorded.
        controller.chats = ChatStore(root: directory, platform: .unknown,
                                     locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/usr/bin/true"]))
        controller.attach([ChatFolder.Item(path: folder.appendingPathComponent("rapor.pdf").path, isDirectory: false),
                           ChatFolder.Item(path: "/elsewhere/fatura.pdf", isDirectory: false)])
        XCTAssertNil(controller.chatModel.folder, "nothing in common but the root: its own workspace")
        controller.chatModel.remove(controller.chatModel.attachments[1])
        controller.attach([ChatFolder.Item(path: folder.appendingPathComponent("sub/ek.png").path, isDirectory: false)])
        XCTAssertEqual(controller.chatModel.folder, folder.path)

        XCTAssertTrue(controller.chatModel.submit("Summarize"))
        let id = try XCTUnwrap(controller.currentChat)
        let chat = try XCTUnwrap(controller.chats?.chat(id))
        XCTAssertEqual(chat.folder, folder.path)
        XCTAssertFalse(chat.isWorkspace)
        XCTAssertEqual(chat.messages.first, .user(text: "Summarize", attachments: ["rapor.pdf", "sub/ek.png"]))
        XCTAssertTrue(controller.chatModel.attachments.isEmpty, "sent and cleared")
        XCTAssertEqual(controller.chatModel.folder, folder.path)
        XCTAssertTrue(controller.chatModel.folderLocked, "sent once: the folder is the chat's")

        controller.attach([ChatFolder.Item(path: "/elsewhere/fatura.pdf", isDirectory: false)])
        XCTAssertEqual(controller.chatModel.folder, folder.path, "a later file does not move the chat")
    }

    /// The balloon's drop layer lies over its content, so the line's field
    /// editor never takes a file as text (seen by eye), and it lets every
    /// click through to the content under it.
    func testTheBalloonsDropLayerIsOnTopAndLetsClicksThrough() throws {
        let panel = ChatPanel(content: Color.red)
        defer { panel.close() }
        let container = try XCTUnwrap(panel.contentView)
        let drop = try XCTUnwrap(container.subviews.last as? ChatDropView, "on top of the content")
        XCTAssertTrue(drop.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(drop.frame, container.bounds)
        XCTAssertNil(drop.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(container.hitTest(CGPoint(x: 10, y: 10)) is ChatDropView, "a click reaches the content")
        var dropped: [ChatFolder.Item] = []
        panel.onFiles = { dropped = $0 }
        drop.onFiles?([ChatFolder.Item(path: "/tmp/a.pdf", isDirectory: false)])
        XCTAssertEqual(dropped.count, 1)
    }

    /// With files the suggestions follow what they are.
    func testTheSuggestionsFollowTheFiles() {
        func keys(_ paths: [(String, Bool)]) -> [String] {
            ChatModel.suggestionKeys(for: paths.map { ChatFolder.Item(path: $0.0, isDirectory: $0.1) })
        }
        XCTAssertEqual(keys([]), ChatModel.suggestionKeys, "no files: the three for a bare prompt")
        XCTAssertEqual(keys([("/a/x.pdf", false)]), ["chat.suggestion.summarize", "chat.suggestion.tables"])
        XCTAssertEqual(keys([("/a/x.png", false)]), ["chat.suggestion.explain", "chat.suggestion.text"])
        XCTAssertEqual(keys([("/a/q3", true)]), ["chat.suggestion.organize", "chat.suggestion.contents"])
        XCTAssertEqual(keys([("/a/x.pdf", false), ("/a/y.png", false)]),
                       ["chat.suggestion.summarize", "chat.suggestion.explain", "chat.suggestion.compareTwo"],
                       "mixed: what fits any file")
        XCTAssertEqual(keys([("/a/x.pdf", false), ("/a/y.pdf", false), ("/a/z.pdf", false)]).last,
                       "chat.suggestion.compare")
        XCTAssertEqual(L10n.t("chat.suggestion.compareTwo", in: "tr"), "İkisini karşılaştır")
        XCTAssertEqual(L10n.t("chat.placeholder.files", in: "tr"), "Bu dosyalarla ne yapayım?")
    }

    // MARK: - Words

    func testEveryBalloonKeyIsInBothTables() {
        var keys = ChatModel.keys
        keys += [ChatSession.Failure.noBinary, .launch("x"), .exited(status: 1, detail: nil),
                 .result(subtype: "error", text: nil), .interrupted, .noListener("x")].map(ChatModel.failureKey)
        for lang in ["en", "tr"] {
            for key in keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
        XCTAssertEqual(L10n.t("chat.placeholder", in: "tr"), "Ne yapayım?")
        XCTAssertEqual(L10n.t("chat.hint", in: "tr"), "Dosya bırakabilirsin · Esc kapatır")
    }
}
