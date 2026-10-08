import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// **The character contract**, held for every character Evlat ships and for
/// the test characters that use what the shipped ones do not yet.
///
/// A character is free in how it looks and moves; what it is not free in is
/// below: that its rig names only what it declared, that its clips burst
/// rather than run (the CPU budget the measured clips set), and that the five
/// phases read apart — `waiting` above all, which is the product. These
/// are the checks v0 ran on every pet it loaded (`ShippedPetTests`), applied
/// to the list in `MascotCharacters` instead of to files.
final class MascotCharacterContractTests: XCTestCase {
    private var characters: [MascotCharacter] { MascotCharacters.all + [MascotTestCharacters.lantern] }

    /// Every clip a character can play: its five phases and its own motions.
    private func clips(of character: MascotCharacter) -> [(name: String, clip: MascotClip)] {
        Phase.allCases.map { ($0.rawValue, character.clip(for: $0, pacing: .normal)) }
            + character.motions.sorted { $0.key < $1.key }.map { ("motion \($0.key)", $0.value) }
    }

    func testIdsAreUniqueAndTheDefaultIsListed() {
        let ids = characters.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(MascotCharacters.all.contains(MascotCharacters.default))
    }

    /// SwiftUI tells parts apart by name: two parts with one name would
    /// animate as one.
    func testEveryPartNameIsUniqueWithinItsRig() {
        for character in characters {
            let names = character.rig.parts.map(\.name)
            XCTAssertEqual(Set(names).count, names.count, "\(character.id): \(names)")
        }
    }

    /// A binding on a name nobody declared drives nothing, silently — the
    /// typo v0's loader refused. And a binding whose input has no width
    /// divides by zero.
    func testEveryBindingNamesAKnownControlOverARealRange() {
        for character in characters {
            let known = Set(MascotControl.standard).union(character.rig.controls.keys)
            for (control, range) in character.rig.controls {
                XCTAssertFalse(MascotControl.standard.contains(control),
                               "\(character.id): \(control) is standard, not its own")
                XCTAssertLessThan(range.lower, range.upper, "\(character.id): \(control)")
                XCTAssertTrue(range.contains(range.rest), "\(character.id): \(control) rests outside its range")
            }
            for part in character.rig.parts {
                for binding in part.bindings {
                    XCTAssertTrue(known.contains(binding.control),
                                  "\(character.id).\(part.name): \(binding.control) is not declared")
                    XCTAssertNotEqual(binding.input.start, binding.input.end,
                                      "\(character.id).\(part.name): \(binding.control)")
                }
            }
        }
    }

    /// A clip sets only the controls the rig declared, and only inside their
    /// ranges — Evlat's clips set none of them.
    func testEveryClipSetsOnlyDeclaredControlsWithinTheirRanges() {
        for character in characters {
            for (name, clip) in clips(of: character) {
                for (i, step) in clip.steps.enumerated() {
                    for (control, value) in step.pose.own {
                        let range = character.rig.controls[control]
                        XCTAssertNotNil(range, "\(character.id) \(name) step \(i): \(control) is not declared")
                        XCTAssertTrue(range?.contains(value) ?? false,
                                      "\(character.id) \(name) step \(i): \(control) = \(value)")
                    }
                }
            }
        }
        for phase in Phase.allCases {
            XCTAssertTrue(MascotClip.clip(for: phase, pacing: .normal).steps.allSatisfy { $0.pose.own.isEmpty },
                          "\(phase): Evlat's clips know no character's own controls")
        }
    }

    /// The same rule as Evlat's clips (`MascotClipTests`), for every clip a
    /// character plays: a zero hold is a busy loop, and a step still moving
    /// when the next starts reads as drift.
    func testEveryStepHoldsForARealTimeAndLandsWithinIt() {
        for character in characters {
            for (name, clip) in clips(of: character) {
                XCTAssertFalse(clip.steps.isEmpty, "\(character.id) \(name): never moves")
                for (i, step) in clip.steps.enumerated() {
                    XCTAssertGreaterThan(step.hold, 0, "\(character.id) \(name) step \(i)")
                    XCTAssertGreaterThan(step.motion, 0, "\(character.id) \(name) step \(i)")
                    XCTAssertLessThanOrEqual(step.motion, step.hold + 1e-9, "\(character.id) \(name) step \(i)")
                }
            }
        }
    }

