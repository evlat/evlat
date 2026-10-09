import XCTest
import EvlatCore
import EvlatAgents
@testable import EvlatApp

/// The characters found on disk: Evlat's own folder and each agent's pets,
/// one character a subfolder, the broken ones said and left out — and the
/// controller that offers them beside the shipped ones.
@MainActor
final class MascotLibraryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try MascotPictures.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The agent that keeps pets, from the catalog: the test names none.
    private var petAgent: any Agent {
        get throws { try XCTUnwrap(Agents.all.first { $0.pets != nil }) }
    }

    @discardableResult
    private func pet(_ name: String, in folder: URL, rows: Int = 9, manifest: String? = nil) throws -> URL {
        let pet = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: pet, withIntermediateDirectories: true)
        try MascotPictures.grid(at: pet.appendingPathComponent("spritesheet.png"), columns: 8, rows: rows,
                                cell: PetAtlas.cell)
        try Data((manifest ?? #"{"displayName": "\#(name.capitalized)", "spritesheetPath": "spritesheet.png"}"#).utf8)
            .write(to: pet.appendingPathComponent("pet.json"))
        return pet
    }

    private var ownFolder: URL { MascotLibrary.folder(home: home) }

    private func agentFolder() throws -> URL {
        home.appendingPathComponent(try XCTUnwrap(try petAgent.pets))
    }

    /// Evlat's own folder first, then every agent that keeps pets, each
    /// under its own prefix.
    func testTheSourcesAreEvlatsFolderThenTheAgentsPets() throws {
        let sources = MascotLibrary.sources(home: home)
        XCTAssertEqual(sources.first, MascotLibrary.Source(prefix: "evlat", folder: ownFolder))
        XCTAssertEqual(ownFolder.path, home.appendingPathComponent(".config/evlat/mascots").path)
        let agent = try petAgent
        XCTAssertTrue(sources.contains(MascotLibrary.Source(prefix: agent.id.rawValue, folder: try agentFolder())))
        XCTAssertEqual(sources.count, 1 + Agents.all.filter { $0.pets != nil }.count)
    }

    /// Every folder's characters, by name within it; an id carries its
    /// source, so the same folder name in two places is two characters.
    func testCharactersAreFoundInEveryFolderUnderTheirSourcesName() throws {
        try pet("zed", in: ownFolder)
        try pet("mochi", in: ownFolder)
        try pet("mochi", in: agentFolder(), rows: 11)
        let library = MascotLibrary.read(MascotLibrary.sources(home: home))
        let agent = try petAgent
        XCTAssertEqual(library.characters.map(\.id), ["evlat:mochi", "evlat:zed", agent.id.rawValue + ":mochi"])
        XCTAssertEqual(library.characters.map(\.name), ["Mochi", "Zed", "Mochi"])
        XCTAssertEqual(library.failures, [])
    }

    /// A folder that is not a pet is said, with why, and not offered; a
    /// hidden folder and a loose file are not looked at.
    func testABrokenFolderIsSaidAndLeftOut() throws {
        try pet("good", in: ownFolder)
        try FileManager.default.createDirectory(at: ownFolder.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        try pet("climber", in: ownFolder, manifest: #"{"spritesheetPath": "../../secret.png"}"#)
        try FileManager.default.createDirectory(at: ownFolder.appendingPathComponent(".hidden"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ownFolder.appendingPathComponent("notes.txt"))
        let library = MascotLibrary.read(MascotLibrary.sources(home: home))
        XCTAssertEqual(library.characters.map(\.id), ["evlat:good"])
        XCTAssertEqual(library.failures, [
            MascotLibrary.Failure(source: "evlat", folder: "climber", reason: .pet(.pictureOutside)),
            MascotLibrary.Failure(source: "evlat", folder: "empty", reason: .empty)
        ])
    }

    /// A character written as a file is found as a pet is; with both
    /// files in a folder, the file is read.
    func testACharacterFileIsFoundAndReadBeforeAPet() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mascots")
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("lantern"),
                                         to: ownFolder.appendingPathComponent("lantern"))
        try pet("both", in: ownFolder)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("pati/character.json"),
                                         to: ownFolder.appendingPathComponent("both/character.json"))
        try FileManager.default.createDirectory(at: ownFolder.appendingPathComponent("bad"),
                                                withIntermediateDirectories: true)
        try Data(#"{"version": 9, "root": {"name": "r"}}"#.utf8)
            .write(to: ownFolder.appendingPathComponent("bad/character.json"))
        let library = MascotLibrary.read(MascotLibrary.sources(home: home))
        XCTAssertEqual(library.characters.map(\.id), ["evlat:both", "evlat:lantern"])
        XCTAssertEqual(library.characters.first?.rig, Pati.character.rig, "the file, not the pet")
        XCTAssertEqual(library.failures, [MascotLibrary.Failure(source: "evlat", folder: "bad",
                                                                reason: .file(.newerVersion(9)))])
    }

    /// A character that reads but breaks the contract is said, with the
    /// first rule it breaks, and not offered.
    func testACharacterThatBreaksTheContractIsLeftOut() throws {
        let folder = ownFolder.appendingPathComponent("tilted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "root": {"name": "r"}, "states": {"review": {"steps": [{"pose": {"tilt": 9}, "move": "spring", "hold": 1}]}}}"#.utf8)
            .write(to: folder.appendingPathComponent("character.json"))
        let library = MascotLibrary.read(MascotLibrary.sources(home: home))
        XCTAssertEqual(library.characters, [])
        guard case .contract(let rule)? = library.failures.first?.reason else { return XCTFail("\(library.failures)") }
        XCTAssertTrue(rule.contains("review rests tilted"), rule)
    }

    func testNoFolderIsNoCharacters() {
        XCTAssertEqual(MascotLibrary.read(MascotLibrary.sources(home: home)), MascotLibrary())
    }

    /// The controller offers the found characters after Evlat's, draws one
    /// chosen and stores it like any other.
    func testAFoundCharacterIsOfferedChosenAndStored() throws {
        try pet("mochi", in: ownFolder)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "evlat-library-\(UUID().uuidString)"))
        let controller = AppController(defaults: defaults, home: home)
        XCTAssertEqual(controller.mascotLooks.map(\.id), MascotCharacters.all.map(\.id), "nothing read yet")
        controller.readMascots()
        XCTAssertEqual(controller.mascotLooks.map(\.id), MascotCharacters.all.map(\.id) + ["evlat:mochi"])
        XCTAssertEqual(controller.settingsHost.mascotLooks().map(\.id), controller.mascotLooks.map(\.id))
        controller.setMascotCharacter("evlat:mochi")
        XCTAssertEqual(controller.mascot.character.id, "evlat:mochi")
        XCTAssertEqual(defaults.string(forKey: AppController.mascotCharacterKey), "evlat:mochi")
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: [:], among: controller.mascotLooks).id,
                       "evlat:mochi", "drawn again at the next launch")
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: [:]).id, "cube",
                       "its folder gone, the cube")
    }

    /// `EVLAT_MASCOT` names a found character too, whatever the case of its
    /// folder's name.
    func testEvlatMascotNamesAFoundCharacter() throws {
        try pet("Mochi", in: ownFolder)
        let looks = MascotCharacters.all + MascotLibrary.read(MascotLibrary.sources(home: home)).characters
        XCTAssertEqual(AppController.forcedMascotCharacter(["EVLAT_MASCOT": "evlat:mochi"], among: looks), "evlat:Mochi")
        XCTAssertNil(AppController.forcedMascotCharacter(["EVLAT_MASCOT": "evlat:mochi"]), "not among the shipped")
    }

    /// A controller built without a home reads nothing — no test reaches the
    /// user's folders.
    func testAControllerWithoutAHomeReadsNothing() {
        let controller = AppController(defaults: nil, home: nil)
        controller.readMascots()
        XCTAssertEqual(controller.mascotLibrary, MascotLibrary())
    }
}
