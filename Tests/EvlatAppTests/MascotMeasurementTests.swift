import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The measurement instrument `003/phase-2` wrote for `plan.md` → Yaklaşım 6,
/// and that `phase-3` and `phase-4` measure with: the duty cycle a clip
/// reports, the continuous variant for the in-clip leg, and the two
/// environment switches that let a script launch a measurement.
///
/// Resolution is a pure function over a dictionary — the shape
/// `HookListener.resolvePort` uses — so the fallbacks can be tested without
/// launching anything.
final class MascotMeasurementTests: XCTestCase {
    func testAnUnsetEnvironmentLeavesTheInstrumentOff() {
        XCTAssertEqual(MascotPacing.resolve([:]), .normal)
        XCTAssertNil(AppController.forcedPhase([:]))
    }

    func testTheSwitchesResolveByName() {
        for pacing in MascotPacing.allCases {
            XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: pacing.rawValue]),
                           pacing)
        }
        for phase in Phase.allCases {
            XCTAssertEqual(AppController.forcedPhase(["EVLAT_PHASE": phase.rawValue]), phase)
        }
    }

    /// Case and stray whitespace are forgiven, and a value nobody can read falls
    /// back rather than refusing: a mascot that will not start is a worse answer
    /// than one running normally, and an empty value is what an unset shell
    /// variable expands to.
    func testAnUnreadableValueFallsBack() {
        XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: ""]), .normal)
        XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: " Continuous "]),
                       .continuous)
        XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: "fast"]), .normal)
        XCTAssertNil(AppController.forcedPhase(["EVLAT_PHASE": "busy"]),
                     "not a phase name; the menu stays in charge")
        XCTAssertNil(AppController.forcedPhase(["EVLAT_PHASE": "   "]))
        XCTAssertEqual(AppController.forcedPhase(["EVLAT_PHASE": " Working "]), .working)
    }

    /// **The clip the user picked in `003/phase-2`**, pinned by what it does
    /// rather than by its numbers: it is the composite — it moves both the aim
    /// and the body — and its aim goes **down**, onto the work, never up. That
    /// is the whole reason it was chosen over a body rhythm alone and a gaze
    /// release alone; a later edit that dropped either half, or turned the gaze
    /// back toward the user, would be a different clip wearing its name.
    func testWorkingCarriesBothSignalsAndLooksDownAtTheWork() {
        let rest = MascotPose.resting(for: .working)
        let steps = MascotClip.clip(for: .working, pacing: .normal).steps
        XCTAssertTrue(steps.contains { $0.pose.yaw != rest.yaw || $0.pose.pitch != rest.pitch },
                      "working has to leave the cursor's aim")
        XCTAssertTrue(steps.contains { $0.pose.scaleY != rest.scaleY },
                      "working has to move the body")
        XCTAssertTrue(steps.allSatisfy { $0.pose.pitch >= 0 },
                      "the gaze goes down onto the work, never up")
        XCTAssertTrue(steps.contains { $0.pose.pitch > 0 })
    }

    // MARK: - Duty cycle and the continuous variant

    /// Duty cycle is `motion / hold` summed over the clip — the multiplier a
    /// 90 s window silently folds into its reading.
    func testDutyCycleCountsOnlyTheStepsThatActuallyMove() {
        let pose = MascotPose()
        let moved = MascotPose(eyeOpen: 0.5)
        let clip = MascotClip(steps: [
            .eased(pose, over: 0.5, hold: 5),
            .eased(moved, over: 0.5, hold: 5)
        ], loops: true)
        // Ten seconds, of which the eyes move for half a second twice — once
        // closing, once opening.
        XCTAssertEqual(clip.cycle, 10, accuracy: 1e-9)
        XCTAssertEqual(clip.movingTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(clip.dutyCycle ?? 0, 0.1, accuracy: 1e-9)
    }

    /// A step that lands on the pose it is already in produces no frames, so it
    /// is not motion. That is exactly step 0 of a looping clip: it re-enters the
    /// resting pose the last step already returned to. Counting it would
    /// overstate every clip in the table by a whole transition.
    func testAStepThatGoesNowhereIsNotMotion() {
        let pose = MascotPose()
        let clip = MascotClip(steps: [
            .entering(pose, hold: 4),
            .eased(pose, over: 1, hold: 6)
        ], loops: true)
        XCTAssertEqual(clip.movingTime, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.dutyCycle ?? 1, 0, accuracy: 1e-9)
    }

    /// The in-clip leg runs on a variant with the waiting taken out: the same
    /// motion, on the same curves, played end to end. Without it the 90 s window
    /// measures *cost × duty cycle* and stretching the window buys any number
    /// you like.
    func testTheContinuousVariantIsTheSameMotionWithNothingBetween() {
        for phase in Phase.allCases {
            let clip = MascotClip.clip(for: phase, pacing: .normal)
            let burst = MascotClip.clip(for: phase, pacing: .continuous)
            // Every pose the clip actually travels to is still there, in order.
            // Only the standing still is gone — including step 0, which
            // re-enters the pose the last step already returned to.
            // The variant always loops, so it re-enters step 0 from its own
            // last pose — for a one-shot clip too, which is why its entering
            // spring is not part of the measured motion.
            var previous = clip.steps.last!.pose
            var travelled: [MascotPose] = []
            for step in clip.steps where step.pose != previous {
                travelled.append(step.pose)
                previous = step.pose
            }
            XCTAssertEqual(burst.steps.map(\.pose), travelled,
                           "\(phase): the variant must show the same motion")
            XCTAssertTrue(burst.steps.allSatisfy { $0.hold == $0.motion },
                          "\(phase): a step that waits is not in-clip time")
            XCTAssertEqual(burst.dutyCycle ?? 0, 1.0, accuracy: 1e-9,
                           "\(phase): the in-clip leg has to be all clip")
            XCTAssertLessThan(burst.cycle, clip.cycle, "\(phase): the waiting is what was removed")
            // A one-shot clip's own `movingTime` counts the entering spring
            // (it is entered from another phase); the looping variant does not.
            let entering = clip.loops ? 0 : clip.steps[0].motion
            XCTAssertEqual(burst.movingTime, clip.movingTime - entering, accuracy: 1e-9,
                           "\(phase): the same motion, not less of it")
            XCTAssertTrue(burst.loops, "\(phase): it has to keep running to be read")
        }
    }
}
