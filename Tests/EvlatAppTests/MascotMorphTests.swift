import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// A polygon's morphs move its points one by one: an eye that shuts from
/// the top rather than squashing as a box would.
final class MascotMorphTests: XCTestCase {
    /// A square, and the square with its top edge brought down to its middle.
    private let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    private let lidded = [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    private let widened = [CGPoint(x: -0.2, y: 0), CGPoint(x: 1.2, y: 0), CGPoint(x: 1.2, y: 1), CGPoint(x: -0.2, y: 1)]

    /// Each point goes its own way by the weight; the bottom edge, which
    /// the lid does not move, stays where it is.
    func testAMorphMovesEachPointByItsWeight() {
        let lid = MascotMorph(.eyeOpen, from: (1, 0), to: lidded)
        XCTAssertEqual(MascotMorph.blend(square, [lid], weights: [0]), square)
        XCTAssertEqual(MascotMorph.blend(square, [lid], weights: [1]), lidded)
        let half = MascotMorph.blend(square, [lid], weights: [0.5])
        XCTAssertEqual(half.map(\.y), [0.25, 0.25, 1, 1])
        XCTAssertEqual(half.map(\.x), [0, 1, 1, 0])
    }

    /// Two morphs add, so a lid and a widening compose.
    func testMorphsAdd() {
        let lid = MascotMorph(.eyeOpen, from: (1, 0), to: lidded)
        let wide = MascotMorph(MascotControl("wide"), from: (0, 1), to: widened)
        let both = MascotMorph.blend(square, [lid, wide], weights: [1, 1])
        XCTAssertEqual(both, [CGPoint(x: -0.2, y: 0.5), CGPoint(x: 1.2, y: 0.5), CGPoint(x: 1.2, y: 1), CGPoint(x: -0.2, y: 1)])
    }

    /// The weight is the control over its input, clamped onto 0…1 — and
    /// the input may run downhill: an eye shuts as `eyeOpen` falls.
    func testTheWeightIsTheControlOverItsInputClamped() {
        let lid = MascotMorph(.eyeOpen, from: (1, 0), to: lidded)
        XCTAssertEqual(lid.weight(for: 1), 0)
        XCTAssertEqual(lid.weight(for: 0.25), 0.75)
        XCTAssertEqual(lid.weight(for: 0), 1)
        XCTAssertEqual(lid.weight(for: 1.3), 0, "open wider than rest: no lid")
        XCTAssertEqual(lid.weight(for: -1), 1)
    }

    /// The weights a pose gives, read through the rig: a standard control,
    /// an own one at its rest, and a name nobody declared, which weighs
    /// nothing.
    func testWeightsAreReadFromThePose() {
        let smile = MascotControl("smile")
        let shape = MascotShape.polygon(points: square, cornerRadius: 0, morphs: [
            MascotMorph(.eyeOpen, from: (1, 0), to: lidded),
            MascotMorph(smile, from: (0, 1), to: widened),
            MascotMorph(MascotControl("nobody"), from: (0, 1), to: widened)
        ])
        let rig = MascotRig(root: MascotPart(name: "r", shape: shape), controls: [smile: .init(0, 1, rest: 0.25)])
        XCTAssertEqual(shape.weights(in: MascotPose(eyeOpen: 0.5), rig: rig), [0.5, 0.25, 0])
        XCTAssertEqual(shape.weights(in: MascotPose().setting(smile, to: 1), rig: rig), [0, 1, 0])
        XCTAssertEqual(MascotShape.capsule(minimumHeight: 1).weights(in: MascotPose(), rig: rig), [])
    }

    /// The weights are what a spring interpolates: a vector that adds,
    /// subtracts and scales, a shorter one padded with zeros.
    func testWeightsAnimateAsAVector() {
        var a = MorphWeights([1, 0.5])
        let b = MorphWeights([0.5])
        XCTAssertEqual((a - b).values, [0.5, 0.5])
        XCTAssertEqual((a + b).values, [1.5, 0.5])
        a.scale(by: 2)
        XCTAssertEqual(a.values, [2, 1])
        XCTAssertEqual(a.magnitudeSquared, 5)
        XCTAssertEqual(MorphWeights([0, 0]), .zero)
        var shape = RoundedPolygon(points: square, radius: 0, morphs: [MascotMorph(.eyeOpen, from: (1, 0), to: lidded)],
                                   weights: MorphWeights([0]))
        shape.animatableData = MorphWeights([1])
        XCTAssertEqual(shape.path(in: CGRect(x: 0, y: 0, width: 10, height: 10)).boundingRect,
                       CGRect(x: 0, y: 5, width: 10, height: 5), "drawn at the weight it was animated to")
    }

    /// Drawn, a lidded eye covers the top of its frame no more.
    @MainActor
    func testAMorphedPolygonDrawsItsOutline() throws {
        let shape = MascotShape.polygon(points: square, cornerRadius: 0,
                                        morphs: [MascotMorph(.eyeOpen, from: (1, 0), to: lidded)])
        let rig = MascotRig(root: MascotPart(name: "r", shape: shape, fill: .white))
        func topInk(_ pose: MascotPose) throws -> UInt8 {
            let image = try XCTUnwrap(ImageRenderer(content: RigBody(rig: rig, pose: pose, size: 40)
                .frame(width: 40, height: 40)).cgImage)
            let top = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 2, width: image.width, height: image.height / 4)))
            return MascotPictures.centre(of: top).alpha
        }
        XCTAssertGreaterThan(try topInk(MascotPose(eyeOpen: 1)), 200, "open: the top is drawn")
        XCTAssertEqual(try topInk(MascotPose(eyeOpen: 0)), 0, "shut: the lid took the top")
    }

    /// A morph names a declared control over a real range, and moves every
    /// point the outline has.
    func testTheContractHoldsMorphs() {
        func broken(_ morph: MascotMorph) -> [String] {
            MascotContract.violations(of: MascotCharacter(id: "m", rig: MascotRig(root: MascotPart(
                name: "r", children: [MascotPart(name: "eye", shape: .polygon(points: square, cornerRadius: 0,
                                                                              morphs: [morph]))]))))
        }
        XCTAssertFalse(broken(MascotMorph(.eyeOpen, from: (1, 0), to: lidded)).contains { $0.contains("morph") })
        XCTAssertTrue(broken(MascotMorph(MascotControl("lid"), from: (0, 1), to: lidded))
            .contains { $0.contains("morph's lid is not declared") })
        XCTAssertTrue(broken(MascotMorph(.eyeOpen, from: (1, 1), to: lidded)).contains { $0.contains("no input range") })
        XCTAssertTrue(broken(MascotMorph(.eyeOpen, from: (1, 0), to: Array(lidded.prefix(3))))
            .contains { $0.contains("has 3 points, the outline 4") })
    }

    /// A character file spells a morph, and reads back as the code.
    func testACharacterFileSpellsMorphs() throws {
        let json = #"""
        {"version": 1, "root": {"name": "eye", "shape": {"polygon": {
          "points": [[0, 0], [1, 0], [1, 1], [0, 1]], "cornerRadius": 0.01,
          "morphs": [{"control": "eyeOpen", "from": [1, 0], "points": [[0, 0.5], [1, 0.5], [1, 1], [0, 1]]}]}}}}
        """#
        let character = try CharacterFile.character(from: Data(json.utf8), folder: URL(fileURLWithPath: "/"), id: "m")
        XCTAssertEqual(character.rig.root.shape,
                       .polygon(points: square, cornerRadius: 0.01, morphs: [MascotMorph(.eyeOpen, from: (1, 0), to: lidded)]))
    }
}
