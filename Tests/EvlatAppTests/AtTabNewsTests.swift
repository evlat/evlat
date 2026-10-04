import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// News kept quiet while the user is at the session's tab (`isAtTab`): the
/// face, the ring and the news stay as they are, the sound and the peek do
/// not come, and nothing is taken for seen. The question is answered by the
/// test, now or later; no terminal is ever asked.
@MainActor
final class AtTabNewsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    @MainActor private final class Rig {
        let controller = AppController()
        let provider = Stub()
        var played: [AlertSound] = []
        var panel: BarPanel!
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        /// Who was asked about, in order.
        var asked: [String] = []
        /// The answer given at once; `nil` holds the question in `held`.
        var answer: Bool? = true
        var held: [(Bool) -> Void] = []

        init() {
            controller.now = { [unowned self] in self.now }
            controller.peekSchedule = { _, _ in }
            controller.soundTones = [.done: .evlat(.rise), .failed: .evlat(.fall),
                                     .approval: .evlat(.bell), .answer: .evlat(.question)]
            controller.soundOn = [.done: true, .failed: true, .approval: true, .answer: true]
            controller.registry.register(provider)
            panel = controller.installPanel()
            controller.playSound = { [unowned self] in self.played.append($0) }
            controller.isAtTab = { [unowned self] row, reply in
                self.asked.append(row.entity)
                if let answer = self.answer { reply(answer) } else { self.held.append(reply) }
            }
            controller.refresh()
        }

        func set(_ rows: [(String, Phase)]) {
            provider.signals = rows.map {
                Signal(provider: "stub", entity: $0.0, phase: $0.1, label: $0.0, fidelity: .official,
                       updatedAt: Date(timeIntervalSince1970: 0),
                       activity: $0.1 == .waiting ? Signal.Activity(waitKind: .approval) : nil)
            }
            controller.refresh()
        }

        /// Answers the questions held, oldest first.
        func reply(_ at: Bool) {
            let replies = held
            held = []
            replies.forEach { $0(at) }
        }

        var news: [Finish] { controller.registry.snapshot(seen: controller.seen).news }
    }

    // MARK: - A finish

    /// At the tab: no sound, no peek; still news, still told once, and its
    /// reminder comes as any told finish's would — asked again then.
    func testAFinishAtItsTabIsQuietAndStillNews() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.nudgeScope = .all
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.asked, ["s"])
        XCTAssertEqual(rig.played, [])
        XCTAssertNil(rig.controller.peekPhase)
        XCTAssertEqual(rig.news.map(\.entity), ["s"], "never taken for seen")
        XCTAssertTrue(rig.controller.seen.isEmpty)
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s"], "told once, asked once")
        rig.answer = false
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s", "s"])
        XCTAssertEqual(rig.played, [.evlat(.rise)], "the reminder, away from the tab")
    }

    func testAFinishAwayFromItsTabIsToldAsAlways() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = false
        rig.controller.bodyMode = .tucked
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    func testFinishesTogetherAreToldWithoutAsking() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("a", .working), ("b", .working)])
        rig.set([("a", .review), ("b", .failed)])
        XCTAssertEqual(rig.asked, [])
        XCTAssertEqual(rig.played, [.evlat(.fall)])
    }

    /// Nothing to keep quiet, nothing asked: its sound off and a body that
    /// shows no finish. Under Tucked its peek would show it. With the peek
    /// off the sliver's dot is the row's state, which is no news to keep
    /// quiet — unless a wait's amber covers it, and the dot tells the finish.
    func testAFinishThatWouldShowNothingAsksNothing() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.soundOn[.done] = false
        for mode in [BodyPresence.Mode.always, .hidden] {
            rig.controller.bodyMode = mode
            rig.set([("s-\(mode)", .working)])
            rig.set([("s-\(mode)", .review)])
        }
        XCTAssertEqual(rig.asked, [])
        rig.controller.bodyMode = .tucked
        rig.set([("t", .working)])
        rig.set([("t", .review)])
        XCTAssertEqual(rig.asked, ["t"], "its peek")
        rig.controller.bodyToggles.peekDone = false
        rig.set([("u", .working)])
        rig.set([("u", .review)])
        XCTAssertEqual(rig.asked, ["t"], "the dot already shows the review")
        rig.controller.bodyToggles.peekWaiting = false
        rig.controller.soundOn[.approval] = false
        rig.set([("w", .waiting), ("v", .working)])
        rig.set([("w", .waiting), ("v", .review)])
        XCTAssertEqual(rig.asked, ["t", "v"], "the dot tells it over the amber")
    }

    /// A late "no" tells the finish if nothing moved meanwhile.
    func testALateAnswerTellsAFinishStillUnwatched() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [], "waiting for the answer")
        rig.reply(false)
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        XCTAssertEqual(rig.controller.peekPhase, .review)
    }

    /// What the user saw while the question was out is not told late: the
    /// bar opened, or the row moved on.
    func testALateAnswerDoesNotTellWhatMovedMeanwhile() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        rig.controller.openBar()
        rig.reply(false)
        XCTAssertEqual(rig.played, [])
        rig.controller.closeBar()
        rig.set([("t", .working)])
        rig.set([("t", .review)])
        rig.set([("t", .working)])
        rig.reply(false)
        XCTAssertEqual(rig.played, [], "no longer news")
        XCTAssertNil(rig.controller.peekPhase)
    }

    // MARK: - A wait

    func testAWaitBeginningAtItsTabIsQuiet() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        XCTAssertEqual(rig.asked, ["s"])
        XCTAssertEqual(rig.played, [])
        XCTAssertEqual(rig.controller.mascot.phase, .waiting, "the face is the registry's")
    }

    func testAWaitAnsweredBeforeTheAnswerIsNotTold() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.answer = nil
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.set([("s", .working)])
        rig.reply(false)
        XCTAssertEqual(rig.played, [])
    }

    /// Due at its tab: no reminder, timed again; due once more after the
    /// same minutes, and away from the tab then, it speaks.
    func testAWaitDueAtItsTabIsTimedAgain() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.asked, ["s", "s"])
        XCTAssertEqual(rig.played, [])
        rig.now += 119
        rig.controller.refresh()
        XCTAssertEqual(rig.asked.count, 2, "not before the minutes again")
        rig.answer = false
        rig.now += 1
        rig.controller.refresh()
        XCTAssertEqual(rig.asked.count, 3)
        XCTAssertEqual(rig.played, [.evlat(.bell)])
    }

    /// The reminder is the user's to have asked for: it speaks on the open
    /// bar as it always did, a late answer included.
    func testAWaitDueAwayFromItsTabSpeaksOnTheOpenBarToo() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.set([("s", .waiting)])
        rig.answer = nil
        rig.controller.openBar()
        rig.now += 120
        rig.controller.refresh()
        rig.reply(false)
        XCTAssertEqual(rig.played, [.evlat(.bell)])
    }
}
