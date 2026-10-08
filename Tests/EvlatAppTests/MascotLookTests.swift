import XCTest
import EvlatCore
@testable import EvlatApp

/// Settings → Mascot → Look: which character the bar draws, where the choice
/// is kept, and what `EVLAT_MASCOT` does to it. Every controller has a suite
/// of its own and no home.
@MainActor
final class MascotLookTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "evlat.tests.look.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNothingStoredIsTheCubeAndAStoredChoiceIsDrawn() {
        XCTAssertEqual(AppController.mascotCharacterKey, "mascot.character")
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: [:]).id, "cube")
        XCTAssertEqual(AppController.mascotCharacter(nil, environment: [:]).id, "cube", "no storage at all")
        defaults.set("bit", forKey: AppController.mascotCharacterKey)
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: [:]).id, "bit")
        defaults.set("gone", forKey: AppController.mascotCharacterKey)
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: [:]).id, "cube",
                       "a character no longer shipped falls back")
        XCTAssertEqual(defaults.string(forKey: AppController.mascotCharacterKey), "gone", "reading writes nothing")
    }

    /// For looking at one character and measuring it: forced over what is
    /// stored, never written, and an id nobody has is ignored.
    func testEvlatMascotForcesACharacterAndWritesNothing() {
        XCTAssertEqual(AppController.forcedMascotCharacter(["EVLAT_MASCOT": "pati"]), "pati")
        XCTAssertEqual(AppController.forcedMascotCharacter(["EVLAT_MASCOT": " Puf "]), "puf")
        XCTAssertNil(AppController.forcedMascotCharacter(["EVLAT_MASCOT": "dragon"]))
        XCTAssertNil(AppController.forcedMascotCharacter(["EVLAT_MASCOT": ""]))
        XCTAssertNil(AppController.forcedMascotCharacter([:]))

        defaults.set("bit", forKey: AppController.mascotCharacterKey)
        XCTAssertEqual(AppController.mascotCharacter(defaults, environment: ["EVLAT_MASCOT": "puf"]).id, "puf",
                       "the forced character comes before the stored one")
        XCTAssertEqual(defaults.string(forKey: AppController.mascotCharacterKey), "bit")
    }

    /// A choice is drawn at once and stored; Settings reads it back. Forced,
    /// it is drawn but the user's stored choice stays.
    func testAChoiceIsDrawnAtOnceAndStoredUnlessForced() {
        let controller = AppController(defaults: defaults)
        XCTAssertEqual(controller.mascot.character.id, "cube")
        controller.setMascotCharacter("pati")
        XCTAssertEqual(controller.mascot.character.id, "pati")
        XCTAssertEqual(defaults.string(forKey: AppController.mascotCharacterKey), "pati")
        XCTAssertEqual(controller.settingsHost.mascotCharacter(), "pati")

        controller.mascotForced = true
        controller.setMascotCharacter("bit")
        XCTAssertEqual(controller.mascot.character.id, "bit")
        XCTAssertEqual(defaults.string(forKey: AppController.mascotCharacterKey), "pati", "forced: not stored")
    }

    /// The setup's mascot and its pictures of the bar are the user's bar:
    /// they draw the chosen character.
    func testTheSetupDrawsTheChosenCharacter() {
        let controller = AppController(defaults: defaults)
        let flow = SetupFlowModel(settings: controller.settingsHost,
                                  setup: SetupModel(host: controller.setupHost, lang: "en"),
                                  close: {}, lang: "en")
        XCTAssertEqual(flow.mascotRig, Cube.rig)
        controller.setMascotCharacter("puf")
        XCTAssertEqual(flow.mascotRig, Puf.rig)
    }

    /// Every character has its name in every table: a missing one would show
    /// the key on the tile.
    func testEveryCharacterIsNamedInEveryLanguage() {
        for language in L10nTests.languages {
            for character in MascotCharacters.all {
                let name = L10n.t(character.nameKey, in: language)
                XCTAssertFalse(name.isEmpty || name == character.nameKey, "\(language): \(character.id)")
            }
            for key in ["settings.mascot.look", "settings.mascot.look.note"] {
                XCTAssertNotEqual(L10n.t(key, in: language), key, "\(language): \(key)")
            }
        }
    }
}
