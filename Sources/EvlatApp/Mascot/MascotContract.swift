import Foundation
import EvlatCore

/// **The character contract**: what no character is free in, whoever wrote
/// it — Evlat's own, checked by `MascotCharacterContractTests` before anyone
/// sees them, and the ones found on disk (`MascotLibrary`), checked here as
/// they are read and left out of the picker when they break it.
///
/// A character is free in how it looks and moves. What it is not free in:
/// that its rig names only what it declared, that its clips burst rather
/// than run (the CPU budget the measured clips set), and that the five
/// phases read apart — `waiting` above all, which is the product. These are
/// the checks v0 ran on every pet it loaded (`ShippedPetTests`).
enum MascotContract {
    /// The share of a loop's cycle that may be motion.
    ///
    /// Derived from measurement, not chosen. The most expensive of the three
    /// `working` candidates measured read **2.11% over 90 s at a duty cycle
    /// of 0.299**; the same shape stretched to this ceiling would cost
    /// 2.11 × 0.35 / 0.299 ≈ **2.47%**, against the **3.77%** threshold while
    /// a clip is running. The clip that shipped reads 1.84% at 0.215, and the
    /// idle foot 0.04%.
    ///
    /// It is a guard, not a proof: cost also tracks how often the step index
    /// changes, and the candidates' in-clip readings (5.16% / 9.16% / 7.68%)
    /// differed by more than their duty cycles did. The gate is the measured
    /// 90 s leg, re-run against the threshold; this line is what stops a clip
    /// from drifting there between measurements.
    static let maxDutyCycle = 0.35

