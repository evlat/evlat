import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The body's presence rule: which level each mode, phase and toggle set
/// draws, which dot it carries, and the geometry that follows from it — and
/// the readers of the stored mode and toggles.
///
/// Every test that stores anything has its own suite, removed in `tearDown`:
/// the user's domain is never read or written here.
@MainActor
final class BodyPresenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "evlat.tests.body.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private static let closedLength = AppController.barLength(slots: 3)
    private static let openWidth: CGFloat = 180
    private static let openLength = AppController.openLength(rows: 3)

    private func presence(_ mode: BodyPresence.Mode, _ phase: Phase,
                          toggles: BodyPresence.Toggles = .init(),
                          peekPhase: Phase? = nil,
                          isOpen: Bool = false, chatOpen: Bool = false,
                          dragging: Bool = false, edgeClear: Bool = false) -> BodyPresence {
        BodyPresence(mode: mode, toggles: toggles, phase: phase,
                     peekPhase: peekPhase, isOpen: isOpen, chatOpen: chatOpen,
                     dragging: dragging, edgeClear: edgeClear, closedLength: Self.closedLength,
                     openWidth: Self.openWidth, openLength: Self.openLength)
    }

    private static let allToggles: [BodyPresence.Toggles] = [false, true].flatMap { sliver in
        [false, true].flatMap { waiting in
            [false, true].map { done in
                BodyPresence.Toggles(sliver: sliver, peekWaiting: waiting, peekDone: done)
            }
        }
    }

    // MARK: Levels

    func testAlwaysIsTheFullBodyWhateverElseIsTrue() {
        for phase in Phase.allCases {
            for toggles in Self.allToggles {
                for peek in [nil, Phase.review, .failed] {
                    let p = presence(.always, phase, toggles: toggles, peekPhase: peek)
                    XCTAssertEqual(p.level, .full, "always · \(phase) · \(toggles)")
                    XCTAssertNil(p.dot, "the full body carries no dot")
                }
            }
        }
    }

    /// R3.1 with every toggle on: idle an empty sliver, working a white dot,
    /// waiting the peek, review and failed a peek while it lasts and a dot after.
    func testSmartFollowsThePhaseTable() {
        XCTAssertEqual(presence(.smart, .idle).level, .sliver)
        XCTAssertNil(presence(.smart, .idle).dot, "nothing stopped: no dot")

        XCTAssertEqual(presence(.smart, .working).level, .sliver, "working never comes out")
        XCTAssertEqual(presence(.smart, .working).dot, .working)

        XCTAssertEqual(presence(.smart, .waiting).level, .peek, "waiting comes out until answered")

        for done in [Phase.review, .failed] {
            let peeking = presence(.smart, done, peekPhase: done)
            XCTAssertEqual(peeking.level, .peek, "\(done) peeks while its peek lasts")
            let after = presence(.smart, done)
            XCTAssertEqual(after.level, .sliver, "\(done) goes back in when the peek ends")
            XCTAssertEqual(after.dot, done)
        }
    }

    /// The dot is what the open bar would show: once the phase has gone
    /// back to idle, no finish is remembered.
    func testNoDotOutlivesThePhase() {
        XCTAssertNil(presence(.smart, .idle).dot)
        XCTAssertEqual(presence(.smart, .review).dot, .review)
        XCTAssertEqual(presence(.smart, .failed).dot, .failed)
    }

    /// A finish being told takes the dot over a higher phase for as long as
    /// it lasts — the peek switched off, a job done beside working sessions.
    func testAFinishBeingToldTakesTheDot() {
        let off = BodyPresence.Toggles(sliver: true, peekWaiting: false, peekDone: false)
        XCTAssertEqual(presence(.smart, .working, toggles: off, peekPhase: .review).dot, .review)
        XCTAssertEqual(presence(.smart, .waiting, toggles: off, peekPhase: .failed).dot, .failed)
        XCTAssertEqual(presence(.smart, .working, toggles: off).dot, .working, "and only while it lasts")
    }

    /// Every input the rule reads but the edge, in every combination.
    private func everyCase(_ mode: BodyPresence.Mode, edgeClear: Bool) -> [BodyPresence] {
        Phase.allCases.flatMap { phase in
            Self.allToggles.flatMap { toggles in
                [nil, Phase.review, .failed, .working].flatMap { peek in
                    [(false, false, false), (true, false, false),
                     (false, true, false), (false, false, true)].map { open, chat, drag in
                        presence(mode, phase, toggles: toggles, peekPhase: peek,
                                 isOpen: open, chatOpen: chat, dragging: drag, edgeClear: edgeClear)
                    }
                }
            }
        }
    }

    /// Tucked is the Smart hide that was: the same level, dot, area and
    /// trigger in every case, and the edge means nothing to it.
    func testTuckedIsSmartWithACoveredEdge() {
        let smart = everyCase(.smart, edgeClear: false)
        for clear in [false, true] {
            let tucked = everyCase(.tucked, edgeClear: clear)
            XCTAssertEqual(tucked.count, smart.count)
            for (t, s) in zip(tucked, smart) {
                let what = "\(s.phase) · \(s.toggles) · peek \(String(describing: s.peekPhase)) · clear \(clear)"
                XCTAssertEqual(t.level, s.level, what)
                XCTAssertEqual(t.dot, s.dot, what)
                XCTAssertEqual(t.area, s.area, what)
                XCTAssertEqual(t.trigger, s.trigger, what)
                XCTAssertEqual(t.mascotShown, s.mascotShown, what)
            }
        }
        XCTAssertEqual(presence(.tucked, .idle).level, .sliver)
        XCTAssertEqual(presence(.tucked, .working).dot, .working)
        XCTAssertEqual(presence(.tucked, .waiting).level, .peek)
        XCTAssertEqual(presence(.tucked, .idle, peekPhase: .review).level, .peek)
    }

    /// Under Smart a clear edge is the whole body, whatever the phase, the
    /// switches or a peek; it keeps the trigger strip and its length.
    func testSmartWithAClearEdgeIsTheFullBody() {
        for p in everyCase(.smart, edgeClear: true) {
            let what = "\(p.phase) · \(p.toggles) · peek \(String(describing: p.peekPhase))"
            XCTAssertEqual(p.level, .full, what)
            XCTAssertNil(p.dot, what)
            XCTAssertTrue(p.mascotShown, what)
            XCTAssertTrue(p.takesMascotClick, what)
            XCTAssertNotNil(p.trigger, "not today's bar: \(what)")
        }
        let closed = presence(.smart, .idle, edgeClear: true)
        XCTAssertEqual(closed.area, BodyPresence.Area(width: AppController.barWidth,
                                                      length: max(Self.closedLength, BodyPresence.triggerLength)))
        let open = presence(.smart, .idle, isOpen: true, edgeClear: true)
        XCTAssertEqual(open.area, presence(.smart, .idle, isOpen: true).area, "open, the edge changes nothing")
    }

    /// Only Smart reads the edge: Always is out anyway, Hidden stays hidden.
    func testOnlySmartReadsTheEdge() {
        for mode in [BodyPresence.Mode.always, .tucked, .hidden] {
            XCTAssertEqual(everyCase(mode, edgeClear: true).map(\.level),
                           everyCase(mode, edgeClear: false).map(\.level), "\(mode)")
        }
    }

    /// The picker's order is the cases' order; the switches shape only
    /// the two modes that have a sliver and peeks.
    func testTheModesAndWhichHaveSwitches() {
        XCTAssertEqual(BodyPresence.Mode.allCases, [.always, .smart, .tucked, .hidden])
        XCTAssertEqual(BodyPresence.Mode.allCases.filter(\.hasToggles), [.smart, .tucked])
    }

    /// R3.3: an open bar, the balloon or a file drag is the full body in
    /// every mode.
    func testOpenBalloonOrDragIsTheFullBodyInEveryMode() {
        for mode in BodyPresence.Mode.allCases {
            for phase in Phase.allCases {
                for toggles in Self.allToggles {
                    XCTAssertEqual(presence(mode, phase, toggles: toggles, isOpen: true).level, .full)
                    XCTAssertEqual(presence(mode, phase, toggles: toggles, chatOpen: true).level, .full)
                    XCTAssertEqual(presence(mode, phase, toggles: toggles, dragging: true).level, .full)
                }
            }
        }
    }

    /// R3.4: a toggle that is off takes its view away and nothing else.
    func testAToggleThatIsOffDropsItsView() {
        let noSliver = BodyPresence.Toggles(sliver: false, peekWaiting: true, peekDone: true)
        XCTAssertEqual(presence(.smart, .idle, toggles: noSliver).level, .none)
        XCTAssertEqual(presence(.smart, .working, toggles: noSliver).level, .none)
        XCTAssertNil(presence(.smart, .working, toggles: noSliver).dot, "no sliver, nothing to draw a dot on")
        XCTAssertEqual(presence(.smart, .waiting, toggles: noSliver).level, .peek,
                       "the peek does not need the sliver")

        let noWaitingPeek = BodyPresence.Toggles(sliver: true, peekWaiting: false, peekDone: true)
        let waiting = presence(.smart, .waiting, toggles: noWaitingPeek)
        XCTAssertEqual(waiting.level, .sliver)
        XCTAssertEqual(waiting.dot, .waiting, "waiting is told by the amber dot alone")

        let noDonePeek = BodyPresence.Toggles(sliver: true, peekWaiting: true, peekDone: false)
        for done in [Phase.review, .failed] {
            let p = presence(.smart, done, toggles: noDonePeek, peekPhase: done)
            XCTAssertEqual(p.level, .sliver, "\(done) with its peek off is the dot alone")
            XCTAssertEqual(p.dot, done)
        }

        let nothing = BodyPresence.Toggles(sliver: false, peekWaiting: false, peekDone: false)
        XCTAssertEqual(presence(.smart, .waiting, toggles: nothing).level, .none)
    }

    /// Only a review or a failure peeks on its own: a `peekPhase` of any
    /// other phase is not a finish and draws nothing new.
    func testOnlyAFinishPeeks() {
        for other in [Phase.idle, .working, .waiting] {
            XCTAssertEqual(presence(.smart, .idle, peekPhase: other).level, .sliver, "\(other)")
        }
    }

    /// R3.5: fully hidden has neither sliver nor peek, whatever the toggles.
    func testHiddenNeverDrawsASliverOrAPeek() {
        for phase in Phase.allCases {
            for toggles in Self.allToggles {
                for peek in [nil, Phase.review, .failed] {
                    let p = presence(.hidden, phase, toggles: toggles, peekPhase: peek)
                    XCTAssertEqual(p.level, .none, "hidden · \(phase) · \(toggles)")
                    XCTAssertNil(p.dot)
                }
            }
        }
    }

    // MARK: Mascot

    func testTheMascotIsShownAndClickableOnlyWhenItIsOut() {
        let cases: [(BodyPresence, BodyPresence.Level)] = [
            (presence(.smart, .idle, toggles: .init(sliver: false, peekWaiting: true, peekDone: true)), .none),
            (presence(.smart, .idle), .sliver),
            (presence(.smart, .waiting), .peek),
            (presence(.always, .idle), .full),
        ]
        for (p, level) in cases {
            XCTAssertEqual(p.level, level)
            let out = level == .peek || level == .full
            XCTAssertEqual(p.mascotShown, out, "\(level)")
            XCTAssertEqual(p.takesMascotClick, out, "\(level)")
        }
    }

    // MARK: Geometry

    /// R2's gate: under `always` the area is today's — the bar's width and
    /// length, closed or open — and on both edges the rectangle is the one
    /// the hosting view builds from the same numbers today.
    func testAlwaysGeometryIsTodays() {
        let bounds = NSRect(origin: .zero, size: AppController.envelopeSize)
        for phase in Phase.allCases {
            for isOpen in [false, true] {
                for chatOpen in [false, true] {
                    let p = presence(.always, phase, isOpen: isOpen, chatOpen: chatOpen)
                    let width = isOpen ? Self.openWidth : AppController.barWidth
                    let length = isOpen ? Self.openLength : Self.closedLength
                    XCTAssertEqual(p.area, BodyPresence.Area(width: width, length: length))
                    for edge in [BarPanel.Edge.right, .left] {
                        let today = BarHostingView.trackingRects(
                            in: bounds, inset: AppController.shadowGutter,
                            visibleWidth: width, visibleLength: length, card: nil,
                            flipped: true, edge: edge).body
                        XCTAssertEqual(p.area.rect(in: bounds, edge: edge), today,
                                       "\(edge) · open \(isOpen)")
                    }
                }
            }
        }
    }

    /// The sliver sits level with the mascot's centre, and the trigger runs
    /// from the window's top to 60 pt under the sliver.
    func testTheSliverAndTheTriggerHangFromTheMascot() {
        let centre = AppController.mascotTopInset + AppController.mascotSize / 2
        XCTAssertEqual(BodyPresence.sliverTop + BodyPresence.sliverLength / 2, centre)
        XCTAssertEqual(BodyPresence.sliverWidth, 8)
        XCTAssertEqual(BodyPresence.sliverLength, 72)
        XCTAssertEqual(BodyPresence.triggerLength,
                       BodyPresence.sliverTop + BodyPresence.sliverLength + 60)
    }

    /// Each level's area holds at least what it draws: the strip for
    /// none and sliver, the peek's width for the peek, the bar for full.
    func testEveryAreaHoldsWhatIsDrawn() {
        let noSliver = BodyPresence.Toggles(sliver: false, peekWaiting: true, peekDone: true)
        let none = presence(.smart, .idle, toggles: noSliver).area
        let sliver = presence(.smart, .idle).area
        XCTAssertEqual(none, BodyPresence.Area(width: BodyPresence.sliverWidth,
                                               length: BodyPresence.triggerLength))
        XCTAssertEqual(sliver, none)
        XCTAssertEqual(presence(.hidden, .waiting).area, none, "hidden still has its trigger")
        XCTAssertGreaterThanOrEqual(sliver.length, BodyPresence.sliverTop + BodyPresence.sliverLength)

        let peek = presence(.smart, .waiting).area
        XCTAssertEqual(peek, BodyPresence.Area(width: BodyPresence.peekWidth,
                                               length: BodyPresence.triggerLength))
        XCTAssertGreaterThanOrEqual(peek.length, AppController.mascotTopInset + AppController.mascotSize)

        let full = presence(.smart, .idle, chatOpen: true).area
        XCTAssertEqual(full, BodyPresence.Area(width: AppController.barWidth, length: Self.closedLength))
        let open = presence(.hidden, .idle, isOpen: true).area
        XCTAssertEqual(open, BodyPresence.Area(width: Self.openWidth, length: Self.openLength))
    }

    /// A body shorter than the strip (no session) still holds the strip:
    /// otherwise the strip's lower end opens it and the body, not reaching
    /// there, closes it again on the next move.
    func testTheWholeBodyHoldsTheStripThatOpenedIt() {
        let short = AppController.barLength(slots: 0)
        XCTAssertLessThan(short, BodyPresence.triggerLength, "precondition")
        for mode in [BodyPresence.Mode.smart, .tucked, .hidden] {
            for isOpen in [false, true] {
                let p = BodyPresence(mode: mode, toggles: .init(), phase: .idle,
                                     peekPhase: nil, isOpen: isOpen, chatOpen: false, dragging: true,
                                     closedLength: short, openWidth: Self.openWidth, openLength: short)
                XCTAssertEqual(p.area.length, BodyPresence.triggerLength, "\(mode) open \(isOpen)")
                XCTAssertEqual(p.trigger, p.area)
            }
        }
        let today = BodyPresence(mode: .always, toggles: .init(), phase: .idle,
                                 peekPhase: nil, isOpen: false, chatOpen: false, dragging: false,
                                 closedLength: short, openWidth: Self.openWidth, openLength: short)
        XCTAssertEqual(today.area.length, short, "today's bar is not lengthened")
        XCTAssertNil(today.trigger)
    }

    /// The left edge is the right one mirrored, at every level.
    func testTheLeftEdgeIsTheMirrorOfTheRight() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 400)
        let presences = [presence(.smart, .idle), presence(.smart, .waiting),
                         presence(.hidden, .idle), presence(.always, .idle),
                         presence(.smart, .idle, isOpen: true)]
        for p in presences {
            let right = p.area.rect(in: bounds, edge: .right)
            let left = p.area.rect(in: bounds, edge: .left)
            XCTAssertEqual(right.maxX, bounds.maxX, "held against the right edge")
            XCTAssertEqual(left.minX, bounds.minX, "held against the left edge")
            XCTAssertEqual(left.width, right.width)
            XCTAssertEqual(left.minY, right.minY)
            XCTAssertEqual(left.height, right.height)
            XCTAssertEqual(left.minY, bounds.minY, "from the window's top (flipped)")
        }
    }

    // MARK: Stored mode, toggles and EVLAT_BODY

    func testTheModeRoundTripsThroughItsStoredValue() {
        for mode in BodyPresence.Mode.allCases {
            XCTAssertEqual(BodyPresence.Mode(stored: mode.storedValue), mode)
        }
        XCTAssertEqual(BodyPresence.Mode.always.storedValue, "always")
        XCTAssertEqual(BodyPresence.Mode.smart.storedValue, "smart")
        XCTAssertEqual(BodyPresence.Mode.tucked.storedValue, "tucked")
        XCTAssertEqual(BodyPresence.Mode.hidden.storedValue, "hidden")
        XCTAssertNil(BodyPresence.Mode(stored: "top"))
        XCTAssertNil(BodyPresence.Mode(stored: nil))
    }

    func testNothingStoredIsAlwaysWithEveryToggleOn() {
        XCTAssertEqual(AppController.storedBodyMode(defaults), .always)
        XCTAssertEqual(AppController.storedBodyMode(nil), .always, "no storage at all")
        XCTAssertEqual(AppController.storedBodyToggles(defaults),
                       BodyPresence.Toggles(sliver: true, peekWaiting: true, peekDone: true))
        XCTAssertEqual(AppController.storedBodyToggles(nil), BodyPresence.Toggles())
    }

    func testTheStoredModeAndTogglesAreRead() {
        defaults.set("smart", forKey: AppController.bodyModeKey)
        XCTAssertEqual(AppController.storedBodyMode(defaults), .smart, "a stored Smart stays Smart")
        defaults.set("tucked", forKey: AppController.bodyModeKey)
        XCTAssertEqual(AppController.storedBodyMode(defaults), .tucked)
        defaults.set("hidden", forKey: AppController.bodyModeKey)
        XCTAssertEqual(AppController.storedBodyMode(defaults), .hidden)
        defaults.set("sideways", forKey: AppController.bodyModeKey)
        XCTAssertEqual(AppController.storedBodyMode(defaults), .always, "an unknown value is always")
        XCTAssertEqual(defaults.string(forKey: AppController.bodyModeKey), "sideways",
                       "reading writes nothing")

        let keys = [AppController.bodySliverKey, AppController.bodyPeekWaitingKey,
                    AppController.bodyPeekDoneKey]
        XCTAssertEqual(Set(keys).count, 3)
        for (index, key) in keys.enumerated() {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(false, forKey: key)
            let toggles = AppController.storedBodyToggles(defaults)
            let values = [toggles.sliver, toggles.peekWaiting, toggles.peekDone]
            for (other, value) in values.enumerated() {
                XCTAssertEqual(value, other != index, "\(key) stored off; the others absent")
            }
        }
    }

    func testTheKeysAreTheOnesTheMigrationNoteNames() {
        XCTAssertEqual(AppController.bodyModeKey, "bar.body")
        XCTAssertEqual(AppController.bodySliverKey, "bar.body.sliver")
        XCTAssertEqual(AppController.bodyPeekWaitingKey, "bar.body.peekWaiting")
        XCTAssertEqual(AppController.bodyPeekDoneKey, "bar.body.peekDone")
    }

    func testEvlatBodyForcesTheModeAndAnUnreadableValueIsIgnored() {
        XCTAssertEqual(AppController.forcedBodyMode(["EVLAT_BODY": "smart"]), .smart)
        XCTAssertEqual(AppController.forcedBodyMode(["EVLAT_BODY": "Tucked"]), .tucked)
        XCTAssertEqual(AppController.forcedBodyMode(["EVLAT_BODY": " Hidden "]), .hidden)
        XCTAssertEqual(AppController.forcedBodyMode(["EVLAT_BODY": "always"]), .always)
        XCTAssertNil(AppController.forcedBodyMode(["EVLAT_BODY": "peek"]))
        XCTAssertNil(AppController.forcedBodyMode(["EVLAT_BODY": ""]))
        XCTAssertNil(AppController.forcedBodyMode([:]))

        defaults.set("hidden", forKey: AppController.bodyModeKey)
        let env = ["EVLAT_BODY": "smart"]
        XCTAssertEqual(AppController.bodyMode(defaults, environment: env), .smart,
                       "the forced mode comes before the stored one")
        XCTAssertEqual(defaults.string(forKey: AppController.bodyModeKey), "hidden",
                       "forcing writes nothing")
        XCTAssertEqual(AppController.bodyMode(defaults, environment: ["EVLAT_BODY": "bogus"]), .hidden)
        XCTAssertEqual(AppController.bodyMode(nil, environment: [:]), .always)
    }
}
