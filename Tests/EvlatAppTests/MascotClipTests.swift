import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The clip table. Motion used to live inside the view as two `asyncAfter`
/// chains and a coin flip, which is why none of it was testable; the point of
/// `MascotClip` being plain data is that these claims can be held.
///
/// Every test walks **every phase against every `working` candidate**
/// (`003/phase-2`). The candidates are selected by an environment variable, so
/// testing only the selected one would leave two thirds of the table uncovered
/// on any given run — and the whole point of the gate is that all three are
/// shippable and the user picks.
final class MascotClipTests: XCTestCase {
    /// Every clip in the table, with the resting pose it was built on and a
    /// name for the failure message.
    private func allClips() -> [(name: String, rest: MascotPose, clip: MascotClip)] {
        var clips: [(String, MascotPose, MascotClip)] = []
        for phase in Phase.allCases {
            for candidate in MascotWorking.allCases {
                // Only `working` differs by candidate; taking the others once
                // keeps the failure messages honest about what is being tested.
                guard phase == .working || candidate == MascotWorking.allCases[0] else { continue }
                let name = phase == .working ? "working/\(candidate.rawValue)" : phase.rawValue
                clips.append((name,
                              MascotPose.resting(for: phase, working: candidate),
                              MascotClip.clip(for: phase, working: candidate, pacing: .normal)))
            }
        }
        return clips
    }

    func testEveryPhaseHasAClip() {
        for (name, _, clip) in allClips() {
            XCTAssertFalse(clip.steps.isEmpty, "\(name): a phase with no steps never moves")
        }
    }

    /// Entering a clip is entering the phase, so the first step is the phase's
    /// resting pose on the shared transition curve. Two `.animation` modifiers
    /// are in play on a phase change; this makes it not matter which one wins.
    func testEveryClipStartsAtRestOnTheTransitionCurve() {
        for (name, rest, clip) in allClips() {
            XCTAssertEqual(clip.steps[0].pose, rest, "\(name)")
            XCTAssertEqual(clip.steps[0].curve, MascotPose.transition, "\(name)")
        }
    }

    /// Every hold is positive: a zero hold would make the walk a busy loop
    /// scheduling itself at the run loop's speed. And no step moves for longer
    /// than it is held — a step whose curve outlasts its hold hands the next
    /// step a pose that is still travelling, which is how a clip starts reading
    /// as drift instead of motion.
    func testEveryStepHoldsForARealTimeAndLandsWithinIt() {
        for (name, _, clip) in allClips() {
            for (i, step) in clip.steps.enumerated() {
                XCTAssertGreaterThan(step.hold, 0, "\(name) step \(i)")
                XCTAssertGreaterThan(step.motion, 0, "\(name) step \(i): a step with no curve")
                XCTAssertLessThanOrEqual(step.motion, step.hold + 1e-9,
                                         "\(name) step \(i): still moving when the next one starts")
            }
        }
    }

    /// **Karar 3a: clips burst, they do not run continuously.**
    ///
    /// This replaces `phase-1`'s "a burst no more often than every 4 s". That
    /// rule was a proxy for the budget and it priced a 0.08 s eye flick the same
    /// as a 1.3 s breath, so it could only be satisfied by making `working` as
    /// slow as `idle` — which is R2 given up. What actually costs CPU is **time
    /// in motion**, and now that every step carries its own, the guard can be
    /// written in the currency the threshold is in.
    ///
    /// The ceiling is derived from measurement, not chosen. The most expensive
    /// candidate measured in `003/phase-2` reads **2.11% over 90 s at a duty
    /// cycle of 0.299**; the same shape stretched to this ceiling would cost
    /// 2.11 × 0.35 / 0.299 ≈ **2.47%**, against the **3.77%** R5.2 allows while
    /// a clip is running. The idle foot is untouched at 0.04%.
    ///
    /// It is a guard, not a proof: cost also tracks how often the step index
    /// changes, and the three candidates' in-clip readings (5.16% / 9.16% /
    /// 7.68%) differ by more than their duty cycles do. The gate is the measured
    /// 90 s leg, which `phase-4` re-runs against the threshold; this line is
    /// what stops a clip from drifting there between measurements.
    func testLoopingClipsStayInsideTheDutyCycleBudget() {
        for (name, rest, clip) in allClips() {
            guard clip.loops else { continue }
            XCTAssertGreaterThan(clip.movingTime, 0,
                                 "\(name): a clip that never leaves rest is not a clip")
            XCTAssertLessThanOrEqual(clip.dutyCycle, MascotClipTests.maxDutyCycle,
                                     "\(name): \(clip.dutyCycle) of the cycle is motion")
            // A clip whose steps all sit at rest would pass the line above with
            // a duty cycle of zero; this is the same claim from the other side.
            XCTAssertTrue(clip.steps.contains { $0.pose != rest },
                          "\(name): nothing in this clip leaves the resting pose")
        }
    }

