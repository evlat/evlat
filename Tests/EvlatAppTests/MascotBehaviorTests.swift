import XCTest
import EvlatCore
@testable import EvlatApp

/// The behavior's one decision, on the test lantern's rules: a wait
/// answered at one minute and again at five, and an accent every 20 s while
/// work goes on with a finish unseen.
final class MascotBehaviorTests: XCTestCase {
    private let behavior = MascotTestCharacters.behavior

    private func decide(_ phase: Phase, at seconds: Double, _ sessions: MascotContext.Sessions = .init(),
                        memory: MascotBehavior.Memory = .init(), roll: Double = 0) -> MascotBehavior.Decision {
        behavior.decide(MascotContext(phase: phase, secondsInPhase: seconds, sessions: sessions),
                        memory: memory, random: { roll })
    }

    /// Entering the wait plays nothing and asks to be woken when the first
    /// stage is due — not before, and not on a tick.
    func testAStageWaitsForItsTimeAndAsksToBeWokenThen() {
        let start = decide(.waiting, at: 0)
        XCTAssertNil(start.motion)
        XCTAssertEqual(start.wake, 60)
        let later = decide(.waiting, at: 25, memory: start.memory)
        XCTAssertNil(later.motion)
        XCTAssertEqual(later.wake ?? 0, 35, accuracy: 1e-9)
    }

    /// At its time a stage speaks once, and the wake moves on to the next.
    func testAStageSpeaksOnceAndTheNextIsAwaited() {
        let first = decide(.waiting, at: 60)
        XCTAssertEqual(first.motion, "flicker")
        XCTAssertEqual(first.wake ?? 0, 240, accuracy: 1e-9)
        let again = decide(.waiting, at: 61, memory: first.memory)
        XCTAssertNil(again.motion, "a once-per-phase rule does not repeat")
        XCTAssertEqual(again.wake ?? 0, 239, accuracy: 1e-9)
        let second = decide(.waiting, at: 300, memory: again.memory)
        XCTAssertEqual(second.motion, "sway")
        XCTAssertNil(second.wake, "nothing is left to wait for")
    }

    /// **Stages never go back.** Asked late — the mascot was hidden for the
    /// first ten minutes of the wait — only the furthest stage reached
    /// speaks, and the earlier one is spent with it rather than played next.
    func testAskedLateOnlyTheFurthestStageSpeaks() {
        let late = decide(.waiting, at: 600)
        XCTAssertEqual(late.motion, "sway")
        let after = decide(.waiting, at: 601, memory: late.memory)
        XCTAssertNil(after.motion, "the one-minute stage must not play after the five-minute one")
        XCTAssertNil(after.wake)
    }

    /// A rule whose condition does not hold neither plays nor asks to be
    /// woken: only an event — the sessions changing — can change that.
    func testAConditionThatDoesNotHoldWaitsForAnEvent() {
        let quiet = decide(.working, at: 100)
        XCTAssertNil(quiet.motion)
        XCTAssertNil(quiet.wake, "no tick: a count changes only with an event")
        let heard = decide(.working, at: 100, .init(working: 1, news: 1))
        XCTAssertNotNil(heard.motion)
    }

    /// A repeating rule speaks, then is due again `every` seconds later.
    func testARepeatingRuleComesBackOnItsInterval() {
        let news = MascotContext.Sessions(working: 1, news: 1)
        let first = decide(.working, at: 0, news)
        XCTAssertNotNil(first.motion)
        XCTAssertEqual(first.wake, 20)
        let between = decide(.working, at: 12, news, memory: first.memory)
        XCTAssertNil(between.motion)
        XCTAssertEqual(between.wake ?? 0, 8, accuracy: 1e-9)
        XCTAssertNotNil(decide(.working, at: 20, news, memory: between.memory).motion)
    }

    /// A rule is its phase's: the wait's stages say nothing while working.
    func testRulesSpeakOnlyInTheirPhase() {
        for phase in [Phase.idle, .review, .failed] {
            let decision = decide(phase, at: 1000, .init(waiting: 2, working: 2, news: 2))
            XCTAssertNil(decision.motion, "\(phase)")
            XCTAssertNil(decision.wake, "\(phase)")
        }
    }

    /// The dice are handed in: a weighted pick is a pure function of the roll.
    func testAWeightedPickFollowsTheRoll() {
        let picks: [MascotRule.Pick] = [.init("flicker"), .init("sway", weight: 3)]
        XCTAssertEqual(MascotBehavior.pick(picks, 0), "flicker")
        XCTAssertEqual(MascotBehavior.pick(picks, 0.24), "flicker")
        XCTAssertEqual(MascotBehavior.pick(picks, 0.25), "sway")
        XCTAssertEqual(MascotBehavior.pick(picks, 0.99), "sway")
        XCTAssertNil(MascotBehavior.pick([], 0.5))
    }

    // MARK: - What the shell hands in

    /// The counts come from the snapshot the face is made from: live rows by
    /// where they stand, a seen finish counted as nothing.
    func testTheSessionsAreCountedFromTheSnapshot() {
        let now = Date()
        func row(_ entity: String, _ phase: Phase) -> Signal {
            Signal(provider: "stub", entity: entity, phase: phase, label: entity, fidelity: .official, updatedAt: now)
        }
        let seenFinish = row("e", .review)
        let snapshot = Registry.Snapshot(
            signals: [row("a", .waiting), row("b", .waiting), row("c", .working), row("d", .failed), seenFinish,
                      row("f", .idle)],
            seen: [Finish(entity: "e", phase: .review, updatedAt: now)])
        XCTAssertEqual(MascotContext.Sessions(snapshot), MascotContext.Sessions(waiting: 2, working: 1, news: 1))
    }
}

/// The model's side of the context.
@MainActor
final class MascotModelContextTests: XCTestCase {
    /// "How long" is counted from the drawn phase's change, forced or not —
    /// and a write that leaves the drawn phase as it was does not restart it.
    func testThePhaseIsTimedFromWhenTheDrawnPhaseChanged() {
        var clock = Date(timeIntervalSince1970: 1000)
        let model = MascotModel(now: { clock })
        XCTAssertEqual(model.phaseSince, clock)
        clock += 30
        model.phase = .working
        XCTAssertEqual(model.phaseSince, clock)
        clock += 30
        model.phase = .working
        XCTAssertEqual(model.phaseSince.timeIntervalSince1970, 1030, "same phase, same start")
        clock += 30
        model.override = .waiting
        XCTAssertEqual(model.phaseSince, clock, "a forced phase is a drawn phase")
        clock += 30
        model.phase = .idle
        XCTAssertEqual(model.phaseSince.timeIntervalSince1970, 1090, "the forced phase still draws")
    }

    /// The cube has no rules, so the counts are never published to it — the
    /// face redraws exactly as often as it did before rules existed.
    func testACharacterWithoutRulesIsNotToldTheSessions() {
        let model = MascotModel()
        model.hear(.init(waiting: 2))
        XCTAssertEqual(model.sessions, MascotContext.Sessions())
        model.character = MascotTestCharacters.lantern
        model.hear(.init(waiting: 2))
        XCTAssertEqual(model.sessions, MascotContext.Sessions(waiting: 2))
    }
}
