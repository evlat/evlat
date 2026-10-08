import SwiftUI
import EvlatCore

/// A character: what the mascot looks like and, where it chooses, how it
/// moves. The contract every folder in `Characters/` fills in.
///
/// Only the rig is required. Bound to the standard controls, it plays
/// Evlat's own clip in every phase (`MascotClip.clip(for:)`) — a character
/// with nothing else written already looks, blinks and waits. Beyond that a
/// character may play any phase **its own way** (`states`) and keep gestures
/// of its own (`motions`), written in the same clip data with its own
/// controls set: a serious character need not widen its eyes to say it is
/// waiting, it may straighten and turn to you instead.
///
/// What is not the character's to decide is that the five phases read apart
/// — above all that `waiting` is noticed, which is the whole product.
/// `MascotCharacterContractTests` holds every character in
/// `MascotCharacters.all` to that, and to the CPU budget the clips burst in.
///
/// Characters are written in code, one folder each: there is no file format
/// and nothing is loaded from outside, so a character is checked by the
/// compiler and the contract tests before anyone sees it.
struct MascotCharacter: Equatable {
    /// Unique among the characters; what a stored choice will name.
    let id: String
    let rig: MascotRig
    /// The phases it plays its own way. A phase not here plays Evlat's clip.
    var states: [Phase: MascotClip] = [:]
    /// Gestures of its own, by name, each played once on top of a phase.
    var motions: [String: MascotClip] = [:]

    /// The clip a phase plays on this character.
    func clip(for phase: Phase, pacing: MascotPacing = MascotPacing.selected) -> MascotClip {
        guard let own = states[phase] else { return MascotClip.clip(for: phase, pacing: pacing) }
        return pacing == .continuous ? own.continuous : own
    }

    /// The pose a phase rests at: the first step of its clip, which is where
    /// a phase change lands and what the asleep mascot draws.
    func resting(for phase: Phase) -> MascotPose {
        clip(for: phase, pacing: .normal).steps.first?.pose ?? MascotPose.resting(for: phase)
    }
}