    /// Every phase change feels the same, whoever is drawn: it lands on the
    /// shared spring. And a phase's clip ends on the pose it began with — the
    /// pose the asleep mascot draws, and the one a loop wraps back to — so
    /// neither the loop's seam nor falling asleep is a jump.
    func testEveryPhaseEntersOnTheSpringAndEndsWhereItRests() {
        for character in characters {
            for phase in Phase.allCases {
                let clip = character.clip(for: phase, pacing: .normal)
                XCTAssertEqual(clip.steps.first?.curve, MascotPose.transition, "\(character.id) \(phase)")
                XCTAssertEqual(clip.steps.last?.pose, clip.steps.first?.pose,
                               "\(character.id) \(phase): it does not end where it rests")
                XCTAssertEqual(character.resting(for: phase), clip.steps.first?.pose)
            }
        }
    }

    /// **Clips burst.** A phase a character sits in for hours keeps a sparse
    /// rhythm, under the same ceiling Evlat's own clips are held to — the one
    /// derived from measurement (`MascotClipTests.maxDutyCycle`).
    func testLoopingPhasesStayInsideTheDutyCycleBudget() {
        for character in characters {
            for phase in Phase.allCases {
                let clip = character.clip(for: phase, pacing: .normal)
                guard clip.loops else { continue }
                XCTAssertGreaterThan(clip.movingTime, 0, "\(character.id) \(phase): a loop that never moves")
                XCTAssertLessThanOrEqual(clip.dutyCycle ?? 1, MascotClipTests.maxDutyCycle,
                                         "\(character.id) \(phase)")
            }
        }
    }

    /// **The five phases read apart.** No two rest at the same pose, and
    /// `waiting` arrives moving: however a character says it is waiting,
    /// it must say it.
    func testTheFivePhasesReadApart() {
        for character in characters {
            let rests = Phase.allCases.map { character.resting(for: $0) }
            for (a, first) in rests.enumerated() {
                for (b, second) in rests.enumerated() where b > a {
                    XCTAssertNotEqual(first, second,
                                      "\(character.id): \(Phase.allCases[a]) and \(Phase.allCases[b]) rest alike")
                }
            }
            XCTAssertGreaterThan(character.clip(for: .waiting, pacing: .normal).movingTime, 0,
                                 "\(character.id): waiting has to arrive moving")
        }
    }

    /// A motion is a gesture on top of a phase: it plays once and hands the
    /// phase back. One that looped would never hand it back.
    func testMotionsPlayOnce() {
        for character in characters {
            for (name, motion) in character.motions {
                XCTAssertFalse(motion.loops, "\(character.id) motion \(name)")
            }
        }
    }

    /// A rule plays the character's own gestures, at real times, with real
    /// weights. A gesture name the character does not have would be a rule
    /// that silently never plays.
    func testEveryRuleNamesItsOwnGesturesAtRealTimes() {
        for character in characters {
            for (i, rule) in character.behavior.rules.enumerated() {
                let at = "\(character.id) rule \(i)"
                XCTAssertFalse(rule.play.isEmpty, at)
                for pick in rule.play {
                    XCTAssertNotNil(character.motions[pick.motion], "\(at): no gesture \(pick.motion)")
                    XCTAssertGreaterThan(pick.weight, 0, at)
                }
                XCTAssertGreaterThanOrEqual(rule.after, 0, at)
                if let every = rule.every { XCTAssertGreaterThan(every, 0, at) }
                for condition in rule.when {
                    XCTAssertLessThanOrEqual(condition.atLeast, condition.atMost, at)
                }
            }
        }
    }

