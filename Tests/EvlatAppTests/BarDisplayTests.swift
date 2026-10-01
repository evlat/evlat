import XCTest
import AppKit
import SwiftUI
@testable import EvlatApp

/// Which screen the bar goes on, and when its edge is a seam between two
/// screens: pure rules over frames, no real display needed.
final class BarDisplayTests: XCTestCase {
    private func display(_ id: String, _ name: String = "Screen", x: CGFloat, y: CGFloat = 0,
                         width: CGFloat = 1920, height: CGFloat = 1080) -> BarDisplay {
        let frame = NSRect(x: x, y: y, width: width, height: height)
        return BarDisplay(id: id, name: name, frame: frame, visibleFrame: frame)
    }

    func testThePinnedScreenWhileConnected() {
        let main = display("A", x: 0), side = display("B", x: 1920)
        XCTAssertEqual(BarDisplay.chosen("B", among: [main, side]), side)
    }

    func testNothingPinnedIsTheMainScreen() {
        let main = display("A", x: 0), side = display("B", x: 1920)
        XCTAssertEqual(BarDisplay.chosen(nil, among: [main, side]), main)
    }

    /// Unplugged, the bar waits on the main screen.
    func testAnUnpluggedPinFallsBackToTheMainScreen() {
        let main = display("A", x: 0)
        XCTAssertEqual(BarDisplay.chosen("B", among: [main]), main)
    }

    func testNoScreenIsNothing() {
        XCTAssertNil(BarDisplay.chosen("A", among: []))
        XCTAssertNil(BarDisplay.chosen(nil, among: []))
    }

    /// Left screen | right screen: the left one's right edge and the right
    /// one's left edge are seams; the outer edges are walls.
    func testSideBySideScreensMeetAtASeam() {
        let left = display("L", x: 0), right = display("R", x: 1920)
        let all = [left, right]
        XCTAssertTrue(BarDisplay.hasNeighbour(beyond: .right, of: left, among: all))
        XCTAssertFalse(BarDisplay.hasNeighbour(beyond: .left, of: left, among: all))
        XCTAssertTrue(BarDisplay.hasNeighbour(beyond: .left, of: right, among: all))
        XCTAssertFalse(BarDisplay.hasNeighbour(beyond: .right, of: right, among: all))
    }

    /// A screen above, or one that only touches a corner, is no seam for a
    /// side edge.
    func testAScreenAboveOrAtACornerIsNoSideSeam() {
        let main = display("M", x: 0)
        let above = display("A", x: 0, y: 1080)
        let corner = display("C", x: 1920, y: 1080)
        XCTAssertFalse(BarDisplay.hasNeighbour(beyond: .right, of: main, among: [main, above, corner]))
        XCTAssertTrue(BarDisplay.hasNeighbour(beyond: .top, of: main, among: [main, above]))
    }

    /// Screens of different heights still meet where they overlap.
    func testAShorterScreenBesideStillMakesASeam() {
        let laptop = display("L", x: 0, y: 0, width: 1512, height: 982)
        let tall = display("T", x: 1512, y: -400, width: 2560, height: 1440)
        XCTAssertTrue(BarDisplay.hasNeighbour(beyond: .right, of: laptop, among: [laptop, tall]))
    }

    /// Two monitors of one model share a name; the second is numbered.
    func testARepeatedNameIsNumbered() {
        let screens = [display("1", "Built-in", x: 0), display("2", "DELL", x: 1920),
                       display("3", "DELL", x: 3840)]
        XCTAssertEqual(BarDisplay.titles(screens), ["Built-in", "DELL", "DELL 2"])
    }

    /// A real screen has an id, and the same screen reads the same id twice.
    @MainActor
    func testARealScreenHasAStableID() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        XCTAssertFalse(screen.displayID.isEmpty)
        XCTAssertEqual(screen.displayID, screen.displayID)
        XCTAssertEqual(BarDisplay.connected.first?.id, screen.displayID, "the main screen first")
    }

    /// A pinned screen that is not connected puts the bar on the main one.
    @MainActor
    func testAPanelPinnedToAMissingScreenSitsOnTheMainOne() throws {
        let main = try XCTUnwrap(NSScreen.screens.first)
        let size = CGSize(width: 54, height: 485)
        let panel = BarPanel(edge: .right, size: size, content: EmptyView())
        defer { panel.close() }
        panel.display = "NOT-CONNECTED"
        panel.reposition()
        XCTAssertEqual(panel.frame.maxX, main.visibleFrame.maxX, accuracy: 0.5)
        XCTAssertTrue(main.frame.contains(panel.frame))
    }

    /// With a second screen attached, pinning moves the bar there and
    /// unpinning brings it back. Skipped on a one-screen machine.
    @MainActor
    func testAPanelPinnedToASecondScreenMovesThere() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("needs a second screen") }
        let main = NSScreen.screens[0], other = NSScreen.screens[1]
        let panel = BarPanel(edge: .right, size: CGSize(width: 54, height: 485), content: EmptyView())
        defer { panel.close() }
        panel.display = other.displayID
        XCTAssertEqual(panel.frame.maxX, other.visibleFrame.maxX, accuracy: 0.5)
        XCTAssertTrue(other.frame.contains(panel.frame))
        panel.display = nil
        XCTAssertTrue(main.frame.contains(panel.frame))
    }
}
