import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// A character written as a file reads back as the code that writes it —
/// the format loses nothing — and a file that is not one says where.
final class CharacterFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try MascotPictures.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `Tests/Fixtures/mascots/<name>/`: characters written by hand as
    /// files, and the examples of the format.
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mascots/\(name)")
    }

    private func read(_ json: String) throws -> MascotCharacter {
        try CharacterFile.character(from: Data(json.utf8), folder: folder, id: "test:file")
    }

    private func failure(_ json: String) -> CharacterFile.Failure? {
        do {
            _ = try read(json)
            return nil
        } catch {
            return error as? CharacterFile.Failure
        }
    }

    /// Pati, written as a file: its ears, nose, whiskers, eyes, its own
    /// control, gesture and rules — equal to the Swift, part for part.
    func testPatiReadsBackAsItsCode() throws {
        let pati = try CharacterFile.character(in: fixture("pati"), id: "pati")
        XCTAssertEqual(pati.rig, Pati.character.rig)
        XCTAssertEqual(pati.motions, Pati.character.motions)
        XCTAssertEqual(pati.behavior, Pati.character.behavior)
        XCTAssertEqual(pati, Pati.character)
    }

    /// The test lantern: a phase played its own way, capsules, conditions
    /// and weights — what Pati does not use.
    func testTheLanternReadsBackAsItsCode() throws {
        let lantern = try CharacterFile.character(in: fixture("lantern"), id: "test-lantern")
        var expected = MascotTestCharacters.lantern
        expected.name = "Lantern"
        XCTAssertEqual(lantern.rig, expected.rig)
        XCTAssertEqual(lantern.states, expected.states)
        XCTAssertEqual(lantern.motions, expected.motions)
        XCTAssertEqual(lantern.behavior, expected.behavior)
        XCTAssertEqual(lantern, expected)
        XCTAssertEqual(MascotContract.violations(of: lantern), [])
    }

    private let minimal = ##"{"version": 1, "root": {"name": "r", "shape": {"capsule": {"minimumHeight": 1}}, "fill": "#EBEBEB"}}"##

    /// Only the root is required: the rest is Evlat's.
    func testOnlyTheRootIsRequired() throws {
        let character = try read(minimal)
        XCTAssertEqual(character.states, [:])
        XCTAssertEqual(character.behavior, MascotBehavior())
        XCTAssertEqual(character.rig.root.fill, Color(red: 235.0 / 255, green: 235.0 / 255, blue: 235.0 / 255))
        XCTAssertNil(character.name)
    }

    func testAColourIsHexNamedGreyOrRGBWithAnOpacity() throws {
        func fill(_ json: String) throws -> Color {
            try read(#"{"version": 1, "root": {"name": "r", "fill": \#(json)}}"#).rig.root.fill
        }
        XCTAssertEqual(try fill(##""#00000080""##), Color(red: 0, green: 0, blue: 0).opacity(128.0 / 255))
        XCTAssertEqual(try fill(#"{"name": "black", "opacity": 0.92}"#), Color.black.opacity(0.92))
        XCTAssertEqual(try fill(#"{"white": 0.92}"#), Color(white: 0.92))
        XCTAssertEqual(try fill(#"{"red": 1, "green": 0.5, "blue": 0}"#), Color(red: 1, green: 0.5, blue: 0))
        XCTAssertEqual(failure(##"{"version": 1, "root": {"name": "r", "fill": "#GG0000"}}"##),
                       .unreadable(at: "root.fill"))
    }

    /// Where the reading stopped is said, as a key path.
    func testAFileThatIsNotACharacterSaysWhere() {
        XCTAssertEqual(failure("not json"), .unreadable(at: ""))
        XCTAssertEqual(failure(#"{"version": 1}"#), .unreadable(at: ""))
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r", "children": [{"name": "a"}, {"shape": {"capsule": {"minimumHeight": 1}}}]}}"#),
                       .unreadable(at: "root.children.1"))
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r", "bindings": [{"control": "yaw", "property": "spin", "from": [0, 1]}]}}"#),
                       .unreadable(at: "root.bindings.0.property"))
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r"}, "states": {"asleep": {"steps": []}}}"#),
                       .unreadable(at: "states.asleep"))
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r"}, "motions": {"m": {"steps": [{"pose": {}, "move": "glide", "hold": 1}]}}}"#),
                       .unreadable(at: "motions.m.steps.0.move"))
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r"}, "rules": [{"phase": "waiting", "when": [{"fact": "mood"}], "play": ["m"]}]}"#),
                       .unreadable(at: "rules.0.when.0.fact"))
    }

    func testANewerVersionIsNotGuessedAt() {
        XCTAssertEqual(failure(#"{"version": 2, "root": {"name": "r"}}"#), .newerVersion(2))
    }

    /// A step moves on the shared spring, eased over seconds, or by a cut;
    /// a pose starts at a phase's rest or the neutral one.
    func testStepsAndPoses() throws {
        let character = try read(#"""
        {"version": 1, "root": {"name": "r"}, "controls": {"glow": {"lower": 0, "upper": 1, "rest": 0}},
         "motions": {"m": {"steps": [
           {"pose": {"from": "failed", "tilt": 3}, "move": "spring", "hold": 1},
           {"pose": {"glow": 0.5}, "move": 0.2, "hold": 0.3},
           {"pose": {"yaw": 1}, "move": "cut", "hold": 0.1}]}}}
        """#)
        var failed = MascotPose.resting(for: .failed)
        failed.tilt = 3
        XCTAssertEqual(character.motions["m"], MascotClip(steps: [
            .entering(failed, hold: 1),
            .eased(MascotPose().setting(MascotControl("glow"), to: 0.5), over: 0.2, hold: 0.3),
            .cut(MascotPose(yaw: 1), hold: 0.1)
        ], loops: false))
    }

    /// A picture is the folder's own: drawn whole, or as cells a control
    /// names; one outside the folder or not there is said.
    func testPicturesAreTheFoldersOwn() throws {
        try MascotPictures.grid(at: folder.appendingPathComponent("face.png"), columns: 2, rows: 1, cell: (10, 10))
        let whole = try read(#"{"version": 1, "root": {"name": "r", "shape": {"image": "face.png"}}}"#)
        guard case .cells(let sheet, let control)? = whole.rig.root.shape else { return XCTFail("no picture") }
        XCTAssertEqual([sheet.columns, sheet.rows], [1, 1])
        XCTAssertNil(control)
        let cells = try read(#"{"version": 1, "controls": {"lid": {"lower": 0, "upper": 1, "rest": 0}}, "root": {"name": "r", "shape": {"cells": {"image": "face.png", "columns": 2, "rows": 1, "by": "lid"}}}}"#)
        guard case .cells(let grid, let lid)? = cells.rig.root.shape else { return XCTFail("no cells") }
        XCTAssertEqual([grid.columns, grid.rows], [2, 1])
        XCTAssertEqual(lid, MascotControl("lid"))
        XCTAssertEqual(MascotContract.violations(of: cells).filter { $0.contains("cells") }, [])
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r", "shape": {"image": "../face.png"}}}"#), .pictureOutside)
        XCTAssertEqual(failure(#"{"version": 1, "root": {"name": "r", "shape": {"image": "gone.png"}}}"#),
                       .noPicture("gone.png"))
    }

    /// Cells named by a control nobody declared would draw nothing: the
    /// contract says so.
    func testCellsByAnUndeclaredControlBreakTheContract() throws {
        try MascotPictures.grid(at: folder.appendingPathComponent("face.png"), columns: 2, rows: 1, cell: (10, 10))
        let character = try read(#"{"version": 1, "root": {"name": "r", "shape": {"cells": {"image": "face.png", "columns": 2, "rows": 1, "by": "lid"}}}}"#)
        XCTAssertTrue(MascotContract.violations(of: character).contains { $0.contains("lid is not declared") })
    }
}
