import XCTest
import EvlatCore
@testable import EvlatApp

/// The rig: what a binding does, and the cube drawn through one.
final class RigTests: XCTestCase {
    // MARK: - Bindings

    func testABindingMapsItsInputOntoItsOutputLinearly() {
        let b = MascotBinding(.yaw, .offsetX, from: (-1, 1), to: (-0.11, 0.11))
        XCTAssertEqual(b.output(for: -1), -0.11, accuracy: 1e-12)
        XCTAssertEqual(b.output(for: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(b.output(for: 0.5), 0.055, accuracy: 1e-12)
        let downhill = MascotBinding(.yaw, .width, from: (0, 1), to: (1, 0.58))
        XCTAssertEqual(downhill.output(for: 0.5), 0.79, accuracy: 1e-12, "an output may run downhill")
    }

    /// Clamping is what makes a binding one-sided: the right eye narrows as
    /// the face turns right and is left alone however far it turns left.
    func testAValueOutsideTheInputIsHeldAtItsEnd() {
        let b = MascotBinding(.yaw, .width, from: (0, 1), to: (1, 0.58))
        XCTAssertEqual(b.output(for: -0.7), 1, accuracy: 1e-12)
        XCTAssertEqual(b.output(for: 3), 0.58, accuracy: 1e-12)
    }

    /// Positions and angles add; sizes, scales and opacity multiply — so two
    /// controls can share a property without knowing about each other.
    func testBindingsOnOnePropertyAddOrMultiply() {
        let part = MascotPart(name: "p", bindings: [
            MascotBinding(.yaw, .offsetX, from: (0, 1), to: (0, 0.2)),
            MascotBinding(.pitch, .offsetX, from: (0, 1), to: (0, 0.1)),
            .follows(.eyeOpen, .height, over: (0, 2)),
            MascotBinding(.eyeSquint, .height, from: (0, 1), to: (1, 0.5)),
            MascotBinding(.tilt, .rotation, from: (0, 10), to: (0, 10)),
            MascotBinding(.tilt, .rotation, from: (0, 10), to: (0, 20))
        ])
        let rig = MascotRig(root: part)
        let r = part.resolved(in: MascotPose(yaw: 1, pitch: 1, eyeOpen: 0.5, eyeSquint: 1, tilt: 5), rig: rig)
        XCTAssertEqual(r.offsetX, 0.3, accuracy: 1e-12)
        XCTAssertEqual(r.height, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.rotation, 15, accuracy: 1e-12)
        XCTAssertEqual(r.width, 1, "a property no binding moves stays at rest")
    }

    /// A control the pose does not carry moves nothing — its binding is left
    /// out, rather than read as zero and driving the part to an end.
    func testAControlThePoseDoesNotCarryDrivesNothing() {
        let part = MascotPart(name: "p", bindings: [
            MascotBinding(MascotControl("nobody"), .opacity, from: (0, 1), to: (0, 1))
        ])
        XCTAssertEqual(part.resolved(in: MascotPose(), rig: MascotRig(root: part)).opacity, 1)
    }

    // MARK: - The cube

    /// **The cube is drawn by the formulas it had before it was a rig.**
    ///
    /// Before the rig the cube was a view: a rounded square, two capsules in
    /// a row spaced 0.16 of the side, the row shifted by the gaze, the far eye
    /// narrowed by 0.42 as the face turned, each eye 0.30 tall times
    /// `eyeOpen`, a squint taking 55% of that and lowering it by 0.04, and an
    /// eye never flatter than 0.35 of its width. Those formulas are written
    /// out below and the rig is held to them across the poses the clips use
    /// and a sweep of the gaze. The row laid its eyes out by their drawn
    /// widths, which is why the near eye slides in as the far one narrows.
    ///
    /// Rendered side by side with the old view the two agree to the pixel
    /// except where the old row snapped an eye to the pixel grid (half a
    /// pixel at most, at ten times the size); that comparison was a one-time
    /// probe, and this is the claim that stays.
    func testTheCubeIsDrawnByTheFormulasItHadBeforeItWasARig() throws {
        let rig = Cube.rig
        let face = try XCTUnwrap(rig.parts.first { $0.name == "face" })
        XCTAssertEqual(face.shape, .roundedRectangle(cornerRadius: 0.3))
        XCTAssertEqual(face.size, CGSize(width: 1, height: 1))
        XCTAssertTrue(face.bindings.isEmpty, "the face itself does not move; the whole cube does")

        for pose in Self.poses {
            let root = rig.root.resolved(in: pose, rig: rig)
            XCTAssertEqual(root.scaleX, pose.scaleX, accuracy: 1e-12)
            XCTAssertEqual(root.scaleY, pose.scaleY, accuracy: 1e-12)
            XCTAssertEqual(root.rotation, pose.tilt, accuracy: 1e-12)

            let width = { (side: Double) in 0.13 * (1 - max(0, side * pose.yaw) * 0.42) }
            for side in [-1.0, 1.0] {
                let eye = try XCTUnwrap(rig.parts.first { $0.name == (side < 0 ? "leftEye" : "rightEye") })
                XCTAssertEqual(eye.shape, .capsule(minimumHeight: 0.35))
                let r = eye.resolved(in: pose, rig: rig)

                let w = width(side)
                let h = max(w * 0.35, 0.30 * pose.eyeOpen * (1 - pose.eyeSquint * 0.55))
                // In the row: the left eye's centre is half of the right
                // eye's width and the gap to the left of the middle, and the
                // other way round.
                let rowX = side < 0 ? -(width(1) + 0.16) / 2 : (width(-1) + 0.16) / 2
                let x = rowX + pose.yaw * 0.11
                let y = pose.eyeSquint * 0.04 + pose.pitch * 0.08

                let drawnW = eye.size.width * r.width
                let drawnH = max(drawnW * 0.35, eye.size.height * r.height)
                let at = "\(side < 0 ? "left" : "right") eye in \(pose)"
                XCTAssertEqual(drawnW, w, accuracy: 1e-12, at)
                XCTAssertEqual(drawnH, h, accuracy: 1e-12, at)
                XCTAssertEqual(eye.center.x + r.offsetX, x, accuracy: 1e-12, at)
                XCTAssertEqual(eye.center.y + r.offsetY, y, accuracy: 1e-12, at)
                XCTAssertEqual(r.scaleX, 1); XCTAssertEqual(r.scaleY, 1)
                XCTAssertEqual(r.rotation, 0); XCTAssertEqual(r.opacity, 1)
            }
        }
    }

    /// Every pose the clips and the catching face reach, and a sweep of the
    /// gaze across both axes on top of each phase's rest.
    private static var poses: [MascotPose] {
        var out: [MascotPose] = [MascotPose.catching]
        for phase in Phase.allCases {
            out += MascotClip.clip(for: phase, pacing: .normal).steps.map(\.pose)
            let rest = MascotPose.resting(for: phase)
            for x in stride(from: -1.0, through: 1.0, by: 0.25) {
                for y in [-1.0, 0, 0.6] {
                    out.append(rest.blending(gaze: CGSize(width: x, height: y)))
                }
            }
        }
        return out
    }

    /// SwiftUI tells parts apart by name: two parts with one name would
    /// animate as one.
    func testTheCubesPartsHaveDistinctNames() {
        let names = Cube.rig.parts.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
    }
}
