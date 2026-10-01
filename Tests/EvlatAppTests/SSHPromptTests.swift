import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// `ssh`'s question in Evlat's own window: the machine-verifiable half of
/// "it takes the keyboard and nothing else" (`ChatPanelTests`' split), and
/// what each press answers. Whether it looks right on the real screen is
/// looked at by eye.
@MainActor
final class SSHPromptTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        _ = NSApplication.shared
        // The app's own policy: under the runner's default `.prohibited`
        // nothing could activate, and "did not activate" would prove nothing.
        NSApplication.shared.setActivationPolicy(.accessory)
        suiteName = "evlat.tests.prompt.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func controller() -> AppController {
        let controller = AppController(defaults: defaults)
        controller.installPanel()
        return controller
    }

    private func close(_ controller: AppController) {
        controller.showPrompt(nil)
        controller.promptPanel?.close()
        controller.panel?.close()
    }

    private let password = RemoteTunnels.Prompt(id: "r-1", machineID: "m1", machine: "devbox",
                                                 text: "ben@devbox's password: ", generation: 1)
    private let hostKey = RemoteTunnels.Prompt(
        id: "r-2", machineID: "m1", machine: "devbox",
        text: "The authenticity of host 'devbox (10.0.0.9)' can't be established.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
        generation: 1)

    private var front: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// "Evlat was not brought forward", as the system sees it (not
    /// `NSApp.isActive`, which reads `true` while a non-activating panel is
    /// key — `AGENTS.md` → Pitfalls).
    private func assertNotBroughtForward(_ before: pid_t?, _ message: String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(NSRunningApplication.current.isActive, message, file: file, line: line)
        XCTAssertEqual(front, before, "the app in front stays in front \(message)", file: file, line: line)
        XCTAssertNotEqual(NSWorkspace.shared.menuBarOwningApplication?.processIdentifier,
                          ProcessInfo.processInfo.processIdentifier, message, file: file, line: line)
    }

    func testTheWindowTakesTheKeyboardWithoutActivatingEvlat() throws {
        let controller = controller()
        defer { close(controller) }
        let before = front
        XCTAssertNotEqual(before, ProcessInfo.processInfo.processIdentifier, "precondition")
        controller.showPrompt(password)
        let window = try XCTUnwrap(controller.promptPanel)
        XCTAssertTrue(window.canBecomeKey, "a password is typed into it")
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel),
                      "without it taking the keyboard would bring Evlat forward")
        XCTAssertFalse(window.closesWhenKeyLeaves, "the password may be fetched from another app")
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(window.frame.size, PromptView.size)
        assertNotBroughtForward(before, "the window takes the keyboard, never the app")

        controller.showPrompt(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive, "closed, the keyboard is the front app's again")
        assertNotBroughtForward(before)
    }

    /// The prompt as `ssh` wrote it; a password prompt offers "Remember",
    /// on by default, and sends the field; Esc refuses.
    func testAPasswordIsSentWithTheBoxAndEscRefuses() throws {
        let controller = controller()
        defer { close(controller) }
        controller.showPrompt(password)
        let model = controller.promptModel
        XCTAssertEqual(model.prompt?.text, "ben@devbox's password: ")
        XCTAssertTrue(model.remember, "on by default")
        var answers: [(String, String?, Bool)] = []
        model.onAnswer = { answers.append(($0, $1, $2)) }

        model.secret = "s3cret"
        model.submit()
        XCTAssertEqual(answers.map(\.0), ["r-1"])
        XCTAssertEqual(answers.first?.1, "s3cret")
        XCTAssertEqual(answers.first?.2, true)
        XCTAssertEqual(model.secret, "", "the field forgets what was typed")

        model.remember = false
        model.secret = "again"
        model.submit()
        XCTAssertEqual(answers.last?.2, false)

        try XCTUnwrap(controller.promptPanel).cancelOperation(nil)
        XCTAssertEqual(answers.last?.0, "r-1")
        XCTAssertNil(answers.last?.1, "Esc is a refusal")
    }

    /// A host key's question is answered yes or no — never remembered.
    func testAYesNoQuestionIsAnsweredInWords() throws {
        let controller = controller()
        defer { close(controller) }
        controller.showPrompt(hostKey)
        let model = controller.promptModel
        XCTAssertEqual(model.prompt?.isYesNo, true)
        XCTAssertEqual(model.prompt?.isPassword, false)
        var answers: [(String?, Bool)] = []
        model.onAnswer = { answers.append(($1, $2)) }
        model.submit("yes")
        model.submit("no")
        XCTAssertEqual(answers.map(\.0), ["yes", "no"])
        XCTAssertEqual(answers.map(\.1), [false, false], "only a password is ever kept")
    }

    /// A new question resets the field and the box.
    func testANewQuestionStartsClean() {
        let controller = controller()
        defer { close(controller) }
        controller.showPrompt(password)
        controller.promptModel.secret = "half"
        controller.promptModel.remember = false
        controller.showPrompt(hostKey)
        XCTAssertEqual(controller.promptModel.secret, "")
        XCTAssertTrue(controller.promptModel.remember)
        XCTAssertEqual(controller.promptModel.prompt, hostKey)
    }

    /// Return on an empty password field sends nothing: an empty password
    /// would be one failed login on the server.
    func testAnEmptyPasswordIsNotSent() {
        let controller = controller()
        defer { close(controller) }
        var sent = 0
        controller.showPrompt(password)
        controller.promptModel.onAnswer = { _, _, _ in sent += 1 }
        controller.promptModel.submit()
        XCTAssertEqual(sent, 0)
        controller.promptModel.secret = "pw"
        controller.promptModel.submit()
        XCTAssertEqual(sent, 1)
    }

    func testEveryKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in PromptView.keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }
}