    static let maxDutyCycle = 0.35

    /// **`gazeMix` is a phase constant, never animated.** Karar 4 put the mix on
    /// the pose so a phase could say how much of the cursor it wants; animating
    /// it per step would make the eyes drift between following and not
    /// following, which is a second gaze authority — the exact arrangement
    /// `003` exists to end. `wander` is explicitly out of scope (`plan.md` →
    /// Kapsam Dışı).
    func testGazeMixIsConstantThroughAClip() {
        for (name, rest, clip) in allClips() {
            for (i, step) in clip.steps.enumerated() {
                XCTAssertEqual(step.pose.gazeMix, rest.gazeMix,
                               "\(name) step \(i): the mix moved")
            }
        }
    }

    /// **The clip owns the channels it drives, and only those.**
    ///
    /// `phase-1` wrote this as "tilt, squint and aim stay at rest", which was a
    /// description of the only clip that existed then. Aim is now a channel
    /// clips legitimately drive — that is what `glance` and `busy` are — so what
    /// survives is the part that is a rule rather than a description: a clip
    /// never touches the head tilt or the squint, the two channels that say
    /// which phase this is rather than what it is doing inside it.
    func testClipsDoNotRewriteTheChannelsThatIdentifyThePhase() {
        for (name, rest, clip) in allClips() {
            for (i, step) in clip.steps.enumerated() {
                XCTAssertEqual(step.pose.tilt, rest.tilt, "\(name) step \(i): tilt")
                XCTAssertEqual(step.pose.eyeSquint, rest.eyeSquint,
                               "\(name) step \(i): squint")
            }
        }
    }

    /// A looping clip comes back to where it started. The seam of the loop is a
    /// cut like any other, and a clip that wrapped from a saccade or a held
    /// breath would jump there; a phase change out of it would also start from
    /// a pose no other phase knows about.
    func testALoopingClipEndsWhereItBegan() {
        for (name, rest, clip) in allClips() {
            guard clip.loops, let last = clip.steps.last else { continue }
            XCTAssertEqual(last.pose, rest,
                           "\(name): the loop's seam is a jump")
        }
    }

    /// The blink is the old `lidClosed` flag, moved onto the channel that owns
    /// eye height: some step shuts the eyes and the clip opens them again. Every
    /// candidate blinks — a face that never blinks reads as dead however well it
    /// is moving otherwise.
    func testEveryClipBlinksAndOpensAgain() {
        for (name, rest, clip) in allClips() {
            let open = rest.eyeOpen
            XCTAssertTrue(clip.steps.contains { $0.pose.eyeOpen < open * 0.5 },
                          "\(name): nothing in this clip closes the eyes")
            XCTAssertEqual(clip.steps.last?.pose.eyeOpen, open,
                           "\(name): a clip must not end mid-blink")
        }
    }

