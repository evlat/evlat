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

    /// Resting poses carry no gaze: gaze comes from the cursor and rides on top
    /// of whatever phase is showing.
    func testRestingPosesCarryNoGaze() {
        for phase in Phase.allCases {
            XCTAssertEqual(MascotPose.resting(for: phase).yaw, 0, "\(phase)")
            XCTAssertEqual(MascotPose.resting(for: phase).pitch, 0, "\(phase)")
        }
    }

    /// A state change must never snap. The transition is a spring held in one
    /// place so every phase feels the same; if it ever became a linear or
    /// zero-duration animation, v1's principle would be quietly lost.
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
        XCTAssertEqual(model.gaze, .zero)
    }
}
