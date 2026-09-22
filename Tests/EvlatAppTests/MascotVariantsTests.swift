import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The knobs `003/phase-2` reads from the environment, and the measurement
/// instrument built on them.
///
/// Resolution is a pure function over a dictionary — the shape
/// `HookListener.resolvePort` uses — so the fallbacks can be tested without
/// launching anything.
final class MascotVariantsTests: XCTestCase {
    func testAnUnsetEnvironmentLeavesEverythingAtTheShippedDefault() {
        XCTAssertEqual(MascotWorking.resolve([:]), .breath,
                       "the candidate closest to what phase-1 shipped")
        XCTAssertEqual(MascotCurve.resolve([:]), .spring, "001's curve until the user says otherwise")
        XCTAssertEqual(MascotPacing.resolve([:]), .normal, "the instrument is off unless asked for")
        XCTAssertNil(AppController.forcedPhase([:]))
    }

    func testEveryCandidateCanBeSelectedByName() {
        for candidate in MascotWorking.allCases {
            XCTAssertEqual(MascotWorking.resolve([MascotWorking.environmentKey: candidate.rawValue]),
                           candidate)
        }
        for curve in MascotCurve.allCases {
            XCTAssertEqual(MascotCurve.resolve([MascotCurve.environmentKey: curve.rawValue]), curve)
        }
        for pacing in MascotPacing.allCases {
            XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: pacing.rawValue]),
                           pacing)
        }
        for phase in Phase.allCases {
            XCTAssertEqual(AppController.forcedPhase(["EVLAT_PHASE": phase.rawValue]), phase)
        }
    }

    /// Case and stray whitespace are forgiven, and a value nobody can read falls
    /// back rather than refusing. These are looking-at instruments: a mascot
    /// that will not start is a worse answer than one showing the default, and
    /// an empty value is what an unset shell variable expands to.
    func testAnUnreadableValueFallsBack() {
        for raw in ["", "   ", "Glance", " GLANCE ", "nope", "1"] {
            let resolved = MascotWorking.resolve([MascotWorking.environmentKey: raw])
            let expected: MascotWorking = raw.trimmingCharacters(in: .whitespaces)
                .lowercased() == "glance" ? .glance : .breath
            XCTAssertEqual(resolved, expected, "EVLAT_MASCOT_WORKING=\(raw)")
        }
        XCTAssertEqual(MascotCurve.resolve([MascotCurve.environmentKey: "quintic"]), .spring)
        XCTAssertEqual(MascotPacing.resolve([MascotPacing.environmentKey: "fast"]), .normal)
        XCTAssertNil(AppController.forcedPhase(["EVLAT_PHASE": "busy"]),
                     "not a phase name; the menu stays in charge")
        XCTAssertEqual(AppController.forcedPhase(["EVLAT_PHASE": " Working "]), .working)
    }

    /// The candidates separate on **what they do**, which is the requirement
    /// (`phase-2.md`: the axis must not be a parameter tweak). Two candidates
    /// that drove the same channels by different amounts would be one candidate
    /// asked twice.
    func testTheCandidatesSeparateOnDifferentChannels() {
        func channels(_ candidate: MascotWorking) -> (aim: Bool, body: Bool) {
            let rest = MascotPose.resting(for: .working, working: candidate)
            let steps = candidate.clip.steps
            return (steps.contains { $0.pose.yaw != rest.yaw || $0.pose.pitch != rest.pitch },
                    steps.contains { $0.pose.scaleY != rest.scaleY })
        }
        XCTAssertEqual(channels(.breath).aim, false, "breath keeps its aim; the body carries it")
        XCTAssertEqual(channels(.breath).body, true)
        XCTAssertEqual(channels(.glance).aim, true, "glance is the one that looks away")
        XCTAssertEqual(channels(.glance).body, false, "glance holds the body still")
        XCTAssertEqual(channels(.busy).aim, true, "busy is the composite")
        XCTAssertEqual(channels(.busy).body, true)

        // And the mixes are three different answers, not one value jittered.
        let mixes = MascotWorking.allCases.map(\.gazeMix)
        XCTAssertEqual(Set(mixes).count, MascotWorking.allCases.count)
        for a in MascotWorking.allCases {
            for b in MascotWorking.allCases where a != b {
                XCTAssertGreaterThan(abs(a.gazeMix - b.gazeMix), 0.1,
                                     "\(a.rawValue) vs \(b.rawValue): a tweak, not an axis")
            }
        }
    }

    /// **Every candidate must be shippable.** The user picks by eye, and a
    /// candidate that broke the phase's contract would be a choice that cannot
    /// be taken — so the ordering `phase-1` pinned holds for all three, whichever
    /// one the environment selects.
    func testEveryCandidateKeepsTheGazeOrdering() {
        for candidate in MascotWorking.allCases {
            let mix = MascotPose.resting(for: .working, working: candidate).gazeMix
            XCTAssertEqual(mix, candidate.gazeMix)
            XCTAssertLessThan(mix, MascotPose.resting(for: .idle).gazeMix,
                              "\(candidate.rawValue): working has to hold the cursor more loosely")
            XCTAssertGreaterThan(mix, 0,
                                 "\(candidate.rawValue): a face that never follows is not a mix")
        }
    }

    /// The curve variant is a swap of one line, on the step a phase change
    /// travels through — so both answers to Karar 2 can be watched on the same
    /// candidate without touching anything else.
    func testTheCurveVariantSwapsTheTransitionAndNothingElse() {
        XCTAssertNotEqual(MascotCurve.spring.animation, MascotCurve.ease.animation)
        XCTAssertEqual(MascotCurve.spring.animation, .spring(response: 0.38, dampingFraction: 0.72),
                       "the spring is 001's, unchanged")
        // The shudder is a transient, not a transition: it keeps its own keys
        // whichever curve is in force.
        XCTAssertEqual(MascotShake.shake(for: .failed).keys.count, 4)
    }

    // MARK: - The measurement instrument (`plan.md` → Yaklaşım 6)

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
        XCTAssertEqual(clip.dutyCycle, 0.1, accuracy: 1e-9)
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
        XCTAssertEqual(clip.dutyCycle, 0, accuracy: 1e-9)
    }

    /// The in-clip leg runs on a variant with the waiting taken out: the same
    /// motion, on the same curves, played end to end. Without it the 90 s window
    /// measures *cost × duty cycle* and stretching the window buys any number
    /// you like.
    func testTheContinuousVariantIsTheSameMotionWithNothingBetween() {
        for candidate in MascotWorking.allCases {
            let clip = MascotClip.clip(for: .working, working: candidate, pacing: .normal)
            let burst = MascotClip.clip(for: .working, working: candidate, pacing: .continuous)
            // Every pose the clip actually travels to is still there, in order.
            // Only the standing still is gone — including step 0, which re-enters
            // the pose the last step already returned to and so draws nothing.
            var previous = clip.steps.last!.pose
            var travelled: [MascotPose] = []
            for step in clip.steps where step.pose != previous {
                travelled.append(step.pose)
                previous = step.pose
            }
            XCTAssertEqual(burst.steps.map(\.pose), travelled,
                           "\(candidate.rawValue): the variant must show the same motion")
            XCTAssertTrue(burst.steps.allSatisfy { $0.hold == $0.motion },
                          "\(candidate.rawValue): a step that waits is not in-clip time")
            XCTAssertEqual(burst.dutyCycle, 1.0, accuracy: 1e-9,
                           "\(candidate.rawValue): the in-clip leg has to be all clip")
            XCTAssertLessThan(burst.cycle, clip.cycle,
                              "\(candidate.rawValue): the waiting is what was removed")
            XCTAssertEqual(burst.movingTime, clip.movingTime, accuracy: 1e-9,
                           "\(candidate.rawValue): the same motion, not less of it")
            XCTAssertTrue(burst.loops, "\(candidate.rawValue): it has to keep running to be read")
        }
    }

    /// The expected average each candidate's 90 s window should land near:
    /// in-clip cost × duty cycle. The numbers live in `phase-2`'s notes; what is
    /// pinned here is that the arithmetic is available at all, because a table
    /// of three single numbers is the thing `plan.md` → Yaklaşım 6 forbids.
    func testEveryCandidatePublishesItsOwnDutyCycle() {
        let cycles = MascotWorking.allCases.map {
            MascotClip.clip(for: .working, working: $0, pacing: .normal).dutyCycle
        }
        for (candidate, duty) in zip(MascotWorking.allCases, cycles) {
            XCTAssertGreaterThan(duty, 0, "\(candidate.rawValue)")
            XCTAssertLessThanOrEqual(duty, MascotClipTests.maxDutyCycle, "\(candidate.rawValue)")
        }
    }
}
