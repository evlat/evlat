import XCTest
import SwiftUI
@testable import EvlatApp

/// A picture sheet: read for its size alone, cut into cells row by row the
/// first time one is drawn, and drawn one cell at a time by the control
/// that names it.
final class MascotSheetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try MascotPictures.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testItsSizeIsReadFromThePicture() throws {
        let url = try MascotPictures.grid(at: folder.appendingPathComponent("s.png"), columns: 3, rows: 2,
                                          cell: (20, 30))
        let size = try XCTUnwrap(MascotSheet.pixelSize(of: url))
        XCTAssertEqual(size.width, 60)
        XCTAssertEqual(size.height, 60)
        XCTAssertNil(MascotSheet.pixelSize(of: folder.appendingPathComponent("none.png")))
    }

    /// Cells count row by row from the top left — the order a pet sheet's
    /// table names them in.
    func testCellsAreCutRowByRowFromTheTopLeft() throws {
        let url = try MascotPictures.grid(at: folder.appendingPathComponent("s.png"), columns: 3, rows: 2,
                                          cell: (20, 30))
        let sheet = MascotSheet.sheet(at: url, columns: 3, rows: 2)
        for index in 0..<6 {
            let cell = try XCTUnwrap(sheet.cell(index), "cell \(index)")
            let centre = MascotPictures.centre(of: cell), want = MascotPictures.color(of: index)
            XCTAssertEqual([centre.red, centre.green, centre.blue], [want.red, want.green, want.blue], "cell \(index)")
        }
        XCTAssertNil(sheet.cell(6))
        XCTAssertNil(sheet.cell(-1))
    }

    /// A big sheet is decoded no taller than the cells need.
    func testABigSheetIsDecodedAtTheCellsHeight() throws {
        let url = try MascotPictures.grid(at: folder.appendingPathComponent("s.png"), columns: 2, rows: 2,
                                          cell: (300, 400))
        let cell = try XCTUnwrap(MascotSheet.sheet(at: url, columns: 2, rows: 2).cell(3))
        XCTAssertLessThanOrEqual(cell.height, MascotSheet.cellHeight)
        XCTAssertGreaterThanOrEqual(cell.height, MascotSheet.cellHeight - 1)
    }

    /// One sheet per version of a file: found again unchanged, it is the
    /// same object — its cells decoded once — and changed, a new one.
    func testOneSheetPerVersionOfTheFile() throws {
        let url = try MascotPictures.grid(at: folder.appendingPathComponent("s.png"), columns: 1, rows: 1,
                                          cell: (10, 10))
        let first = MascotSheet.sheet(at: url, columns: 1, rows: 1)
        XCTAssertTrue(first === MascotSheet.sheet(at: url, columns: 1, rows: 1))
        try MascotPictures.grid(at: url, columns: 2, rows: 1, cell: (10, 10))
        XCTAssertFalse(first === MascotSheet.sheet(at: url, columns: 1, rows: 1))
    }

    func testAPictureThatCannotBeReadDrawsNothing() throws {
        let url = folder.appendingPathComponent("s.png")
        try Data("not a picture".utf8).write(to: url)
        XCTAssertNil(MascotSheet.sheet(at: url, columns: 2, rows: 2).cell(0))
    }

    /// The part draws the cell its control names, rounded.
    @MainActor
    func testACellsPartDrawsTheCellItsControlNames() throws {
        let url = try MascotPictures.grid(at: folder.appendingPathComponent("s.png"), columns: 2, rows: 2,
                                          cell: (40, 40))
        let frame = MascotControl("frame")
        let rig = MascotRig(root: MascotPart(name: "sheet",
                                             shape: .cells(MascotSheet.sheet(at: url, columns: 2, rows: 2), by: frame)),
                            controls: [frame: MascotControl.Range(0, 3, rest: 0)])
        for (value, index) in [(0.0, 0), (2.2, 2), (2.6, 3)] {
            let view = RigBody(rig: rig, pose: MascotPose().setting(frame, to: value), size: 40)
                .frame(width: 40, height: 40)
            let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
            let centre = MascotPictures.centre(of: image), want = MascotPictures.color(of: index)
            XCTAssertEqual([centre.red, centre.green, centre.blue], [want.red, want.green, want.blue], "at \(value)")
        }
    }

    /// A cut is one drawn frame and then stillness.
    func testACutIsOneFrame() {
        let step = MascotClip.Step.cut(MascotPose(), hold: 0.15)
        XCTAssertEqual(step.motion, 1.0 / 60)
        XCTAssertEqual(step.hold, 0.15)
    }
}