    /// **A rule that repeats pays for its gestures.** Played every `every`
    /// seconds on top of its phase, its longest gesture adds that share of
    /// time in motion to the phase's own: together they stay under the same
    /// ceiling the clips are held to.
    func testRepeatingRulesStayInsideTheDutyCycleBudget() {
        for character in characters {
            for (i, rule) in character.behavior.rules.enumerated() {
                guard let every = rule.every else { continue }
                let longest = rule.play.compactMap { character.motions[$0.motion]?.movingTime }.max() ?? 0
                let phase = character.clip(for: rule.phase, pacing: .normal).dutyCycle ?? 0
                XCTAssertLessThanOrEqual(phase + longest / every, MascotClipTests.maxDutyCycle,
                                         "\(character.id) rule \(i)")
            }
        }
    }

    /// **A character without rules is never asked**, so it draws exactly as
    /// before rules existed: whatever the phase, the time and the sessions,
    /// its behavior plays nothing and asks to be woken for nothing.
    func testACharacterWithoutRulesDecidesNothing() {
        for character in characters where character.behavior.isEmpty {
            for phase in Phase.allCases {
                for seconds in [0.0, 1, 59, 60, 600, 86_400] {
                    for sessions in [MascotContext.Sessions(), .init(waiting: 3, working: 2, news: 4)] {
                        let decision = character.behavior.decide(
                            MascotContext(phase: phase, secondsInPhase: seconds, sessions: sessions),
                            memory: .init(), random: { 0.5 })
                        XCTAssertNil(decision.motion, "\(character.id) \(phase)")
                        XCTAssertNil(decision.wake, "\(character.id) \(phase)")
                    }
                }
            }
        }
        XCTAssertTrue(MascotCharacters.default.behavior.isEmpty, "the cube has no rules")
    }

    /// A phase the character plays its own way is its clip; the measurement
    /// variant of it is that clip with the waiting taken out, as Evlat's are.
    func testAnOwnPhaseReplacesEvlatsClip() {
        let lantern = MascotTestCharacters.lantern
        XCTAssertEqual(lantern.clip(for: .waiting, pacing: .normal), MascotTestCharacters.waiting)
        XCTAssertEqual(lantern.clip(for: .waiting, pacing: .continuous), MascotTestCharacters.waiting.continuous)
        XCTAssertEqual(lantern.clip(for: .idle, pacing: .normal), MascotClip.clip(for: .idle, pacing: .normal),
                       "a phase it does not write plays Evlat's clip")
    }

    /// An own control a pose does not set rests where the rig says; one it
    /// sets is read; a name the rig never declared drives nothing.
    func testAnOwnControlRestsUntilAClipSetsIt() {
        let rig = MascotTestCharacters.lantern.rig
        let glow = MascotTestCharacters.glow
        XCTAssertEqual(rig.value(of: glow, in: MascotPose()), 0.3)
        XCTAssertEqual(rig.value(of: glow, in: MascotPose().setting(glow, to: 0.9)), 0.9)
        XCTAssertNil(rig.value(of: MascotControl("nobody"), in: MascotPose()))
        XCTAssertEqual(rig.value(of: .eyeOpen, in: MascotPose(eyeOpen: 0.4)), 0.4)
    }

    /// Every character draws something in every phase at the bar's size.
    @MainActor
    func testEveryCharacterDrawsInEveryPhase() throws {
        for character in characters {
            for phase in Phase.allCases {
                let view = MascotBody(pose: character.resting(for: phase), size: AppController.mascotSize,
                                      rig: character.rig)
                    .frame(width: AppController.mascotSize, height: AppController.mascotSize)
                let image = try XCTUnwrap(ImageRenderer(content: view).cgImage, "\(character.id) \(phase)")
                XCTAssertGreaterThan(Self.inkedPixels(image), 0, "\(character.id) \(phase): nothing drawn")
            }
        }
    }

    private static func inkedPixels(_ image: CGImage) -> Int {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 0 }.count
    }
}
