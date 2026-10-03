import XCTest
@testable import EvlatCore

/// The character pack format: what a manifest must say, and what is refused.
final class CharacterPackTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/packs/heart-cube")
    private let size: (URL) -> Int? = { _ in 1000 }

    private func manifest(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["evlat_character": 1, "name": "heart-cube", "display_name": "Heart Cube", "version": "1.0.0",
         "author": "Someone", "license": "CC-BY-4.0", "body": "body.png"].merging(extra) { $1 }
    }

    private let eye: [String: Any] = ["cx": 0.4, "cy": 0.5, "length": 0.14, "width": 0.05, "tilt": 0]

    func testABodyIsEnough() throws {
        let pack = try CharacterPack.validate(manifest(), directory: root, fileSize: size).get()
        XCTAssertEqual(pack.name, "heart-cube")
        XCTAssertEqual(pack.displayName, "Heart Cube")
        XCTAssertEqual(pack.body.path, "/packs/heart-cube/body.png")
        XCTAssertTrue(pack.eyes.isEmpty)
        XCTAssertNil(pack.face)
        XCTAssertNil(pack.soundPack)
    }

    func testEyesAFaceAndASoundPackAreRead() throws {
        let pack = try CharacterPack.validate(manifest([
            "eyes": [eye, eye], "face": ["image": "heart.png", "cx": 0.5, "cy": 0.5, "size": 0.3, "tint": "status"],
            "sound_pack": "night-owls", "inspired_by": "Something",
        ]), directory: root, fileSize: size).get()
        XCTAssertEqual(pack.eyes.count, 2)
        XCTAssertEqual(pack.face?.tintsByStatus, true)
        XCTAssertEqual(pack.face?.image.lastPathComponent, "heart.png")
        XCTAssertEqual(pack.soundPack, "night-owls")
        XCTAssertEqual(pack.inspiredBy, "Something")
    }

    /// Data only, inside the pack: a manifest that reaches for anything else
    /// is refused, and says why.
    func testWhatIsRefused() {
        func why(_ json: [String: Any], size: @escaping (URL) -> Int? = { _ in 1000 }) -> CharacterPack.Rejection? {
            if case .failure(let r) = CharacterPack.validate(json, directory: root, fileSize: size) { return r }
            return nil
        }
        XCTAssertEqual(why(manifest(["evlat_character": 2])), .notACharacter)
        XCTAssertEqual(why(manifest(["name": "Bad Name"])), .badName)
        XCTAssertEqual(why(manifest(["body": "../secret.png"])), .missingBody)
        XCTAssertEqual(why(manifest(["body": "body.jpg"])), .missingBody, "PNG only")
        XCTAssertEqual(why(manifest(), size: { _ in 3 * 1_048_576 }), .missingBody, "over 2 MB")
        XCTAssertEqual(why(manifest(["eyes": [eye]])), .badEyes, "two or none")
        XCTAssertEqual(why(manifest(["eyes": [eye, ["cx": 2, "cy": 0.5, "length": 0.1, "width": 0.1]]])), .badEyes)
        XCTAssertEqual(why(manifest(["face": ["image": "heart.png", "cx": 0.5, "cy": 0.5, "size": 0]])), .badFace)
        XCTAssertNil(try? CharacterPack.validate(manifest(["sound_pack": "../x"]), directory: root, fileSize: size).get().soundPack)
    }

    func testAnExportedManifestReadsBack() throws {
        let eyes = [EyeFinder.Eye(cx: 0.3, cy: 0.5, length: 0.1, width: 0.04, tilt: 0),
                    EyeFinder.Eye(cx: 0.7, cy: 0.5, length: 0.1, width: 0.04, tilt: 0)]
        let json = CharacterPack.manifest(name: "me", displayName: "Me", author: "", license: "", eyes: eyes)
        let pack = try CharacterPack.validate(json, directory: root, fileSize: size).get()
        XCTAssertEqual(pack.eyes, eyes)
    }
}
