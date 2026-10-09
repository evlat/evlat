import XCTest
import EvlatCore
import EvlatAgents
@testable import EvlatApp

/// `evlat mascot check`: a folder read as Settings reads it, every broken
/// rule said, the id it would show under, and a picture when asked.
@MainActor
final class MascotCheckTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try MascotPictures.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mascots")
    }

    private func folder(_ name: String, json: String) throws -> URL {
        let folder = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("character.json"))
        return folder
    }

    func testAGoodMascotIsOkAndSaysWhereItShows() throws {
        let anywhere = MascotCheck.run(["check", fixtures.appendingPathComponent("lantern").path], home: home)
        XCTAssertEqual(anywhere.status, 0)
        XCTAssertTrue(anywhere.output.hasPrefix("ok: “Lantern” reads and keeps every rule."), anywhere.output)
        XCTAssertTrue(anywhere.output.contains("Put its folder in \(MascotLibrary.folder(home: home).path)/"), anywhere.output)

        let own = MascotLibrary.folder(home: home)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("pati"), to: own.appendingPathComponent("pati"))
        let found = MascotCheck.run(["check", own.appendingPathComponent("pati").path], home: home)
        XCTAssertEqual(found.status, 0)
        XCTAssertTrue(found.output.contains("It shows in Settings → Mascot → Look (evlat:pati)."), found.output)
    }

    /// Every rule it breaks, not only the first Settings shows.
    func testEveryBrokenRuleIsSaid() throws {
        let tilted = try folder("tilted", json: #"""
        {"version": 1, "root": {"name": "r"}, "states": {"review": {"steps": [{"pose": {"tilt": 9}, "move": 0.2, "hold": 1}]}}}
        """#)
        let result = MascotCheck.run(["check", tilted.path], home: home)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.output, """
            “tilted” breaks 2 rules, so Settings leaves it out:
              - review does not enter on the shared spring
              - review rests tilted
            """)
    }

    /// A file that does not read says where, in the decoder's own words.
    func testAnUnreadableFileSaysWhereAndWhy() throws {
        let broken = try folder("broken", json: ##"{"version": 1, "root": {"name": "r", "fill": "#GG"}}"##)
        let result = MascotCheck.run(["check", broken.path], home: home)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.output, "not a mascot: character.json can't be read at root.fill\n  not a colour")
        let empty = home.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(MascotCheck.run(["check", empty.path], home: home).output,
                       "not a mascot: the folder has no character.json or pet.json")
        XCTAssertEqual(MascotCheck.run(["check", home.appendingPathComponent("gone").path], home: home).status, 1)
    }

    /// `--preview` draws the states into a picture.
    func testAPreviewIsDrawn() throws {
        let png = home.appendingPathComponent("p.png")
        let result = MascotCheck.run(["check", fixtures.appendingPathComponent("pati").path, "--preview", png.path],
                                     home: home)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.hasSuffix("preview: \(png.path)"), result.output)
        let size = try XCTUnwrap(MascotSheet.pixelSize(of: png))
        XCTAssertGreaterThan(size.width, size.height)
    }

    func testAWrongCallIsAUsageError() {
        for arguments in [[], ["preview"], ["check"], ["check", "a", "b"], ["check", "a", "--preview"], ["check", "--x"]] {
            XCTAssertEqual(MascotCheck.run(arguments, home: home),
                           MascotCheck.Result(status: SignalCommand.usageExitCode, output: MascotCheck.usage), "\(arguments)")
        }
    }
}
