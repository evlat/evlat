import XCTest
@testable import EvlatApp

/// Ghostty's terminal for `[Go to session]`: picked by the agent's folder,
/// then by the session's name in the title, and never guessed. No test here
/// sends an Apple Event: the runner is a fake.
final class GhosttyFocusTests: XCTestCase {
    private func terminal(_ id: String, _ directory: String, _ title: String = "zsh") -> GhosttyFocus.Terminal {
        .init(id: id, directory: directory, title: title)
    }

    // MARK: - Picking

    func testTheOneTerminalInTheSessionsFolderIsPicked() {
        let terminals = [terminal("A", "/Users/u/web"), terminal("B", "/Users/u/evlat"), terminal("C", "/Users/u")]
        XCTAssertEqual(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: nil), "B")
        XCTAssertEqual(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat/", label: nil), "B",
                       "a trailing slash is the same folder")
        XCTAssertEqual(GhosttyFocus.pick([terminal("A", "/Users/u/evlat/")], directory: "/Users/u/evlat", label: nil), "A")
        XCTAssertNil(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat/Sources", label: nil),
                     "a parent folder is not the session's")
        XCTAssertNil(GhosttyFocus.pick([], directory: "/Users/u/evlat", label: nil))
        XCTAssertNil(GhosttyFocus.pick([terminal("A", "")], directory: "/", label: nil),
                     "a terminal with no reported folder matches nothing")
    }

    /// Two sessions in one folder: the title that carries the session's
    /// name decides, and only when exactly one does.
    func testTwoTerminalsInOneFolderAreToldApartByTheTitle() {
        let terminals = [terminal("A", "/Users/u/evlat", "✳ Fix the listener"),
                         terminal("B", "/Users/u/evlat", "✳ Ghostty focus"),
                         terminal("C", "/Users/u/web", "✳ Ghostty focus")]
        XCTAssertEqual(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: "ghostty FOCUS"), "B")
        XCTAssertNil(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: nil), "no name, no guess")
        XCTAssertNil(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: "  "))
        XCTAssertNil(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: "✳"),
                     "a name both titles carry decides nothing")
        XCTAssertNil(GhosttyFocus.pick(terminals, directory: "/Users/u/evlat", label: "Refactor"))
    }

    // MARK: - The script's output

    func testTheListIsReadBackWhole() {
        let output = "A\u{1F}/Users/u/evlat\u{1F}✳ Tab\ttitle\u{1E}B\u{1F}\u{1F}\u{1E}\u{1F}/x\u{1F}no id\u{1E}\n"
        XCTAssertEqual(GhosttyFocus.parse(output), [terminal("A", "/Users/u/evlat", "✳ Tab\ttitle"),
                                                    terminal("B", "", "")],
                       "a tab in a title is kept, a record without an id dropped, osascript's newline ignored")
        XCTAssertEqual(GhosttyFocus.parse(""), [])
        XCTAssertEqual(GhosttyFocus.parse("garbage"), [])
    }

    // MARK: - Focusing

    func testTheMatchIsFocusedByItsIDAsAnArgument() {
        var calls: [(script: String, arguments: [String])] = []
        let focused = GhosttyFocus.focus(directory: "/Users/u/evlat", label: "x") { script, arguments in
            calls.append((script, arguments))
            return script == GhosttyFocus.listScript
                ? "T-1\u{1F}/Users/u/web\u{1F}zsh\u{1E}T-2\u{1F}/Users/u/evlat\u{1F}claude\u{1E}"
                : "ok"
        }
        XCTAssertTrue(focused)
        XCTAssertEqual(calls.map(\.script), [GhosttyFocus.listScript, GhosttyFocus.focusScript])
        XCTAssertEqual(calls.last?.arguments, ["T-2"])
        XCTAssertFalse(GhosttyFocus.focusScript.contains("T-2"), "the id is never spliced into the script")
    }

    /// Refused (or Ghostty gone), nothing matching, several matching, or
    /// the focus itself failing: `false`, and the caller falls back.
    func testEveryFailureAnswersFalse() {
        XCTAssertFalse(GhosttyFocus.focus(directory: "/d", label: nil) { _, _ in nil }, "the list was refused")
        var focusAsked = false
        let none = GhosttyFocus.focus(directory: "/d", label: nil) { script, _ in
            if script == GhosttyFocus.focusScript { focusAsked = true }
            return "A\u{1F}/elsewhere\u{1F}zsh\u{1E}"
        }
        XCTAssertFalse(none)
        let several = GhosttyFocus.focus(directory: "/d", label: nil) { script, _ in
            if script == GhosttyFocus.focusScript { focusAsked = true }
            return "A\u{1F}/d\u{1F}zsh\u{1E}B\u{1F}/d\u{1F}zsh\u{1E}"
        }
        XCTAssertFalse(several)
        XCTAssertFalse(focusAsked, "no match, no focus event")
        XCTAssertFalse(GhosttyFocus.focus(directory: "/d", label: nil) { script, _ in
            script == GhosttyFocus.listScript ? "A\u{1F}/d\u{1F}zsh\u{1E}" : nil
        }, "the focus event failed")
    }

    /// Both scripts address Ghostty by its bundle id, never by a name
    /// another app could carry.
    func testGhosttyIsAddressedByItsBundleID() {
        for script in [GhosttyFocus.listScript, GhosttyFocus.focusScript] {
            XCTAssertTrue(script.contains(#"tell application id "com.mitchellh.ghostty""#))
        }
    }
}
