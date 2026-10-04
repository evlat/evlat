import XCTest
@testable import EvlatApp

/// The waiting reminder: once per wait, after the chosen minutes, re-armed
/// by an answer, its notification taken back then; off unless chosen.
final class WaitingNudgeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAWaitIsToldOnceAfterTheChosenTime() {
        var nudge = WaitingNudge()
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0, after: 60).due, [])
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 59, after: 60).due, [])
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 60, after: 60).due, ["a"])
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 600, after: 60).due, [], "one wait is told once")
    }

    func testAnAnswerTakesTheNoticeBackAndRearmsIt() {
        var nudge = WaitingNudge()
        _ = nudge.update(waiting: ["a"], now: t0, after: 60)
        _ = nudge.update(waiting: ["a"], now: t0 + 60, after: 60)
        XCTAssertEqual(nudge.update(waiting: [], now: t0 + 61, after: 60), .init(due: [], ended: ["a"]))
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 62, after: 60).due, [], "the new wait starts now")
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 122, after: 60).due, ["a"])
    }

    func testAnUntoldWaitEndsWithNothingToTakeBack() {
        var nudge = WaitingNudge()
        _ = nudge.update(waiting: ["a"], now: t0, after: 60)
        XCTAssertEqual(nudge.update(waiting: [], now: t0 + 10, after: 60), .init())
    }

    func testOffNeverTellsButStillTimes() {
        var nudge = WaitingNudge()
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0, after: nil).due, [])
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 3600, after: nil).due, [])
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 3601, after: 60).due, ["a"],
                       "turned on mid-wait, it counts from the wait's start")
    }

    func testSeveralDueAtOnceComeTogether() {
        var nudge = WaitingNudge()
        _ = nudge.update(waiting: ["a", "b"], now: t0, after: 60)
        XCTAssertEqual(nudge.update(waiting: ["a", "b"], now: t0 + 60, after: 60).due, ["a", "b"])
        XCTAssertEqual(nudge.update(waiting: ["a", "b"], now: t0 + 61, after: 60).due, [])
    }

    /// At the tab when it came due: timed again from then, due once more
    /// after the same minutes, and nothing to take back at its end.
    func testARearmedWaitComesDueAgainAfterTheSameTime() {
        var nudge = WaitingNudge()
        _ = nudge.update(waiting: ["a"], now: t0, after: 60)
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 60, after: 60).due, ["a"])
        nudge.rearm("a", at: t0 + 60)
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 119, after: 60), .init())
        XCTAssertEqual(nudge.update(waiting: ["a"], now: t0 + 120, after: 60).due, ["a"])
        nudge.rearm("a", at: t0 + 120)
        XCTAssertEqual(nudge.update(waiting: [], now: t0 + 121, after: 60), .init(), "nothing was posted")
        nudge.rearm("b", at: t0 + 121)
        XCTAssertEqual(nudge.since, [:], "a wait not seen is not made up")
    }

    func testTheStoredMinutesAreOnlyTheOffered() {
        let name = "evlat.tests.nudge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppController.storedNudgeMinutes(defaults), 0, "nothing stored is off")
        defaults.set(5, forKey: AppController.nudgeKey)
        XCTAssertEqual(AppController.storedNudgeMinutes(defaults), 5)
        defaults.set(7, forKey: AppController.nudgeKey)
        XCTAssertEqual(AppController.storedNudgeMinutes(defaults), 0)
    }

}
