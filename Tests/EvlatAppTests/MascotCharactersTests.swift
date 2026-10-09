import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// What each shipped character's doc says it does, held where the contract
/// cannot: the contract keeps every character honest, these keep each one
/// itself.
final class MascotCharactersTests: XCTestCase {
    private func part(_ name: String, of character: MascotCharacter) throws -> MascotPart {
        try XCTUnwrap(character.rig.parts.first { $0.name == name }, "\(character.id) has no \(name)")
    }

    private func resolved(_ name: String, of character: MascotCharacter, in pose: MascotPose) throws
        -> MascotPart.Resolved {
        try part(name, of: character).resolved(in: pose, rig: character.rig)
    }

    func testTheCatalogFindsACharacterByIdAndFallsBackToTheCube() {
        XCTAssertEqual(MascotCharacters.all.map(\.id), ["cube", "pati", "bit", "puf"])
        XCTAssertEqual(MascotCharacters.character(id: "bit").id, "bit")
        XCTAssertEqual(MascotCharacters.character(id: nil).id, "cube", "nothing chosen")
        XCTAssertEqual(MascotCharacters.character(id: "gone").id, "cube", "a choice outlives a character")
    }

    /// Pati's ears say what its eyes say: up and in while it waits, back
    /// while it works, flat on a failure — and a blink leaves them alone.
    func testPatisEarsFollowItsEyes() throws {
        let pati = Pati.character
        let rest = try resolved("leftEar", of: pati, in: pati.resting(for: .idle))
        let waiting = try resolved("leftEar", of: pati, in: pati.resting(for: .waiting))
        let working = try resolved("leftEar", of: pati, in: pati.resting(for: .working))
        let failed = try resolved("leftEar", of: pati, in: pati.resting(for: .failed))
        XCTAssertLessThan(waiting.offsetY, rest.offsetY, "waiting pricks them up")
        XCTAssertGreaterThan(waiting.rotation, rest.rotation, "and in, toward the middle")
        XCTAssertLessThan(working.rotation, rest.rotation, "working lays them back a little")
        XCTAssertLessThan(failed.rotation, working.rotation, "a failure lays them flat")
        var blink = pati.resting(for: .idle)
        blink.eyeOpen *= 0.08
        XCTAssertEqual(try resolved("leftEar", of: pati, in: blink), rest, "a blink does not twitch the ears")
        let right = try resolved("rightEar", of: pati, in: pati.resting(for: .failed))
        XCTAssertEqual(right.rotation, -failed.rotation, accuracy: 1e-9, "the ears are a mirrored pair")
    }

