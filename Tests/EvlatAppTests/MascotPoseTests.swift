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

    /// **Contract change.** This test was `testOnlyReviewTilts`: `review`
    /// rested with its head tilted until the finish was seen, and that read
    /// as stuck. Now no phase rests tilted; `review` leans on arrival and
    /// comes back upright (`MascotClip.review`), and the green ring keeps
    /// telling the finish.
    func testNoPhaseRestsTilted() {
        for phase in Phase.allCases {
            XCTAssertEqual(MascotPose.resting(for: phase).tilt, 0, "\(phase)")
        }
        let review = MascotClip.clip(for: .review, pacing: .normal)
        XCTAssertTrue(review.steps.contains { $0.pose.tilt != 0 }, "review still asks with a lean")
        XCTAssertEqual(review.steps.last?.pose.tilt, 0, "and lets it go")
    }

    /// **Contract change.** This test used to be
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

    /// A mix is a fraction of the cursor, and the phase whose job is to be
    /// noticed takes all of it. How loosely `working` holds it is the ordering
    /// test's claim below, not a number pinned here.
    func testGazeMixIsAFractionAndWaitingTakesAllOfIt() {
        XCTAssertEqual(MascotPose.resting(for: .waiting).gazeMix, 1,
                       "the phase whose job is to be noticed locks on")
        for phase in Phase.allCases {
            let mix = MascotPose.resting(for: phase).gazeMix
            XCTAssertGreaterThanOrEqual(mix, 0, "\(phase)")
            XCTAssertLessThanOrEqual(mix, 1, "\(phase)")
        }
    }

    /// **The order of the mixes is the contract**: `waiting`
    /// takes the whole cursor, `idle` most of it, `working` the least of any
    /// phase. Strict, because the point of `waiting`'s lock is that it is a
    /// *change*: if idle already stared at full mix, the phase that blocks the
    /// user would arrive looking exactly like the one that does nothing.
    func testGazeMixesAreOrderedWaitingIdleWorking() {
        let mix = { MascotPose.resting(for: $0).gazeMix }
        XCTAssertGreaterThan(mix(.idle), mix(.working))
        for phase in Phase.allCases where phase != .working {
            XCTAssertGreaterThan(mix(phase), mix(.working),
                                 "\(phase): working is the one that looks away most")
        }
        for phase in Phase.allCases where phase != .waiting {
            XCTAssertLessThan(mix(phase), mix(.waiting),
                              "\(phase): only waiting locks on")
        }
    }

    /// A state change must never snap. The transition is a spring held in one
    /// place so every phase feels the same; if it ever became a linear or
    /// zero-duration animation, v1's principle would be quietly lost.
    ///
    /// **This line was settled by eye**: the spring and an exponential
    /// ease-out were looked at side by side and the user kept the spring, so
    /// the original assertion stands unchanged.
    func testTransitionIsASpring() {
        XCTAssertEqual(MascotPose.transition, .spring(response: 0.38, dampingFraction: 0.72))
    }

    /// The five phases' faces, field by field. Dropped files added a pose
    /// that is not a phase (`catching`); the table it sits beside must not
    /// move with it.
    func testTheFivePhasesAreUnchanged() {
        XCTAssertEqual(MascotPose.resting(for: .idle), MascotPose(gazeMix: 0.85))
        XCTAssertEqual(MascotPose.resting(for: .working), MascotPose(eyeOpen: 0.92, eyeSquint: 0.34, gazeMix: 0.30))
        XCTAssertEqual(MascotPose.resting(for: .waiting), MascotPose(eyeOpen: 1.28, scaleX: 1.03, scaleY: 1.04))
        // `review` lost its held tilt on purpose (`testNoPhaseRestsTilted`).
        XCTAssertEqual(MascotPose.resting(for: .review),
                       MascotPose(eyeOpen: 1.02, eyeSquint: 0.12, gazeMix: 0.60))
        XCTAssertEqual(MascotPose.resting(for: .failed),
                       MascotPose(eyeOpen: 0.55, eyeSquint: 0.5, scaleX: 1.07, scaleY: 0.9, gazeMix: 0.45))
    }

    /// A file on its way to the bar: the eyes open
    /// wider than any phase opens them — `waiting` included, or catching
    /// would read as one more "I need you" — the body reaches up a little,
    /// and the gaze is the file's entirely. No mouth: the face is the eyes.
    func testCatchingWidensTheEyesStretchesAndLocksOn() {
        let catching = MascotPose.catching
        for phase in Phase.allCases {
            XCTAssertGreaterThan(catching.eyeOpen, MascotPose.resting(for: phase).eyeOpen, "\(phase)")
        }
        XCTAssertGreaterThan(catching.scaleY, 1, "it reaches")
        XCTAssertGreaterThan(catching.scaleY, catching.scaleX, "taller, not bigger")
        XCTAssertEqual(catching.gazeMix, 1, "the eyes are on the file")
        XCTAssertEqual(catching.eyeSquint, 0)
        XCTAssertEqual(catching.tilt, 0)
    }

    /// What the body draws: its own pose, or — while a file is caught —
    /// the catching face turned to the file, whatever the pose was.
    func testTheCaughtFaceReplacesThePose() {
        let pose = MascotPose.resting(for: .working)
        XCTAssertEqual(MascotPose.drawn(pose, catching: nil), pose)
        let toward = CGSize(width: -0.9, height: 0.2)
        XCTAssertEqual(MascotPose.drawn(pose, catching: toward), MascotPose.catching.blending(gaze: toward))
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
    /// screen. Candidate clips cannot be compared through a menu that shows
    /// nothing moving.
    func testAForcedPhaseWakesTheMascotWithNothingLive() {
        let model = MascotModel()
        model.override = .failed
        XCTAssertTrue(model.isAwake, "a forced phase has to be previewable")
        model.override = nil
        XCTAssertFalse(model.isAwake)
        model.hasLive = true
        XCTAssertTrue(model.isAwake)
    }

    /// Catching is not a phase: the aggregate and what is forced stay as
    /// they are, and an asleep mascot catches in place — the face changes
    /// on the body already drawn, so it springs rather than crossfades
    /// between two views.
    func testCatchingIsNotAPhase() {
        let model = MascotModel()
        model.phase = .working
        model.catching = true
        XCTAssertEqual(model.effectivePhase, .working)
        XCTAssertFalse(model.isAwake, "nothing live: it catches asleep, on the same body")
        XCTAssertEqual(model.caughtGaze, model.gaze)
        model.catching = false
        XCTAssertNil(model.caughtGaze)
    }
}
