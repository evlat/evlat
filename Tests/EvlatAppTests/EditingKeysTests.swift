import AppKit
import XCTest
@testable import EvlatApp

/// Evlat has no main menu, so a window with a field routes the editing keys
/// itself. The password window took no ⌘V until it did (a user's report).
final class EditingKeysTests: XCTestCase {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    func testTheEditingKeysStandForTheirActions() {
        XCTAssertEqual(EditingKeys.action(for: key("v", .command)), #selector(NSText.paste(_:)))
        XCTAssertEqual(EditingKeys.action(for: key("c", .command)), #selector(NSText.copy(_:)))
        XCTAssertEqual(EditingKeys.action(for: key("x", .command)), #selector(NSText.cut(_:)))
        XCTAssertEqual(EditingKeys.action(for: key("a", .command)), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(EditingKeys.action(for: key("z", .command)), Selector(("undo:")))
        XCTAssertEqual(EditingKeys.action(for: key("z", [.command, .shift])), Selector(("redo:")))
    }

    func testOtherKeysAreLeftAlone() {
        XCTAssertNil(EditingKeys.action(for: key("v", [])))
        XCTAssertNil(EditingKeys.action(for: key("v", [.command, .option])))
        XCTAssertNil(EditingKeys.action(for: key("v", [.command, .shift])))
        XCTAssertNil(EditingKeys.action(for: key("w", .command)))
        XCTAssertTrue(EditingKeys.isClose(key("w", .command)))
        XCTAssertFalse(EditingKeys.isClose(key("w", [.command, .option])))
    }
}
