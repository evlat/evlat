import XCTest
import EvlatCore
@testable import EvlatApp

/// An agent's pet folder read as a mascot: the manifest, a picture of a
/// sheet's size kept inside the folder, and rows that keep the contract.
final class PetAtlasTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try MascotPictures.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A pet folder as the Codex app writes one: a manifest and a sheet of
    /// `rows` rows.
    private func pet(rows: Int = 9, manifest: String? = nil, picture: String = "spritesheet.png") throws -> URL {
        let pet = folder.appendingPathComponent("mochi")
        try FileManager.default.createDirectory(at: pet, withIntermediateDirectories: true)
        try MascotPictures.grid(at: pet.appendingPathComponent(picture), columns: 8, rows: rows,
                                cell: PetAtlas.cell)
        let json = manifest ?? #"{"id": "mochi", "displayName": "Mochi", "description": "A cat.", "spritesheetPath": "spritesheet.png"}"#
        try Data(json.utf8).write(to: pet.appendingPathComponent("pet.json"))
        return pet
    }

    private func failure(_ body: () throws -> Any) -> PetAtlas.Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? PetAtlas.Failure
        }
    }

    /// A version 1 pet is a character that keeps the contract, called what
    /// its manifest calls it.
    func testAVersionOnePetKeepsTheContract() throws {
        let character = try PetAtlas.character(in: pet(), id: "test:mochi")
        XCTAssertEqual(character.id, "test:mochi")
        XCTAssertEqual(character.name, "Mochi")
        XCTAssertEqual(MascotContract.violations(of: character), [])
        XCTAssertEqual(character.rig.controls[PetAtlas.cellControl]?.upper, 71)
    }

    /// Version 2's two rows of looking cells are part of its sheet.
    func testAVersionTwoSheetHasElevenRows() throws {
        let character = try PetAtlas.character(in: pet(rows: 11), id: "test:mochi")
        XCTAssertEqual(MascotContract.violations(of: character), [])
        XCTAssertEqual(character.rig.controls[PetAtlas.cellControl]?.upper, 87)
        guard case .cells(let sheet, _)? = character.rig.root.shape else { return XCTFail("no sheet") }
        XCTAssertEqual(sheet.rows, 11)
    }

    /// Each phase rests on its row's first frame: idle, the working row (not
    /// the locomotion ones), failed, waiting and review.
    func testEachPhaseRestsOnItsRow() throws {
        let character = try PetAtlas.character(in: pet(), id: "test:mochi")
        let cells = Phase.allCases.map { character.resting(for: $0).own[PetAtlas.cellControl] }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: zip(Phase.allCases, cells)),
                       [.idle: 0, .working: 56, .failed: 40, .waiting: 48, .review: 64])
    }

    /// The states a session sits in burst — the row once, then still —
    /// and the news plays on arrival and holds: waiting twice through,
    /// review once.
    func testRowsBurstAndNewsPlaysOnArrival() throws {
        let character = try PetAtlas.character(in: pet(), id: "test:mochi")
        for phase in [Phase.idle, .working, .failed] {
            let clip = character.clip(for: phase, pacing: .normal)
            XCTAssertTrue(clip.loops, "\(phase)")
            XCTAssertEqual(clip.steps.first?.hold, PetAtlas.pauses[phase], "\(phase) rests between bursts")
        }
        let waiting = character.clip(for: .waiting, pacing: .normal)
        XCTAssertFalse(waiting.loops)
        XCTAssertEqual(waiting.steps.count, PetAtlas.waiting.durations.count * 2 + 1)
        let review = character.clip(for: .review, pacing: .normal)
        XCTAssertFalse(review.loops)
        XCTAssertEqual(review.steps.count, PetAtlas.review.durations.count + 1)
        let row = PetAtlas.review.durations
        XCTAssertEqual(review.steps.map(\.hold).reduce(0, +),
                       max(row[0], MascotPose.transitionDuration) + row.dropFirst().reduce(0, +) + row[0],
                       accuracy: 1e-9, "the row's own timing, its first frame shown again at the end")
    }

    /// A long wait gets a wave, at the stages Pati twitches at.
    func testALongWaitIsWavedAt() throws {
        let character = try PetAtlas.character(in: pet(), id: "test:mochi")
        let wave = try XCTUnwrap(character.motions["wave"])
        XCTAssertEqual(wave.steps.dropLast().compactMap { $0.pose.own[PetAtlas.cellControl] }, [24, 25, 26, 27])
        XCTAssertEqual(character.behavior.rules.map(\.after), [45, 180])
        XCTAssertTrue(character.behavior.rules.allSatisfy { $0.phase == .waiting })
    }

    func testANameIsTheFoldersWhenTheManifestGivesNone() throws {
        let character = try PetAtlas.character(in: pet(manifest: #"{"displayName": "  ", "spritesheetPath": "spritesheet.png"}"#),
                                               id: "test:mochi")
        XCTAssertEqual(character.name, "mochi")
    }

    func testAFolderWithoutAManifestIsNoPet() throws {
        let pet = try pet()
        try FileManager.default.removeItem(at: pet.appendingPathComponent("pet.json"))
        XCTAssertEqual(failure { try PetAtlas.character(in: pet, id: "x") }, .unreadableManifest)
        try Data("[1, 2]".utf8).write(to: pet.appendingPathComponent("pet.json"))
        XCTAssertEqual(failure { try PetAtlas.character(in: pet, id: "x") }, .unreadableManifest)
    }

    /// The picture is the folder's own: a path that climbs out or starts at
    /// the root is refused before anything is read.
    func testThePictureStaysInsideTheFolder() throws {
        for path in ["../spritesheet.png", "/etc/hosts", "a/../../b.png", ""] {
            let pet = try pet(manifest: #"{"spritesheetPath": "\#(path)"}"#)
            XCTAssertEqual(failure { try PetAtlas.character(in: pet, id: "x") }, .pictureOutside, path)
        }
        XCTAssertNoThrow(try PetAtlas.pictureURL("art/sheet.webp", in: folder))
    }

    func testAMissingPictureIsSaid() throws {
        let pet = try pet(manifest: #"{"spritesheetPath": "other.webp"}"#)
        XCTAssertEqual(failure { try PetAtlas.character(in: pet, id: "x") }, .noPicture)
    }

    /// Only a sheet's two sizes are read; anything else is not guessed at.
    func testAPictureOfAnotherSizeIsRefused() throws {
        let pet = folder.appendingPathComponent("odd")
        try FileManager.default.createDirectory(at: pet, withIntermediateDirectories: true)
        try MascotPictures.grid(at: pet.appendingPathComponent("spritesheet.png"), columns: 8, rows: 10,
                                cell: PetAtlas.cell)
        try Data(#"{"spritesheetPath": "spritesheet.png"}"#.utf8).write(to: pet.appendingPathComponent("pet.json"))
        XCTAssertEqual(failure { try PetAtlas.character(in: pet, id: "x") }, .wrongSize(width: 1536, height: 2080))
    }
}
