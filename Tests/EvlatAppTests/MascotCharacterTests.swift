import XCTest
import EvlatCore
@testable import EvlatApp

/// The mascot's looks: what is stored, what a launch reads back, how a
/// spoken moment shows, and the Custom look's maker. A temporary home and defaults suite: the
/// user's own are never touched.
@MainActor
final class MascotCharacterTests: XCTestCase {
    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("evlat.tests.mascot.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "evlat.tests.mascot.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAnUnknownCharacterIsTheCube() {
        XCTAssertEqual(MascotCharacter.stored(nil), .cube)
        XCTAssertEqual(MascotCharacter.stored("dragon"), .cube)
        XCTAssertEqual(MascotCharacter.stored("fairy"), .fairy)
    }

    func testTheCharacterIsStoredAndDrawnAtOnce() {
        let controller = AppController(defaults: defaults, home: root)
        XCTAssertEqual(controller.mascot.character, .cube, "the cube unless chosen")
        controller.settingsHost.setCharacter(.fairy)
        XCTAssertEqual(controller.mascot.character, .fairy)
        XCTAssertEqual(defaults.string(forKey: AppController.characterKey), "fairy")
        XCTAssertEqual(controller.settingsHost.character(), .fairy)
    }

    /// A moment that speaks reaches the mascot as a callout in its tone.
    func testASpokenMomentIsACalloutInItsTone() {
        XCTAssertEqual(AppController.calloutTone(for: .done), .done)
        XCTAssertEqual(AppController.calloutTone(for: .failed), .oops)
        XCTAssertEqual(AppController.calloutTone(for: .approval), .attention)
        XCTAssertEqual(AppController.calloutTone(for: .answer), .attention)
        let model = MascotModel()
        model.callOut(.done)
        model.callOut(.attention)
        XCTAssertEqual(model.callout, MascotCallout(count: 2, tone: .attention))
    }

    /// Evlat ships no prompt: none until the user pastes one, which is kept
    /// beside the character.
    func testThePromptIsTheUsersOwn() {
        XCTAssertNil(CharacterMaker.prompt(home: root))
        XCTAssertFalse(CharacterMaker.savePrompt("  \n", home: root), "nothing is not a prompt")
        XCTAssertNil(CharacterMaker.prompt(home: root))
        XCTAssertTrue(CharacterMaker.savePrompt("Draw two capsule eyes.", home: root))
        XCTAssertEqual(CharacterMaker.prompt(home: root), "Draw two capsule eyes.")
        XCTAssertEqual(CharacterMaker.promptFile(home: root).lastPathComponent, "prompt.md")
    }

    /// Without a prompt nothing runs, and the reason is the one shown.
    func testMakingWithoutAPromptSaysSo() {
        let maker = CharacterMaker()
        var adopted: Portrait?? = nil
        maker.generate(from: root.appendingPathComponent("picture.png"), home: root, maker: Self.maker,
                       name: "Maker", executable: "/bin/false", path: nil) { adopted = $0 }
        XCTAssertEqual(maker.state, .failed(.noPrompt))
        XCTAssertEqual(adopted, .some(nil))
    }

    /// With a prompt but no maker on this Mac, nothing runs and it says so.
    func testMakingWithoutTheMakerSaysSo() {
        CharacterMaker.savePrompt("Draw two capsule eyes.", home: root)
        let maker = CharacterMaker()
        maker.generate(from: root.appendingPathComponent("picture.png"), home: root, maker: Self.maker,
                       name: "Maker", executable: nil, path: nil) { _ in }
        XCTAssertEqual(maker.state, .failed(.makerMissing))
    }

    private static let maker = ImageMaker(executable: "maker") { [$0] }

    /// An icon whose eyes cannot be found is not saved.
    func testAnIconWithoutEyesIsNotSaved() {
        let blank = NSImage(size: NSSize(width: 64, height: 64))
        blank.lockFocus(); NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); blank.unlockFocus()
        XCTAssertEqual(Portrait.make(from: blank, home: root).failure, .eyes(.eyesNotFound(0)))
        XCTAssertNil(Portrait.load(home: root))
    }

    /// The cube's colours: the most urgent first, by share; white when
    /// every session rests.
    func testTheCubeBlendsTheSessionsByShare() {
        XCTAssertTrue(CubeTint.weights([:]).isEmpty)
        XCTAssertTrue(CubeTint.weights([.idle: 4]).isEmpty, "at rest the cube stays white")
        let blend = CubeTint.weights([.review: 2, .waiting: 1, .idle: 1])
        XCTAssertEqual(blend.map(\.phase), [.waiting, .review, .idle])
        XCTAssertEqual(blend.map(\.share), [0.25, 0.5, 0.25])
        XCTAssertEqual(CubeTint.corners(blend).count, 4)
    }