    /// Bit's bulb burns low at rest and bright only when the eyes open past
    /// it; its antenna droops on a failure.
    func testBitsBulbLightsOnlyWhenItWaitsOrCatches() throws {
        let bit = Bit.character
        let low = try resolved("bulb", of: bit, in: bit.resting(for: .idle)).opacity
        XCTAssertLessThan(low, 0.5)
        for phase in [Phase.idle, .working, .review, .failed] {
            XCTAssertEqual(try resolved("bulb", of: bit, in: bit.resting(for: phase)).opacity, low, "\(phase)")
        }
        XCTAssertEqual(try resolved("bulb", of: bit, in: bit.resting(for: .waiting)).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(try resolved("bulb", of: bit, in: MascotPose.catching).opacity, 1)
        XCTAssertGreaterThan(try resolved("stem", of: bit, in: bit.resting(for: .failed)).rotation, 20,
                             "the antenna droops")
    }

    /// Puf turns height into floating: a breath lifts it, a failure sinks it.
    func testPufRisesOnABreathAndSinksOnAFailure() throws {
        let puf = Puf.character
        let rest = try resolved("puf", of: puf, in: puf.resting(for: .idle))
        XCTAssertEqual(rest.offsetY, 0, accuracy: 1e-9)
        let breath = try resolved("puf", of: puf, in: puf.resting(for: .idle).scaled(by: 1.02))
        XCTAssertLessThan(breath.offsetY, 0, "a breath lifts it")
        XCTAssertLessThan(try resolved("puf", of: puf, in: puf.resting(for: .waiting)).offsetY, 0)
        XCTAssertGreaterThan(try resolved("puf", of: puf, in: puf.resting(for: .failed)).offsetY, 0,
                             "a failure sinks it")
    }

    // MARK: - Their own gestures

    private func decide(_ character: MascotCharacter, _ phase: Phase, at seconds: Double,
                        memory: MascotBehavior.Memory = .init()) -> MascotBehavior.Decision {
        character.behavior.decide(MascotContext(phase: phase, secondsInPhase: seconds, sessions: .init()),
                                  memory: memory, random: { 0 })
    }

    /// Walks a phase from its start, answering each wake as the player
    /// would, and says when a gesture played.
    private func timeline(_ character: MascotCharacter, _ phase: Phase, for seconds: Double) -> [(Double, String)] {
        var played: [(Double, String)] = []
        var memory = MascotBehavior.Memory()
        var t = 0.0
        while t <= seconds {
            let decision = decide(character, phase, at: t, memory: memory)
            memory = decision.memory
            if let motion = decision.motion { played.append((t, motion)) }
            guard let wake = decision.wake else { break }
            t += wake
        }
        return played
    }

    /// Pati twitches an ear twice in a long wait — at 45 s and at three
    /// minutes — and in no other phase.
    func testPatiTwitchesTwiceInALongWaitAndNowhereElse() {
        let played = timeline(Pati.character, .waiting, for: 3600)
        XCTAssertEqual(played.map(\.0), [45, 180])
        XCTAssertEqual(Set(played.map(\.1)), ["twitch"])
        for phase in Phase.allCases where phase != .waiting {
            XCTAssertTrue(timeline(Pati.character, phase, for: 3600).isEmpty, "\(phase)")
        }
    }

    /// Bit blinks its bulb at 30 s and at two minutes of a wait, and in no
    /// other phase.
    func testBitBlinksTwiceInALongWaitAndNowhereElse() {
        let played = timeline(Bit.character, .waiting, for: 3600)
        XCTAssertEqual(played.map(\.0), [30, 120])
        XCTAssertEqual(Set(played.map(\.1)), ["blink"])
        for phase in Phase.allCases where phase != .waiting {
            XCTAssertTrue(timeline(Bit.character, phase, for: 3600).isEmpty, "\(phase)")
        }
    }

    /// Puf hops once per finish, as soon as the finish has arrived (the
    /// player waits out the arrival), and in no other phase.
    func testPufHopsOncePerFinish() {
        XCTAssertEqual(timeline(Puf.character, .review, for: 3600).map(\.1), ["hop"])
        for phase in Phase.allCases where phase != .review {
            XCTAssertTrue(timeline(Puf.character, phase, for: 3600).isEmpty, "\(phase)")
        }
    }

    /// A gesture ends on its phase's resting pose — the pose a one-shot
    /// phase holds once it has arrived, and where the player takes the
    /// phase back up — so it does not jump out.
    func testEveryGestureEndsOnItsPhasesRest() throws {
        for character in [Pati.character, Bit.character, Puf.character] {
            for rule in character.behavior.rules {
                for pick in rule.play {
                    let gesture = try XCTUnwrap(character.motions[pick.motion])
                    XCTAssertEqual(gesture.steps.last?.pose, character.resting(for: rule.phase),
                                   "\(character.id) \(pick.motion)")
                }
            }
        }
    }

    /// Pati's twitch and Bit's blink move their own control and nothing
    /// else: the face stays as the wait left it. (Puf's hop is the body
    /// itself, written in the standard controls.)
    func testTheEarAndTheBulbMoveNothingElse() throws {
        for (character, name, phase) in [(Pati.character, "twitch", Phase.waiting), (Bit.character, "blink", .waiting)] {
            var rest = character.resting(for: phase)
            rest.own = [:]
            for (i, step) in try XCTUnwrap(character.motions[name]).steps.enumerated() {
                var bare = step.pose
                bare.own = [:]
                XCTAssertEqual(bare, rest, "\(character.id) \(name) step \(i)")
            }
        }
    }

    /// Bit's blink puts the bulb out while it waits; Pati's twitch turns
    /// the right ear alone.
    func testTheGesturesMoveWhatTheySay() throws {
        let bit = Bit.character
        let lit = try resolved("bulb", of: bit, in: bit.resting(for: .waiting)).opacity
        let out = try resolved("bulb", of: bit, in: bit.resting(for: .waiting).setting(Bit.dimControl, to: 1)).opacity
        XCTAssertLessThan(out, lit * 0.2)
        let pati = Pati.character
        let twitched = pati.resting(for: .waiting).setting(Pati.twitchControl, to: 1)
        XCTAssertEqual(try resolved("leftEar", of: pati, in: twitched),
                       try resolved("leftEar", of: pati, in: pati.resting(for: .waiting)))
        XCTAssertNotEqual(try resolved("rightEar", of: pati, in: twitched).rotation,
                          try resolved("rightEar", of: pati, in: pati.resting(for: .waiting)).rotation)
    }

    /// A polygon's outline stays inside the frame it is drawn in: its arcs
    /// round the corners in, never out.
    func testAPolygonStaysInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 30)
        let points = [CGPoint(x: 0, y: 1), CGPoint(x: 0.2, y: 0), CGPoint(x: 1, y: 0.9)]
        let box = RoundedPolygon(points: points, radius: 2).path(in: rect).boundingRect
        XCTAssertFalse(box.isEmpty)
        XCTAssertTrue(rect.insetBy(dx: -1e-6, dy: -1e-6).contains(box), "\(box)")
        XCTAssertTrue(RoundedPolygon(points: Array(points.prefix(2)), radius: 2).path(in: rect).isEmpty,
                      "two points are no outline")
    }
}
