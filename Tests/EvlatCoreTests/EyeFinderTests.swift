import XCTest
@testable import EvlatCore

/// Finding a bot icon's two capsule eyes, on pictures drawn here pixel by
/// pixel: a near-black background, a face, and whatever the case needs.
final class EyeFinderTests: XCTestCase {
    private let side = 200
    private let background: (UInt8, UInt8, UInt8) = (28, 28, 30)
    private let skin: (UInt8, UInt8, UInt8) = (250, 214, 180)
    private let ink: (UInt8, UInt8, UInt8) = (25, 25, 27)

    private func picture(_ paint: (Int, Int) -> (UInt8, UInt8, UInt8)?) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let c = paint(x, y) ?? background
                let i = (y * side + x) * 4
                buffer[i] = c.0; buffer[i + 1] = c.1; buffer[i + 2] = c.2
            }
        }
        return buffer
    }

    /// Inside a capsule centred at (cx, cy), `length` long and `width` wide,
    /// its long axis leaning `tilt` degrees clockwise from upright.
    private func inCapsule(_ x: Int, _ y: Int, cx: Double, cy: Double, length: Double, width: Double,
                           tilt: Double) -> Bool {
        let a = tilt * .pi / 180
        let dx = Double(x) - cx, dy = Double(y) - cy
        // Into the capsule's own frame: `u` across, `v` along.
        let u = dx * cos(a) + dy * sin(a), v = -dx * sin(a) + dy * cos(a)
        let r = width / 2, half = length / 2 - r
        let along = max(0, abs(v) - half)
        return u * u + along * along <= r * r
    }

    private func inFace(_ x: Int, _ y: Int) -> Bool {
        let dx = Double(x) - 100, dy = Double(y) - 110
        return dx * dx + dy * dy <= 80 * 80
    }

    private func face(eyes: [(cx: Double, cy: Double, length: Double)], tilt: Double = 0, ring: Bool = false) -> [UInt8] {
        picture { x, y in
            guard inFace(x, y) else { return nil }
            for eye in eyes where inCapsule(x, y, cx: eye.cx, cy: eye.cy, length: eye.length, width: eye.length / 2.7, tilt: tilt) {
                return ink
            }
            if ring {
                let d = (Double(x) - 70) * (Double(x) - 70) + (Double(y) - 110) * (Double(y) - 110)
                if d >= 22 * 22 && d <= 25 * 25 { return ink }
            }
            return skin
        }
    }

    func testTwoCapsuleEyesAreFoundLeftFirst() throws {
        let found = try EyeFinder.find(rgba: face(eyes: [(130, 100, 30), (70, 110, 30)]), width: side, height: side).get()
        XCTAssertEqual(found.eyes.count, 2)
        XCTAssertEqual(found.eyes[0].cx, 70.0 / 200, accuracy: 0.01)
        XCTAssertEqual(found.eyes[1].cx, 130.0 / 200, accuracy: 0.01)
        XCTAssertEqual(found.eyes[0].cy, 110.0 / 200, accuracy: 0.01)
        XCTAssertEqual(found.eyes[0].length, 30.0 / 200, accuracy: 0.02)
        XCTAssertEqual(found.eyes[0].tilt, 0, accuracy: 3)
    }

    /// The prompt tilts the head clockwise; the eyes say by how much.
    func testTheTiltIsRead() throws {
        let found = try EyeFinder.find(rgba: face(eyes: [(70, 105, 32), (128, 120, 32)], tilt: 18),
                                       width: side, height: side).get()
        for eye in found.eyes { XCTAssertEqual(eye.tilt, 18, accuracy: 3) }
        let other = try EyeFinder.find(rgba: face(eyes: [(70, 105, 32), (128, 120, 32)], tilt: -15),
                                       width: side, height: side).get()
        for eye in other.eyes { XCTAssertEqual(eye.tilt, -15, accuracy: 3) }
    }

    /// The background touches the edge and is never an eye; a glasses rim is
    /// a ring, not a solid capsule.
    func testTheBackgroundAndARimAreNotEyes() throws {
        let found = try EyeFinder.find(rgba: face(eyes: [(70, 110, 30), (130, 110, 30)], ring: true),
                                       width: side, height: side).get()
        XCTAssertEqual(found.eyes.map { ($0.cx * 200).rounded() }, [70, 130])
    }

    func testTheEyesArePaintedOutInTheFace() throws {
        let found = try EyeFinder.find(rgba: face(eyes: [(70, 110, 30), (130, 110, 30)]), width: side, height: side).get()
        for x in [70, 130] {
            let i = (110 * side + x) * 4
            XCTAssertEqual([found.cleaned[i], found.cleaned[i + 1], found.cleaned[i + 2]], [skin.0, skin.1, skin.2])
        }
        let corner = 0
        XCTAssertEqual(found.cleaned[corner], background.0, "the background is untouched")
    }

    func testAnIconThatIsNotTheSpecIsSaidSo() {
        XCTAssertEqual(EyeFinder.find(rgba: face(eyes: [(70, 110, 30)]), width: side, height: side),
                       .failure(.eyesNotFound(1)))
        XCTAssertEqual(EyeFinder.find(rgba: face(eyes: []), width: side, height: side),
                       .failure(.eyesNotFound(0)))
        XCTAssertEqual(EyeFinder.find(rgba: face(eyes: [(70, 110, 40), (130, 110, 22)]), width: side, height: side),
                       .failure(.eyesDoNotMatch))
        // Round dots are not capsules.
        let dots = picture { x, y in
            guard inFace(x, y) else { return nil }
            for cx in [70.0, 130.0] where (Double(x) - cx) * (Double(x) - cx) + (Double(y) - 110) * (Double(y) - 110) <= 81 {
                return self.ink
            }
            return self.skin
        }
        XCTAssertEqual(EyeFinder.find(rgba: dots, width: side, height: side), .failure(.eyesNotFound(0)))
        XCTAssertEqual(EyeFinder.find(rgba: [1, 2, 3], width: side, height: side), .failure(.badBuffer))
    }
}

