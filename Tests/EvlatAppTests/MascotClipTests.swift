import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The clip table. Motion used to live inside the view as two `asyncAfter`
/// chains and a coin flip, which is why none of it was testable; the point of
/// `MascotClip` being plain data is that these claims can be held.
final class MascotClipTests: XCTestCase {
    /// Every clip in the table, with the resting pose it was built on and a
    /// name for the failure message. The pacing is named explicitly so a run
    /// with `EVLAT_MASCOT_PACING` set still tests the clips as they ship.
    private func allClips() -> [(name: String, rest: MascotPose, clip: MascotClip)] {
        Phase.allCases.map {
            ($0.rawValue, MascotPose.resting(for: $0), MascotClip.clip(for: $0, pacing: .normal))
        }
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
    /// of the three `working` candidates measured in `003/phase-2` read **2.11%
    /// over 90 s at a duty cycle of 0.299**; the same shape stretched to this
    /// ceiling would cost 2.11 × 0.35 / 0.299 ≈ **2.47%**, against the **3.77%**
    /// R5.2 allows while a clip is running. The clip that shipped reads 1.84%
    /// at 0.215, and the idle foot 0.04%.
    ///
    /// It is a guard, not a proof: cost also tracks how often the step index
    /// changes, and the candidates' in-clip readings (5.16% / 9.16% / 7.68%)
    /// differed by more than their duty cycles did. The gate is the measured
    /// 90 s leg, which `phase-4` re-runs against the threshold; this line is
    /// what stops a clip from drifting there between measurements.
    func testLoopingClipsStayInsideTheDutyCycleBudget() {
        for (name, rest, clip) in allClips() {
            guard clip.loops else { continue }
            XCTAssertGreaterThan(clip.movingTime, 0,
                                 "\(name): a clip that never leaves rest is not a clip")
            let duty = clip.dutyCycle ?? 1
            XCTAssertLessThanOrEqual(duty, MascotClipTests.maxDutyCycle,
                                     "\(name): \(duty) of the cycle is motion")
            // A clip whose steps all sit at rest would pass the line above with
            // a duty cycle of zero; this is the same claim from the other side.
            XCTAssertTrue(clip.steps.contains { $0.pose != rest },
                          "\(name): nothing in this clip leaves the resting pose")
        }
    }

    static let maxDutyCycle = 0.35

    /// `idle`'s breath is a breath, not a squash: both axes grow together.
    /// The area test cannot see this — a bob keeps the area by construction —
    /// and a squashing inhale would read as `working`'s bob on an idle face.
    func testTheIdleBreathScalesBothAxesTogether() {
        let rest = MascotPose.resting(for: .idle)
        let clip = MascotClip.clip(for: .idle, pacing: .normal)
        guard let inhale = clip.steps.first(where: { $0.pose.scaleY > rest.scaleY }) else {
            return XCTFail("idle: nothing in this clip breathes")
        }
        XCTAssertEqual(inhale.pose.scaleX / rest.scaleX, inhale.pose.scaleY / rest.scaleY,
                       accuracy: 1e-9, "the idle breath must not squash")
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
    /// clip blinks — a face that never blinks reads as dead however well it is
    /// moving otherwise.
    func testEveryClipBlinksAndOpensAgain() {
        for (name, rest, clip) in allClips() {
            let open = rest.eyeOpen
            XCTAssertTrue(clip.steps.contains { $0.pose.eyeOpen < open * 0.5 },
                          "\(name): nothing in this clip closes the eyes")
            XCTAssertEqual(clip.steps.last?.pose.eyeOpen, open,
                           "\(name): a clip must not end mid-blink")
        }
    }

    /// The body does not change how much room it takes up — beyond a breath.
    ///
    /// `phase-1` said this as "a breath scales both axes equally", which is true
    /// of the idle breath and false of a working body that **bobs** — stretching
    /// up while narrowing is the difference between drawing breath and growing.
    /// The rule underneath both is that the area is left alone: a mascot that
    /// silently grew would shoulder the bar's layout around it.
    ///
    /// Two steps grow on purpose, `idle`'s breath and `waiting`'s swell, both
    /// by the same 1.02 per axis — about 4% of area. The bound is that, stated
    /// relative to the phase's own rest rather than as an absolute slack that
    /// happened to fit: 5%, and nothing else in the table comes near it.
    func testTheBodyKeepsItsAreaWhileItMoves() {
        for (name, rest, clip) in allClips() {
            let area = rest.scaleX * rest.scaleY
            for (i, step) in clip.steps.enumerated() {
                let ratio = step.pose.scaleX * step.pose.scaleY / area
                XCTAssertEqual(ratio, 1, accuracy: 0.05,
                               "\(name) step \(i): the body changed size")
            }
        }
    }

    /// **No step ever shuts the eyes all the way.** A blink goes down to 8% of
    /// the resting opening and no further — zero would draw a flat line the
    /// view has to rescue, and a mascot that holds a closed-eyed pose reads as
    /// asleep, which is what the *absence* of a clip already means. Checked on
    /// the measurement variant too, since that is the same motion.
    func testNoStepShutsTheEyesCompletely() {
        for phase in Phase.allCases {
            for pacing in MascotPacing.allCases {
                for (i, step) in MascotClip.clip(for: phase, pacing: pacing).steps.enumerated() {
                    XCTAssertGreaterThan(step.pose.eyeOpen, 0,
                                         "\(phase) \(pacing) step \(i): the eyes are shut")
                }
            }
        }
    }

    /// **`waiting` and `review` play once and hold** (`003/phase-3`). They are
    /// news, not states: the arrival is the signal, and a one-shot clip that
    /// has played out schedules nothing more, so however long you take to
    /// answer costs no frames. The pose they hold is the phase's resting pose —
    /// the same face the sleeping branch draws for that phase.
    func testWaitingAndReviewPlayOnceAndHoldTheirLastPose() {
        for phase in [Phase.waiting, .review] {
            let clip = MascotClip.clip(for: phase, pacing: .normal)
            XCTAssertFalse(clip.loops, "\(phase) must not loop")
            XCTAssertEqual(clip.steps.last?.pose, MascotPose.resting(for: phase),
                           "\(phase): it holds the resting pose")
            XCTAssertNil(clip.step(after: clip.steps.count - 1),
                         "\(phase): a played-out clip schedules nothing")
            XCTAssertNil(clip.dutyCycle, "\(phase): a clip that stops has no duty cycle")
        }
        for phase in [Phase.idle, .working, .failed] {
            let clip = MascotClip.clip(for: phase, pacing: .normal)
            XCTAssertTrue(clip.loops, "\(phase) is a state you sit in; it keeps a rhythm")
            XCTAssertEqual(clip.step(after: clip.steps.count - 1), 0, "\(phase)")
        }
    }

    /// The walk visits every step in order, once per pass.
    func testTheWalkVisitsEveryStepInOrder() {
        for phase in Phase.allCases {
            let clip = MascotClip.clip(for: phase, pacing: .normal)
            for i in 0..<(clip.steps.count - 1) {
                XCTAssertEqual(clip.step(after: i), i + 1, "\(phase)")
            }
        }
    }

    /// **The channels a clip does not drive stay at rest — one writer per
    /// channel** (R4, Karar 8).
    ///
    /// The table below is each clip's declaration: a clip that starts writing
    /// a channel it is not listed for is a second writer on something another
    /// part of the face owns, and the list has to change on purpose for it to
    /// pass. Three channels are never on it, for any clip:
    ///
    /// - **tilt and squint** say *which* phase this is, not what it is doing
    ///   inside it; they belong to `resting(for:)`. `review`'s tilt arrives on
    ///   step 0's spring, and its gesture is a nod instead.
    /// - **`gazeMix`** is a phase constant (Karar 4). Animating it per step
    ///   would make the eyes drift between following and not following — a
    ///   second gaze authority, the exact arrangement `003` exists to end.
    func testEachClipDrivesOnlyItsOwnChannels() {
        let driven: [Phase: Set<Channel>] = [
            .idle: [.eyeOpen, .scale],
            .working: [.eyeOpen, .scale, .aim],
            .waiting: [.eyeOpen, .scale],
            .review: [.eyeOpen, .scale, .aim],
            .failed: [.eyeOpen, .scale, .aim]
        ]
        let tableOnly: Set<Channel> = [.tilt, .squint, .gazeMix]
        for phase in Phase.allCases {
            let rest = MascotPose.resting(for: phase)
            let allowed = driven[phase] ?? []
            XCTAssertTrue(allowed.isDisjoint(with: tableOnly),
                          "\(phase): tilt, squint and gazeMix belong to the table")
            var used: Set<Channel> = []
            for (i, step) in MascotClip.clip(for: phase, pacing: .normal).steps.enumerated() {
                let touched = Channel.touched(by: step.pose, from: rest)
                XCTAssertTrue(touched.isSubset(of: allowed),
                              "\(phase) step \(i) writes \(touched.subtracting(allowed))")
                used.formUnion(touched)
            }
            // The declaration is not allowed to go stale in the other
            // direction either: a channel listed but never driven is a claim
            // about the face nobody is keeping.
            XCTAssertEqual(used, allowed, "\(phase): the table says more than the clip does")
        }
    }

    /// **The five phases move differently** (R1): no two clips are the same
    /// motion on a different face. Comparing poses would pass trivially, since
    /// every clip is built on its own resting pose; what is compared is the
    /// motion itself — each step as a change from rest, how long it holds,
    /// and whether the clip loops.
    func testNoTwoPhasesMoveTheSame() {
        let phases = Phase.allCases
        for (a, first) in phases.enumerated() {
            for second in phases[(a + 1)...] {
                XCTAssertNotEqual(Motion(first), Motion(second),
                                  "\(first) and \(second) are the same motion")
            }
        }
    }
}

/// A pose channel, as the clip-ownership test counts them. Scale is one
/// channel with two fields because squash and stretch move them together.
private enum Channel: Hashable {
    case aim, eyeOpen, squint, scale, tilt, gazeMix

    static func touched(by pose: MascotPose, from rest: MascotPose) -> Set<Channel> {
        var out: Set<Channel> = []
        if pose.yaw != rest.yaw || pose.pitch != rest.pitch { out.insert(.aim) }
        if pose.eyeOpen != rest.eyeOpen { out.insert(.eyeOpen) }
        if pose.eyeSquint != rest.eyeSquint { out.insert(.squint) }
        if pose.scaleX != rest.scaleX || pose.scaleY != rest.scaleY { out.insert(.scale) }
        if pose.tilt != rest.tilt { out.insert(.tilt) }
        if pose.gazeMix != rest.gazeMix { out.insert(.gazeMix) }
        return out
    }
}

/// A clip with its face taken out: every step as a change relative to the
/// phase's resting pose, plus timing and looping. Ratios for the channels that
/// multiply, differences for aim.
private struct Motion: Equatable {
    struct Beat: Equatable {
        var yaw, pitch, eyeOpen, scaleX, scaleY, hold: Double
    }
    var beats: [Beat]
    var loops: Bool

    init(_ phase: Phase) {
        let rest = MascotPose.resting(for: phase)
        let clip = MascotClip.clip(for: phase, pacing: .normal)
        beats = clip.steps.map {
            Beat(yaw: $0.pose.yaw - rest.yaw, pitch: $0.pose.pitch - rest.pitch,
                 eyeOpen: $0.pose.eyeOpen / rest.eyeOpen,
                 scaleX: $0.pose.scaleX / rest.scaleX, scaleY: $0.pose.scaleY / rest.scaleY,
                 hold: $0.hold)
        }
        loops = clip.loops
    }
}

/// The `failed` shudder. **This is the first test it has ever had:** before
/// `003`, `grep -rn "shake\|keyframe" Tests/` returned nothing, so the promise
/// that the clip layer preserves today's behaviour had no guard.
final class MascotShakeTests: XCTestCase {
    /// The amplitude is what makes the shudder a shudder: the same
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