    /// Every rule the character breaks, one line each, naming where; empty
    /// when it keeps them all.
    static func violations(of character: MascotCharacter) -> [String] {
        let id = character.id
        var out: [String] = []
        func check(_ holds: Bool, _ line: @autoclosure () -> String) {
            if !holds { out.append("\(id): " + line()) }
        }
        let rig = character.rig
        let clips = Phase.allCases.map { ($0.rawValue, character.clip(for: $0, pacing: .normal)) }
            + character.motions.sorted { $0.key < $1.key }.map { ("motion \($0.key)", $0.value) }

        check(!id.isEmpty, "no id")

        // SwiftUI tells parts apart by name: two parts with one name would
        // animate as one.
        let names = rig.parts.map(\.name)
        check(Set(names).count == names.count, "two parts share a name")

        // A binding on a name nobody declared drives nothing, silently — the
        // typo v0's loader refused. A binding whose input has no width
        // divides by zero.
        let known = Set(MascotControl.standard).union(rig.controls.keys)
        for (control, range) in rig.controls.sorted(by: { $0.key.name < $1.key.name }) {
            check(!MascotControl.standard.contains(control), "\(control) is standard, not its own")
            check(range.lower < range.upper, "\(control)'s range is empty")
            check(range.contains(range.rest), "\(control) rests outside its range")
        }
        for part in rig.parts {
            if case .cells(_, let control?)? = part.shape {
                check(known.contains(control), "\(part.name): its cells' \(control) is not declared")
            }
            // A morph names a declared control over a real range, and moves
            // every point the outline has — no more, no fewer.
            if case .polygon(let points, _, let morphs)? = part.shape {
                for morph in morphs {
                    check(known.contains(morph.control), "\(part.name): its morph's \(morph.control) is not declared")
                    check(morph.input.start != morph.input.end, "\(part.name): a morph on \(morph.control) has no input range")
                    check(morph.points.count == points.count,
                          "\(part.name): a morph on \(morph.control) has \(morph.points.count) points, the outline \(points.count)")
                }
            }
            for binding in part.bindings {
                check(known.contains(binding.control), "\(part.name): \(binding.control) is not declared")
                check(binding.input.start != binding.input.end, "\(part.name): \(binding.control) has no input range")
            }
        }

        for (name, clip) in clips {
            // Only the controls the rig declared, and only inside their
            // ranges. A zero hold is a busy loop, and a step still moving
            // when the next starts reads as drift.
            check(!clip.steps.isEmpty, "\(name) never moves")
            for (i, step) in clip.steps.enumerated() {
                for (control, value) in step.pose.own.sorted(by: { $0.key.name < $1.key.name }) {
                    let range = rig.controls[control]
                    check(range != nil, "\(name) step \(i): \(control) is not declared")
                    check(range?.contains(value) ?? true, "\(name) step \(i): \(control) = \(value) is outside its range")
                }
                check(step.hold > 0 && step.motion > 0 && step.motion <= step.hold + 1e-9,
                      "\(name) step \(i): holds \(step.hold) s, moves \(step.motion) s")
            }
        }

        for phase in Phase.allCases {
            let clip = character.clip(for: phase, pacing: .normal)
            // Every phase change feels the same, whoever is drawn: it lands
            // on the shared spring. A loop ends on the pose it began with, so
            // its seam is not a jump.
            check(clip.steps.first?.curve == MascotPose.transition, "\(phase) does not enter on the shared spring")
            if clip.loops {
                check(clip.steps.last?.pose == clip.steps.first?.pose, "\(phase)'s loop seam is a jump")
                // Clips burst: a phase sat in for hours keeps a sparse rhythm.
                check(clip.movingTime > 0, "\(phase) loops without moving")
                check((clip.dutyCycle ?? 1) <= maxDutyCycle,
                      "\(phase) moves \(clip.dutyCycle ?? 1) of its cycle, over \(maxDutyCycle)")
            }
            // Nothing rests tilted: a lean held for as long as a phase lasts
            // reads as stuck. A character may lean as a gesture, on arrival
            // or in its own motions, and lets it go.
            check(character.resting(for: phase).tilt == 0, "\(phase) rests tilted")
        }

        // The five phases read apart: no two rest at the same pose, and
        // `waiting` arrives moving — however a character says it is
        // waiting, it must say it.
        let rests = Phase.allCases.map { character.resting(for: $0) }
        for (a, first) in rests.enumerated() {
            for (b, second) in rests.enumerated() where b > a {
                check(first != second, "\(Phase.allCases[a]) and \(Phase.allCases[b]) rest alike")
            }
        }
        check(character.clip(for: .waiting, pacing: .normal).movingTime > 0, "waiting does not arrive moving")

        // A motion is a gesture on top of a phase: it plays once and hands
        // the phase back. One that looped would never hand it back.
        for (name, motion) in character.motions.sorted(by: { $0.key < $1.key }) {
            check(!motion.loops, "motion \(name) loops")
        }

        for (i, rule) in character.behavior.rules.enumerated() {
            let at = "rule \(i)"
            let phaseClip = character.clip(for: rule.phase, pacing: .normal)
            // A rule plays the character's own gestures, at real times, with
            // real weights: a gesture name it does not have is a rule that
            // silently never plays.
            check(!rule.play.isEmpty, "\(at) plays nothing")
            for pick in rule.play {
                check(character.motions[pick.motion] != nil, "\(at): no gesture \(pick.motion)")
                check(pick.weight > 0, "\(at): \(pick.motion) weighs nothing")
                // It ends on its phase's rest — the pose a one-shot phase
                // holds and where the player takes a loop back up — so it
                // never jumps out.
                if let motion = character.motions[pick.motion] {
                    check(motion.steps.last?.pose == character.resting(for: rule.phase),
                          "\(at): \(pick.motion) ends off \(rule.phase)'s rest")
                }
            }
            check(rule.after >= 0, "\(at) is due before its phase began")
            // A one-shot phase's arrival is never cut short (the player waits
            // for it); a looping phase's entry is only the shared spring,
            // which a gesture at `after` 0 would land on top of.
            if phaseClip.loops {
                check(rule.after >= MascotPose.transitionDuration, "\(at) would cut the phase change's spring short")
            }
            if let every = rule.every {
                check(every > 0, "\(at) repeats at once")
                // A rule that repeats pays for its gestures: played every
                // `every` seconds on top of its phase, its longest gesture
                // adds that share of time in motion to the phase's own.
                let longest = rule.play.compactMap { character.motions[$0.motion]?.movingTime }.max() ?? 0
                let total = (phaseClip.dutyCycle ?? 0) + longest / every
                check(total <= maxDutyCycle, "\(at) moves \(total) of the time with its phase, over \(maxDutyCycle)")
            }
            for condition in rule.when {
                check(condition.atLeast <= condition.atMost, "\(at): a condition no count meets")
            }
        }
        return out
    }
}