extension Result where Success == EyeFinder.Found, Failure == EyeFinder.Failure {
    /// Failures compare; a success is never expected equal here.
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .failure(let a) = lhs, case .failure(let b) = rhs { return a == b }
        return false
    }
}

/// Shaping a found icon into a floating head (`PortraitShaper`).
final class PortraitShaperTests: XCTestCase {
    private let side = 160

    /// A tilted face on the dark background, its eyes already painted out:
    /// a skin disc with a darker "hair" cap at the top.
    private func tiltedFace() -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - 80, dy = Double(y) - 85
                let i = (y * side + x) * 4
                var c: (UInt8, UInt8, UInt8) = (26, 26, 26)
                if dx * dx + dy * dy <= 55 * 55 { c = dy < -30 ? (58, 39, 31) : (232, 170, 120) }
                buffer[i] = c.0; buffer[i + 1] = c.1; buffer[i + 2] = c.2
            }
        }
        return buffer
    }

    private let eyes = [EyeFinder.Eye(cx: 0.38, cy: 0.5, length: 0.12, width: 0.045, tilt: 18),
                        EyeFinder.Eye(cx: 0.6, cy: 0.57, length: 0.12, width: 0.045, tilt: 18)]

    func testTheBackgroundGoesAndTheFaceStays() {
        let shaped = PortraitShaper.shape(rgba: tiltedFace(), side: side, eyes: eyes, out: 128)
        XCTAssertEqual(shaped.side, 128)
        XCTAssertEqual(shaped.rgba[3], 0, "a corner is transparent")
        let centre = (64 * 128 + 64) * 4
        XCTAssertEqual(shaped.rgba[centre + 3], 255, "the face is opaque")
        XCTAssertGreaterThan(shaped.rgba[centre], 200, "and still skin")
    }

    /// Dark hair warmer than the neutral background is not background.
    func testDarkHairIsNotBackground() {
        var buffer = tiltedFace()
        PortraitShaper.clearBackground(&buffer, side: side)
        let hair = (32 * side + 80) * 4
        XCTAssertEqual(buffer[hair + 3], 255)
        XCTAssertEqual(buffer[3], 0)
    }

    /// Upright: the eyes' lean is taken out of the picture and the eyes, and
    /// the head fills the side.
    func testTheHeadIsTurnedUprightAndFillsTheSide() throws {
        let shaped = PortraitShaper.shape(rgba: tiltedFace(), side: side, eyes: eyes, out: 128)
        for eye in shaped.eyes {
            XCTAssertEqual(eye.tilt, 0, accuracy: 0.001)
            XCTAssertGreaterThan(eye.length, 0.12, "cropped to the head, the eyes are bigger")
        }
        let box = try XCTUnwrap(PortraitShaper.opaqueBox(shaped.rgba, side: 128))
        XCTAssertGreaterThan(max(box.w, box.h), 115)
    }

    /// A point and its eye go through the same turn.
    func testAnEyeTurnsWithThePicture() {
        let eye = EyeFinder.Eye(cx: 1, cy: 0.5, length: 0.1, width: 0.04, tilt: 10)
        let turned = PortraitShaper.turn(eye, side: 100, into: 100, degrees: 90)
        XCTAssertEqual(turned.cx, 0.5, accuracy: 0.001, "the right edge, turned clockwise, is at the bottom")
        XCTAssertEqual(turned.cy, 1, accuracy: 0.001)
        XCTAssertEqual(turned.tilt, 100, accuracy: 0.001)
    }
}
