import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// What each shipped character's doc says it does, held where the contract
/// cannot: the contract keeps every character honest, these keep each one
/// itself.
final class MascotCharactersTests: XCTestCase {
    private func part(_ name: String, of character: MascotCharacter) throws -> MascotPart {
        try XCTUnwrap(character.rig.parts.first { $0.name == name }, "\(character.id) has no \(name)")
    }

    private func resolved(_ name: String, of character: MascotCharacter, in pose: MascotPose) throws
        -> MascotPart.Resolved {
        try part(name, of: character).resolved(in: pose, rig: character.rig)
    }

    func testTheCatalogFindsACharacterByIdAndFallsBackToTheCube() {
        XCTAssertEqual(MascotCharacters.all.map(\.id), ["cube", "pati", "bit", "puf"])
        XCTAssertEqual(MascotCharacters.character(id: "bit").id, "bit")
        XCTAssertEqual(MascotCharacters.character(id: nil).id, "cube", "nothing chosen")
        XCTAssertEqual(MascotCharacters.character(id: "gone").id, "cube", "a choice outlives a character")
    }

    /// Pati's ears say what its eyes say: up and in while it waits, back
    /// while it works, flat on a failure — and a blink leaves them alone.
    func testPatisEarsFollowItsEyes() throws {
        let pati = Pati.character
        let rest = try resolved("leftEar", of: pati, in: pati.resting(for: .idle))
        let waiting = try resolved("leftEar", of: pati, in: pati.resting(for: .waiting))
        let working = try resolved("leftEar", of: pati, in: pati.resting(for: .working))
        let failed = try resolved("leftEar", of: pati, in: pati.resting(for: .failed))
        XCTAssertLessThan(waiting.offsetY, rest.offsetY, "waiting pricks them up")
        XCTAssertGreaterThan(waiting.rotation, rest.rotation, "and in, toward the middle")
        XCTAssertLessThan(working.rotation, rest.rotation, "working lays them back a little")
        XCTAssertLessThan(failed.rotation, working.rotation, "a failure lays them flat")
        var blink = pati.resting(for: .idle)
        blink.eyeOpen *= 0.08
        XCTAssertEqual(try resolved("leftEar", of: pati, in: blink), rest, "a blink does not twitch the ears")
        let right = try resolved("rightEar", of: pati, in: pati.resting(for: .failed))
        XCTAssertEqual(right.rotation, -failed.rotation, accuracy: 1e-9, "the ears are a mirrored pair")
    }

    /// Bit's bulb burns low at rest and bright only when the eyes open past
    /// it; its antenna droops on a failure.
    func testBitsBulbLightsOnlyWhenItWaitsOrCatches() throws {
        let bit = Bit.character
        let low = try resolved("bulb", of: bit, in: bit.resting(for: .idle)).opacity
        XCTAssertLessThan(low, 0.5)
        for phase in [Phase.idle, .working, .review, .failed] {
            XCTAssertEqual(try resolved("bulb", of: bit, in: bit.resting(for: phase)).opacity, low, "\(phase)")
        }
        XCTAssertEqual(try resolved("bulb", of: bit, in: bit.resting(for: .waiting)).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(try resolved("bulb", of: bit, in: MascotPose.catching).opacity, 1)
        XCTAssertGreaterThan(try resolved("stem", of: bit, in: bit.resting(for: .failed)).rotation, 20,
                             "the antenna droops")
    }

    /// Puf turns height into floating: a breath lifts it, a failure sinks it.
    func testPufRisesOnABreathAndSinksOnAFailure() throws {
        let puf = Puf.character
        let rest = try resolved("puf", of: puf, in: puf.resting(for: .idle))
        XCTAssertEqual(rest.offsetY, 0, accuracy: 1e-9)
        let breath = try resolved("puf", of: puf, in: puf.resting(for: .idle).scaled(by: 1.02))
        XCTAssertLessThan(breath.offsetY, 0, "a breath lifts it")
        XCTAssertLessThan(try resolved("puf", of: puf, in: puf.resting(for: .waiting)).offsetY, 0)
        XCTAssertGreaterThan(try resolved("puf", of: puf, in: puf.resting(for: .failed)).offsetY, 0,
                             "a failure sinks it")
    }

    /// A polygon's outline stays inside the frame it is drawn in: its arcs
    /// round the corners in, never out.
    func testAPolygonStaysInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 30)
        let points = [CGPoint(x: 0, y: 1), CGPoint(x: 0.2, y: 0), CGPoint(x: 1, y: 0.9)]
        let box = RoundedPolygon(points: points, radius: 2).path(in: rect).boundingRect
        XCTAssertFalse(box.isEmpty)
        XCTAssertTrue(rect.insetBy(dx: -1e-6, dy: -1e-6).contains(box), "\(box)")
        XCTAssertTrue(RoundedPolygon(points: Array(points.prefix(2)), radius: 2).path(in: rect).isEmpty,
                      "two points are no outline")
    }
}
