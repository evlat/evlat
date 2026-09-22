import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// The clip table. Motion used to live inside the view as two `asyncAfter`
/// chains and a coin flip, which is why none of it was testable; the point of
/// `MascotClip` being plain data is that these claims can be held.
final class MascotClipTests: XCTestCase {
    func testEveryPhaseHasAClip() {
        for phase in Phase.allCases {
            let clip = MascotClip.clip(for: phase)
            XCTAssertFalse(clip.steps.isEmpty, "\(phase): a phase with no steps never moves")
        }
    }

    /// Entering a clip is entering the phase, so the first step is the phase's
    /// resting pose on the shared transition spring. Two `.animation` modifiers
    /// are in play on a phase change; this makes it not matter which one wins.
    func testEveryClipStartsAtRestOnTheTransitionSpring() {
        for phase in Phase.allCases {
            let first = MascotClip.clip(for: phase).steps[0]
            XCTAssertEqual(first.pose, MascotPose.resting(for: phase), "\(phase)")
            XCTAssertEqual(first.curve, MascotPose.transition, "\(phase)")
        }
    }

    /// Every hold is positive: a zero hold would make the walk a busy loop
    /// scheduling itself at the run loop's speed.
    func testEveryStepHoldsForARealTime() {
        for phase in Phase.allCases {
            for (i, step) in MascotClip.clip(for: phase).steps.enumerated() {
                XCTAssertGreaterThan(step.hold, 0, "\(phase) step \(i)")
            }
        }
    }

    /// **Karar 3a: clips burst, they do not run continuously.** A continuous
    /// SwiftUI animation was measured at ~7% CPU on this machine whatever the
    /// technique, against 1.60% idle — so a loop has to be mostly waiting. The
    /// old behaviour was one burst per 4 s beat; a clip that loops must not
    /// come round faster than that on average.
    func testLoopingClipsSpendMostOfTheirTimeWaiting() {
        for phase in Phase.allCases {
            let clip = MascotClip.clip(for: phase)
            guard clip.loops else { continue }
            let rest = MascotPose.resting(for: phase)
            let total = clip.steps.reduce(0) { $0 + $1.hold }
            let bursts = Double(clip.steps.filter { $0.pose != rest }.count)
            XCTAssertGreaterThan(bursts, 0, "\(phase): a clip that never leaves rest is not a clip")
            XCTAssertGreaterThanOrEqual(total / bursts, 4.0,
                                        "\(phase): a burst every \(total / bursts) s is faster than the 4 s beat")
        }
    }

    /// **The clip owns the channels it drives, and only those.** A clip that
    /// silently moved a channel it was not written to move would put a second
    /// writer back on it — the arrangement `003` exists to end. Today's clips
    /// drive eye opening and scale; tilt, squint and aim stay where
    /// `resting(for:)` left them for the clip's whole length.
    func testUndrivenChannelsStayAtRest() {
        for phase in Phase.allCases {
            let rest = MascotPose.resting(for: phase)
            for (i, step) in MascotClip.clip(for: phase).steps.enumerated() {
                XCTAssertEqual(step.pose.tilt, rest.tilt, "\(phase) step \(i): tilt")
                XCTAssertEqual(step.pose.eyeSquint, rest.eyeSquint, "\(phase) step \(i): squint")
                XCTAssertEqual(step.pose.yaw, rest.yaw, "\(phase) step \(i): yaw")
                XCTAssertEqual(step.pose.pitch, rest.pitch, "\(phase) step \(i): pitch")
                XCTAssertEqual(step.pose.gazeMix, rest.gazeMix, "\(phase) step \(i): gazeMix")
            }
        }
    }

    /// The blink is the old `lidClosed` flag, moved onto the channel that owns
    /// eye height: some step shuts the eyes and the clip opens them again.
    func testTheClipBlinksAndOpensAgain() {
        for phase in Phase.allCases {
            let clip = MascotClip.clip(for: phase)
            let rest = MascotPose.resting(for: phase)
            XCTAssertTrue(clip.steps.contains { $0.pose.eyeOpen < rest.eyeOpen * 0.5 },
                          "\(phase): nothing in this clip closes the eyes")
            XCTAssertEqual(clip.steps.last?.pose.eyeOpen, rest.eyeOpen,
                           "\(phase): a clip must not end mid-blink")
        }
    }

    /// The breath is the old `scaleEffect(inhale ? 1.02 : 1.0)`, on the channel
    /// the pose already owned. Both axes together — a breath, not a squash.
    func testTheClipBreathesOnBothAxes() {
        for phase in Phase.allCases {
            let rest = MascotPose.resting(for: phase)
            guard let inhale = MascotClip.clip(for: phase).steps
                .first(where: { $0.pose.scaleY > rest.scaleY }) else {
                XCTFail("\(phase): nothing in this clip breathes")
                continue
            }
            XCTAssertEqual(inhale.pose.scaleX / rest.scaleX,
                           inhale.pose.scaleY / rest.scaleY,
                           accuracy: 1e-9, "\(phase): the breath must not squash")
        }
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
