import XCTest
import EvlatCore
@testable import EvlatApp

/// The phase → expression table. Aesthetics are judged by eye, but the table
/// itself carries claims that can silently drift.
final class MascotPoseTests: XCTestCase {
    func testEveryPhaseHasARestingPose() {
        for phase in Phase.allCases {
            let pose = MascotPose.resting(for: phase)
            XCTAssertGreaterThan(pose.eyeOpen, 0, "\(phase): the eyes must not be shut at rest")
            XCTAssertGreaterThan(pose.scaleX, 0, "\(phase)")
            XCTAssertGreaterThan(pose.scaleY, 0, "\(phase)")
        }
    }

    /// `waiting` has one job: be noticed. Its eyes must be the widest of all,
    /// otherwise the state that actually blocks the user reads as the calmest.
    func testWaitingHasTheWidestEyes() {
        let waiting = MascotPose.resting(for: .waiting).eyeOpen
        for phase in Phase.allCases where phase != .waiting {
            XCTAssertGreaterThan(waiting, MascotPose.resting(for: phase).eyeOpen, "\(phase)")
        }
    }

    /// `working` means focus, so the eyes narrow relative to rest.
    func testWorkingNarrowsTheEyes() {
        XCTAssertGreaterThan(MascotPose.resting(for: .working).eyeSquint,
                             MascotPose.resting(for: .idle).eyeSquint)
    }

    /// `failed` squashes: wider than tall.
    func testFailedSquashesTheBody() {
        let failed = MascotPose.resting(for: .failed)
        XCTAssertGreaterThan(failed.scaleX, failed.scaleY)
        XCTAssertLessThan(failed.eyeOpen, MascotPose.resting(for: .idle).eyeOpen,
                          "the lids come down on failure")
    }

    /// `review` is the only phase that tilts the head.
    func testOnlyReviewTilts() {
        for phase in Phase.allCases {
            let tilt = MascotPose.resting(for: phase).tilt
            if phase == .review {
                XCTAssertNotEqual(tilt, 0)
            } else {
                XCTAssertEqual(tilt, 0, "\(phase)")
            }
        }
    }

    /// **Contract change (`003/phase-1`).** This test used to be
    /// `testRestingPosesCarryNoGaze` and it coded the rule "gaze is written over
    /// every phase, unconditionally" — `MascotView` did `p.yaw = gaze.width` and
    /// erased whatever the pose asked for, which made `yaw` and `pitch` the two
    /// of seven fields no phase could reach. The rule was deliberately broken,
    /// so the test is replaced rather than deleted: gaze is now **blended in**
    /// by `gazeMix`.
    ///
    /// What survives unchanged: the table still aims straight ahead, so a phase
    /// that takes the full gaze looks exactly where it used to.
    func testGazeIsBlendedInNotWrittenOver() {
        let gaze = CGSize(width: 0.8, height: -0.5)
        for phase in Phase.allCases {
            let rest = MascotPose.resting(for: phase)
            XCTAssertEqual(rest.yaw, 0, "\(phase): the table aims straight ahead")
            XCTAssertEqual(rest.pitch, 0, "\(phase)")

            // Full mix is the old behaviour, exactly.
            var full = rest
            full.gazeMix = 1
            XCTAssertEqual(full.blending(gaze: gaze).yaw, gaze.width, accuracy: 1e-9, "\(phase)")
            XCTAssertEqual(full.blending(gaze: gaze).pitch, gaze.height, accuracy: 1e-9, "\(phase)")

            // No mix means no gaze: the pose keeps its own aim. This is the
            // half the old rule made impossible.
            var none = rest
            none.gazeMix = 0
            none.yaw = 0.3
            none.pitch = -0.2
            XCTAssertEqual(none.blending(gaze: gaze).yaw, 0.3, accuracy: 1e-9, "\(phase)")
            XCTAssertEqual(none.blending(gaze: gaze).pitch, -0.2, accuracy: 1e-9, "\(phase)")
        }
    }

    /// Between the two ends the face is *partly* somewhere else, and it lands
    /// proportionally: half the mix, half the way to the cursor.
    func testAPartialMixLandsBetweenThePoseAndTheCursor() {
        let pose = MascotPose(yaw: -1, pitch: 1, gazeMix: 0.5)
        let blended = pose.blending(gaze: CGSize(width: 1, height: -1))
        XCTAssertEqual(blended.yaw, 0, accuracy: 1e-9)
        XCTAssertEqual(blended.pitch, 0, accuracy: 1e-9)
    }

    /// `working` is the phase that gives up the cursor: an agent busy with its
    /// own work does not stare at you. The value was nailed by eye in
    /// `003/phase-2` — the user picked the clip whose gaze is half released and
    /// aimed down onto the work.
    func testWorkingHoldsTheCursorMoreLoosely() {
        XCTAssertEqual(MascotPose.resting(for: .working).gazeMix, 0.30, accuracy: 1e-9,
                       "the mix picked in 003/phase-2")
        XCTAssertLessThan(MascotPose.resting(for: .working).gazeMix,
                          MascotPose.resting(for: .idle).gazeMix)
        XCTAssertEqual(MascotPose.resting(for: .waiting).gazeMix, 1,
                       "the phase whose job is to be noticed locks on")
        for phase in Phase.allCases {
            let mix = MascotPose.resting(for: phase).gazeMix
            XCTAssertGreaterThanOrEqual(mix, 0, "\(phase)")
            XCTAssertLessThanOrEqual(mix, 1, "\(phase)")
        }
    }

    /// A state change must never snap. The transition is a spring held in one
    /// place so every phase feels the same; if it ever became a linear or
    /// zero-duration animation, v1's principle would be quietly lost.
    ///
    /// **Karar 2 is settled by this line** (`003/phase-2`): the spring and an
    /// exponential ease-out were looked at side by side and the user kept the
    /// spring, so the assertion `001` wrote stands unchanged.
    func testTransitionIsASpring() {
        XCTAssertEqual(MascotPose.transition, .spring(response: 0.38, dampingFraction: 0.72))
    }
}

/// The model decides what the view shows.
@MainActor
final class MascotModelTests: XCTestCase {
    func testOverrideWinsOverTheLiveAggregate() {
        let model = MascotModel()
        model.phase = .working
        XCTAssertEqual(model.effectivePhase, .working)
        model.override = .waiting
        XCTAssertEqual(model.effectivePhase, .waiting, "a forced state is what gets drawn")
        model.override = nil
        XCTAssertEqual(model.effectivePhase, .working, "clearing it returns to the sessions")
    }

    func testStartsAsleep() {
        let model = MascotModel()
        XCTAssertFalse(model.hasLive, "with nothing live the animations stay out of the tree")
        XCTAssertFalse(model.isAwake)
        XCTAssertEqual(model.gaze, .zero)
    }

    /// A forced phase has to wake the clip layer even with nothing live.
    ///
    /// `AppController` writes only `override` when a phase is forced from the
    /// status menu, and the view branched on `hasLive` alone — so the one way to
    /// look at `waiting` or `failed` without hooks put a **motionless** cube on
    /// screen. `003/phase-2` cannot compare candidate clips through a menu that
    /// shows nothing moving.
    func testAForcedPhaseWakesTheMascotWithNothingLive() {
        let model = MascotModel()
        model.override = .failed
        XCTAssertTrue(model.isAwake, "a forced phase has to be previewable")
        model.override = nil
        XCTAssertFalse(model.isAwake)
        model.hasLive = true
        XCTAssertTrue(model.isAwake)
    }
}