    /// A finish already seen rests in the blend, as it does on the face:
    /// the cube does not stay green after the user has looked.
    func testASeenFinishLeavesTheCubesColour() {
        func signal(_ entity: String, _ phase: Phase) -> Signal {
            Signal(provider: "stub", entity: entity, phase: phase, label: entity, source: .claude,
                   fidelity: .official, updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        }
        let done = signal("a", .review), running = signal("b", .working)
        XCTAssertEqual(CubeTint.counts(Registry.Snapshot(signals: [done, running])), [.review: 1, .working: 1])
        let seen = Registry.Snapshot(signals: [done, running], seen: [Finish(done)!])
        XCTAssertEqual(CubeTint.counts(seen), [.idle: 1, .working: 1])
        XCTAssertEqual(seen.aggregate, .working, "the face agrees")
    }

    func testStatusColoursAreAStoredSetting() {
        let controller = AppController(defaults: defaults, home: root)
        XCTAssertFalse(controller.mascot.cubeTint, "off unless turned on")
        controller.settingsHost.setCubeTint(true)
        XCTAssertTrue(controller.mascot.cubeTint)
        XCTAssertTrue(defaults.bool(forKey: AppController.cubeTintKey))
    }

    /// A pack folder or a zip is imported, only its own files are kept, and
    /// the picker lists it between the fairy and Custom.
    func testAPackIsImportedAndListed() throws {
        let source = root.appendingPathComponent("source/heart-cube", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        try png.write(to: source.appendingPathComponent("body.png"))
        try Data("stray".utf8).write(to: source.appendingPathComponent("notes.txt"))
        let manifest: [String: Any] = ["evlat_character": 1, "name": "heart-cube", "display_name": "Heart Cube",
                                       "body": "body.png", "sound_pack": "fairy"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("character.json"))
        let home = root.appendingPathComponent("home", isDirectory: true)
        let pack = try CharacterPacks.importPack(from: source, home: home).get()
        let installed = CharacterPacks.folder(home: home).appendingPathComponent("heart-cube")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted(),
                       ["body.png", "character.json"], "only the pack's own files")
        XCTAssertEqual(pack.displayName, "Heart Cube")

        let zip = root.appendingPathComponent("heart-cube.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(try CharacterPacks.importPack(from: zip, home: home).get().name, "heart-cube", "a zip too")

        let controller = AppController(defaults: defaults, home: home)
        controller.mascot.packs = CharacterPacks.load(home: home)
        XCTAssertEqual(controller.characterChoices.map(\.id), ["cube", "fairy", "pack:heart-cube"])
        controller.setCharacterChoice("pack:heart-cube")
        XCTAssertEqual(controller.mascot.character, .pack)
        XCTAssertEqual(controller.characterChoice, "pack:heart-cube")
    }

    /// A look's suggested voice is used when installed, and leaving the
    /// look puts the user's own back.
    func testASuggestedVoiceComesAndGoesWithItsLook() throws {
        func soundPack(_ name: String) throws {
            let pack = SoundPack.directory(home: root).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: pack.appendingPathComponent("sounds"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: pack.appendingPathComponent("sounds/Done.wav"))
            let json: [String: Any] = ["cesp_version": "1.0", "name": name, "display_name": name, "version": "1.0.0",
                                       "categories": ["task.complete": ["sounds": [["file": "sounds/Done.wav", "label": "Done"]]]]]
            try JSONSerialization.data(withJSONObject: json).write(to: pack.appendingPathComponent("openpeon.json"))
        }
        try soundPack("mine")
        try soundPack("theirs")
        let character = CharacterPacks.folder(home: root).appendingPathComponent("heart-cube")
        try FileManager.default.createDirectory(at: character, withIntermediateDirectories: true)
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        try png.write(to: character.appendingPathComponent("body.png"))
        try JSONSerialization.data(withJSONObject: ["evlat_character": 1, "name": "heart-cube", "body": "body.png",
                                                    "sound_pack": "theirs"])
            .write(to: character.appendingPathComponent("character.json"))
        let controller = AppController(defaults: defaults, home: root)
        controller.mascot.packs = CharacterPacks.load(home: root)
        controller.setVoice(.pack("mine"))
        controller.setCharacterChoice("pack:heart-cube")
        XCTAssertEqual(controller.soundVoice, .pack("theirs"))
        controller.setCharacterChoice("fairy")
        XCTAssertEqual(controller.soundVoice, .pack("mine"), "the user's own is back")

        controller.setVoice(.evlat)
        controller.setCharacterChoice("pack:heart-cube")
        controller.setCharacterChoice("cube")
        XCTAssertEqual(controller.soundVoice, .evlat, "Evlat's own tones come back too")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}