    /// The body does not change how much room it takes up.
    ///
    /// `phase-1` said this as "a breath scales both axes equally", which is true
    /// of the idle breath and false of a working body that **bobs** — stretching
    /// up while narrowing is the difference between drawing breath and growing.
    /// The rule underneath both is that the area is left alone: a mascot that
    /// silently grew would shoulder the bar's layout around it.
    func testTheBodyKeepsItsAreaWhileItMoves() {
        for (name, rest, clip) in allClips() {
            let area = rest.scaleX * rest.scaleY
            for (i, step) in clip.steps.enumerated() {
                XCTAssertEqual(step.pose.scaleX * step.pose.scaleY, area, accuracy: 0.05,
                               "\(name) step \(i): the body changed size")
            }
        }
    }

    /// Something in every clip moves the body or the eyes, and `idle`'s breath
    /// is still the breath `phase-1` shipped — untouched by this phase.
    func testTheIdleRhythmIsUnchanged() {
        let clip = MascotClip.clip(for: .idle, working: .breath, pacing: .normal)
        XCTAssertEqual(clip.steps.count, 9)
        XCTAssertEqual(clip.cycle, 18.8, accuracy: 1e-9, "the 18.8 s cycle `phase-1` measured")
        XCTAssertEqual(clip.movingTime, 3.0, accuracy: 1e-9, "~3.0 s of it in motion")
        // 16%: the number `phase-1` reached with pen and paper, now computed.
        XCTAssertEqual(clip.dutyCycle, 0.16, accuracy: 0.005)
        let rest = MascotPose.resting(for: .idle)
        guard let inhale = clip.steps.first(where: { $0.pose.scaleY > rest.scaleY }) else {
            return XCTFail("idle: nothing in this clip breathes")
        }
        XCTAssertEqual(inhale.pose.scaleX / rest.scaleX, inhale.pose.scaleY / rest.scaleY,
                       accuracy: 1e-9, "the idle breath must not squash")
    }
}

/// The `failed` shudder. **This is the first test it has ever had:** before
/// `003`, `grep -rn "shake\|keyframe" Tests/` returned nothing, so the promise
/// that the clip layer preserves today's behaviour had no guard.
final class MascotShakeTests: XCTestCase {
    /// The amplitude is what makes the shudder a shudder: the same four
    /// keyframes run on every phase change and stay flat everywhere else.
    func testOnlyFailedShakes() {
        for phase in Phase.allCases {
            let keys = MascotShake.shake(for: phase).keys
            if phase == .failed {
                XCTAssertTrue(keys.contains { $0.offset != 0 }, "failure has to be felt")
            } else {
                XCTAssertTrue(keys.allSatisfy { $0.offset == 0 }, "\(phase): must not twitch")
            }
        }
    }

    /// Four keys, always. The view unrolls them by index because SwiftUI's
    /// keyframe builder takes a fixed list, so a fifth key would be dropped on
    /// the floor rather than drawn.
    func testTheShudderIsFourKeys() {
        for phase in Phase.allCases {
            XCTAssertEqual(MascotShake.shake(for: phase).keys.count, 4, "\(phase)")
        }
    }

    /// One *damped* shudder, not a wobble: out, a full swing back through the
    /// centre line, then dying away to still. No swing is ever bigger than the
    /// one before it, and the shudder ends at zero — ending off-centre would
    /// leave the mascot standing beside itself.
    func testTheShudderIsDampedAndEndsAtRest() {
        let keys = MascotShake.shake(for: .failed).keys
        XCTAssertGreaterThan(keys[0].offset, 0)
        XCTAssertLessThan(keys[1].offset, 0, "it has to cross back over")
        for i in 1..<keys.count {
            XCTAssertLessThanOrEqual(abs(keys[i].offset), abs(keys[i - 1].offset),
                                     "swing \(i) is bigger than the one before it")
        }
        XCTAssertLessThan(abs(keys[2].offset), abs(keys[1].offset),
                          "after the swing back it has to die down")
        XCTAssertEqual(keys.last?.offset, 0, "the shudder ends still")
        XCTAssertTrue(keys.allSatisfy { $0.duration > 0 })
    }
}
