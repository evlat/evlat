import XCTest
import EvlatCore
@testable import EvlatApp

/// The usage block on the open bar: its text, its model's deadband and cap,
/// and where it is laid out. The bar never branches on a source: a third
/// provider is drawn by the same code (R8).
@MainActor
final class UsageBlockTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(_ group: String, _ minutes: Int, _ progress: Double? = 0.25,
                       resetsIn: TimeInterval = 3600, seenAgo: TimeInterval = 0,
                       fidelity: Signal.Fidelity = .official) -> Signal {
        Signal(provider: "\(group.lowercased())-usage", entity: "usage:\(group):\(minutes)",
               kind: .usage, phase: .idle, progress: progress, label: group,
               fidelity: fidelity, updatedAt: now.addingTimeInterval(-seenAgo),
               usage: Signal.Usage(group: group, windowMinutes: minutes,
                                   resetsAt: now.addingTimeInterval(resetsIn)))
    }

    private func session(_ entity: String, _ phase: Phase = .idle) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: entity,
               fidelity: .official, updatedAt: now)
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    // MARK: - Text

    func testTheWindowLabelComesFromItsLength() {
        XCTAssertEqual(UsageText.windowLabel(minutes: 300, in: "en"), "5h")
        XCTAssertEqual(UsageText.windowLabel(minutes: 10080, in: "en"), "7d")
        XCTAssertEqual(UsageText.windowLabel(minutes: 1440, in: "en"), "1d")
        XCTAssertEqual(UsageText.windowLabel(minutes: 90, in: "en"), "1h 30m")
        XCTAssertEqual(UsageText.windowLabel(minutes: 45, in: "en"), "45m")
        XCTAssertEqual(UsageText.windowLabel(minutes: 2160, in: "en"), "1d 12h")
        XCTAssertEqual(UsageText.windowLabel(minutes: 300, in: "tr"), "5sa")
        XCTAssertEqual(UsageText.windowLabel(minutes: 10080, in: "tr"), "7g")
    }

    /// Two units, rounded down, the second only when it is not zero.
    func testTheCountdownRoundsDownInTwoUnits() {
        let h: TimeInterval = 3600, d: TimeInterval = 86_400
        XCTAssertEqual(UsageText.resets(in: h + 12 * 60 + 59, in: "en"), "↻ 1h 12m")
        XCTAssertEqual(UsageText.resets(in: 4 * d + 16 * h + 59 * 60, in: "en"), "↻ 4d 16h")
        XCTAssertEqual(UsageText.resets(in: 38 * 60 + 30, in: "en"), "↻ 38m")
        XCTAssertEqual(UsageText.resets(in: h - 1, in: "en"), "↻ 59m", "never rounds up to the hour")
        XCTAssertEqual(UsageText.resets(in: 2 * h, in: "en"), "↻ 2h")
        XCTAssertEqual(UsageText.resets(in: d, in: "en"), "↻ 1d")
        XCTAssertEqual(UsageText.resets(in: 59, in: "en"), "↻ 0m")
        XCTAssertEqual(UsageText.resets(in: -5, in: "en"), "↻ 0m")
        XCTAssertEqual(UsageText.resets(in: 4 * d + 16 * h, in: "tr"), "↻ 4g 16sa")
    }

    func testAStaleReadingSaysHowOldItIs() {
        XCTAssertEqual(UsageText.ago(2 * 3600 + 59 * 60, in: "en"), "2h ago")
        XCTAssertEqual(UsageText.ago(61 * 60, in: "tr"), "1sa önce")
        XCTAssertEqual(UsageText.ago(3 * 86_400, in: "tr"), "3g önce")
    }

    func testThePercentFollowsTheLanguageAndTheFidelity() {
        XCTAssertEqual(UsageText.percent(25, approximate: false, in: "en"), "25%")
        XCTAssertEqual(UsageText.percent(25, approximate: true, in: "en"), "~25%")
        XCTAssertEqual(UsageText.percent(8, approximate: true, in: "tr"), "~%8")
    }

    func testEveryKeyTheBlockAsksForExists() {
        for lang in ["en", "tr"] {
            for key in UsageText.keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    // MARK: - Presentation

    /// Fresh within the hour, stale past it, gone at the reset.
    func testFreshnessHasThreeStates() {
        let resets = now.addingTimeInterval(3600)
        XCTAssertEqual(UsageBlockModel.freshness(observedAt: now.addingTimeInterval(-59 * 60),
                                                 resetsAt: resets, now: now), .fresh)
        XCTAssertEqual(UsageBlockModel.freshness(observedAt: now.addingTimeInterval(-61 * 60),
                                                 resetsAt: resets, now: now), .stale)
        XCTAssertEqual(UsageBlockModel.freshness(observedAt: now, resetsAt: now.addingTimeInterval(1),
                                                 now: now), .fresh)
        XCTAssertEqual(UsageBlockModel.freshness(observedAt: now, resetsAt: now, now: now), .expired)
        XCTAssertEqual(UsageBlockModel.freshness(observedAt: now, resetsAt: now.addingTimeInterval(-1),
                                                 now: now), .expired)
    }

    /// A window run past its limit says 100, still amber; the signal keeps
    /// the source's number for `--list`.
    func testAWindowPastItsLimitIsDrawnAtAHundred() throws {
        let over = usage("Claude", 300, 1.01)
        let window = try XCTUnwrap(UsageBlockModel.window(over))
        XCTAssertEqual(window.percent, 100)
        XCTAssertTrue(UsageBlockModel.isHot(window, freshness: .fresh))
        XCTAssertEqual(try XCTUnwrap(UsageBlockModel.window(usage("Claude", 300, 1.0))).percent, 100)
        XCTAssertEqual(try XCTUnwrap(UsageBlockModel.window(usage("Claude", 300, 0.99))).percent, 99)
        XCTAssertTrue(AppController.usageLine(over).contains(" 101% "), "the diagnostic says what came")
    }

    func testAmberOnlyOnAFreshNumberPastTheThreshold() throws {
        let hot = try XCTUnwrap(UsageBlockModel.window(usage("Claude", 300, 0.80)))
        let cool = try XCTUnwrap(UsageBlockModel.window(usage("Claude", 300, 0.79)))
        XCTAssertTrue(UsageBlockModel.isHot(hot, freshness: .fresh))
        XCTAssertFalse(UsageBlockModel.isHot(cool, freshness: .fresh))
        XCTAssertFalse(UsageBlockModel.isHot(hot, freshness: .stale), "an old number rings no alarm")
    }

    func testTheTildeOnlyOnEvlatsOwnReading() {
        XCTAssertFalse(UsageBlockModel.isApproximate(.official))
        XCTAssertTrue(UsageBlockModel.isApproximate(.derived))
        XCTAssertTrue(UsageBlockModel.isApproximate(.manual))
    }

    // MARK: - The model

    func testLinesAreGroupedUnderTheirHeading() {
        let lines = UsageBlockModel.lines(from: [usage("Claude", 300), usage("Claude", 10080),
                                                 usage("Codex", 300)], now: now)
        XCTAssertEqual(lines.map(\.id), ["group:Claude", "usage:Claude:300", "usage:Claude:10080",
                                         "group:Codex", "usage:Codex:300"])
    }

    /// A reset window is not a line: dropped before the cap, so it pushes no
    /// live group out and the layout counts what is drawn.
    func testAResetWindowIsNotALine() {
        let signals = [usage("Claude", 300), usage("Claude", 10080),
                       usage("Codex", 300, resetsIn: 0), usage("Codex", 10080, resetsIn: -60),
                       usage("Gemini", 1440)]
        let lines = UsageBlockModel.lines(from: signals, now: now)
        XCTAssertEqual(lines.map(\.id), ["group:Claude", "usage:Claude:300", "usage:Claude:10080",
                                         "group:Gemini", "usage:Gemini:1440"])
        XCTAssertLessThanOrEqual(lines.count, UsageBlockModel.maxLines)
    }

    /// Hidden stale windows go before the cap like reset ones: the group of
    /// a tool not used for the hour leaves whole, and drawn otherwise.
    func testHidingStaleLeavesOutAToolNotSeenForTheHour() {
        let staleAgo = UsageBlockModel.staleAfter + 60
        let signals = [usage("Claude", 300), usage("Claude", 10080),
                       usage("Codex", 300, seenAgo: staleAgo), usage("Codex", 10080, seenAgo: staleAgo),
                       usage("Gemini", 300, seenAgo: 60)]
        XCTAssertEqual(UsageBlockModel.lines(from: signals, now: now, hidingStale: true).map(\.id),
                       ["group:Claude", "usage:Claude:300", "usage:Claude:10080",
                        "group:Gemini", "usage:Gemini:300"])
        XCTAssertEqual(UsageBlockModel.lines(from: signals, now: now).count, 8, "off: drawn dimmed, as before")
    }

    func testHidingStaleIsAStoredSetting() throws {
        let suite = "evlat.tests.usage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppController(defaults: defaults)
        XCTAssertFalse(controller.hidesStaleUsage, "off unless turned on")
        controller.setHidesStaleUsage(true)
        XCTAssertTrue(defaults.bool(forKey: AppController.hideStaleUsageKey))
        let host = controller.settingsHost
        XCTAssertTrue(host.hidesStaleUsage(), "the settings window reads the controller's")
        host.setHidesStaleUsage(false)
        XCTAssertFalse(controller.hidesStaleUsage)
        XCTAssertFalse(defaults.bool(forKey: AppController.hideStaleUsageKey))
    }

    /// A number that cannot be drawn is left out, not drawn as zero.
    func testAWindowWithoutANumberIsLeftOut() {
        let lines = UsageBlockModel.lines(from: [usage("Claude", 300, nil),
                                                 usage("Claude", 10080, .nan)], now: now)
        XCTAssertEqual(lines, [])
    }

    /// Only the stamp moved, inside the same minute: nothing is written.
    func testAStampMovingWithinTheMinuteDoesNotWrite() {
        let model = UsageBlockModel()
        var writes = 0
        let watch = model.objectWillChange.sink { writes += 1 }
        defer { watch.cancel() }
        let minute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        func seen(_ second: TimeInterval) -> Signal {
            usage("Claude", 300, 0.253, seenAgo: now.timeIntervalSince1970 - (minute + second))
        }
        model.update(from: [seen(1)], now: now)
        XCTAssertEqual(writes, 1)
        model.update(from: [seen(40)], now: now)
        model.update(from: [usage("Claude", 300, 0.2541, seenAgo: now.timeIntervalSince1970 - (minute + 50))],
                     now: now)
        XCTAssertEqual(writes, 1, "the same minute and the same drawn percent")
        model.update(from: [usage("Claude", 300, 0.26)], now: now.addingTimeInterval(60))
        XCTAssertEqual(writes, 2, "a drawn change is written")
    }

    /// R8, the drawing half: a source nobody wrote a line of UI for gets its
    /// own group. The cap holds today's two sources and one machine whole.
    func testAThirdSourceGetsItsOwnGroup() {
        let alone = UsageBlockModel.lines(from: [usage("Gemini", 1440)], now: now)
        XCTAssertEqual(alone.map(\.id), ["group:Gemini", "usage:Gemini:1440"])
    }

    /// Claude, Codex and one machine's Claude: nine lines, all drawn. A
    /// second machine falls off whole; the local groups stay.
    func testOneMachineFitsAndASecondFallsOffWhole() {
        let local = [usage("Claude", 300), usage("Claude", 10080),
                     usage("Codex", 300), usage("Codex", 10080)]
        let devbox = [usage("Claude · devbox", 300), usage("Claude · devbox", 10080)]
        let three = UsageBlockModel.lines(from: local + devbox, now: now)
        XCTAssertEqual(three.count, 9)
        XCTAssertEqual(UsageBlockModel.maxLines, 9)
        XCTAssertEqual(three.compactMap { line -> String? in
            guard case .header(let group) = line else { return nil }
            return group
        }, ["Claude", "Codex", "Claude · devbox"])
        let four = UsageBlockModel.lines(from: local + devbox
                                         + [usage("Claude · buildbox", 300), usage("Claude · buildbox", 10080)],
                                         now: now)
        XCTAssertEqual(four, three, "the fourth group falls off whole")
    }

    /// The machine's heading is wider than the local ones; the body holds it.
    func testTheOpenWidthHoldsAMachinesHeading() {
        let lines = UsageBlockModel.lines(from: [usage("Claude · devbox", 300)], now: now)
        let local = UsageBlockModel.lines(from: [usage("Claude", 300)], now: now)
        XCTAssertGreaterThanOrEqual(UsageBlock.minWidth(lines: lines, in: "en"),
                                    UsageBlock.minWidth(lines: local, in: "en"))
        XCTAssertLessThanOrEqual(AppController.openWidth(rows: [], usage: lines, in: "en"),
                                 AppController.expandedBarWidth)
    }

    // MARK: - Layout

    /// The closed bar does not change with usage: same length, same slots,
    /// nothing live.
    func testUsageLeavesTheClosedBarAlone() {
        let controller = AppController()
        controller.now = { [now] in now }
        let stub = Stub()
        controller.registry.register(stub)
        stub.signals = [session("a"), session("b")]
        controller.refresh()
        let closed = controller.barState.length
        let slots = controller.sessionRows.slotsInUse
        stub.signals += [usage("Claude", 300), usage("Claude", 10080)]
        controller.refresh()
        XCTAssertEqual(controller.barState.length, closed)
        XCTAssertEqual(controller.sessionRows.slotsInUse, slots)
        XCTAssertEqual(controller.usageBlock.lines.count, 3)

        stub.signals = [usage("Codex", 300)]
        controller.refresh()
        XCTAssertFalse(controller.mascot.hasLive, "a usage window is not something live")
        XCTAssertEqual(controller.barState.length, AppController.barLength(slots: 0))
    }

    /// With no session the open body holds the block under the mascot, and
    /// its length is the lines drawn.
    func testTheOpenBodyHoldsTheBlockWithoutSessions() {
        XCTAssertEqual(AppController.openLength(rows: 0, usageLines: 0), AppController.barLength(slots: 0),
                       accuracy: 0.5)
        let two = AppController.openLength(rows: 0, usageLines: 2)
        XCTAssertGreaterThan(two, AppController.barLength(slots: 0))
        XCTAssertEqual(AppController.openLength(rows: 0, usageLines: 5) - two,
                       3 * AppController.usageLineHeight, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(AppController.usageTop(rows: 0),
                                    AppController.mascotTopInset + AppController.mascotSize,
                                    "under the mascot")
        // With sessions, under the summary; the far end closes with the same room.
        let rows = 3, lines = 3
        XCTAssertGreaterThanOrEqual(AppController.usageTop(rows: rows),
                                    AppController.summaryTop(rows: rows) + AppController.summaryHeight)
        XCTAssertEqual(AppController.openLength(rows: rows, usageLines: lines)
                           - AppController.usageTop(rows: rows) - AppController.usageHeight(lines: lines),
                       AppController.mascotTopInset, accuracy: 0.5)
        XCTAssertEqual(AppController.openLength(rows: rows, usageLines: 0),
                       AppController.openLength(rows: rows), accuracy: 0.5, "no block, as before")
    }

    /// `refresh` lengthens the open body when only the block changed, and the
    /// hover area follows while open. A reset window leaves it.
    func testTheOpenLengthFollowsTheBlock() {
        let controller = AppController()
        controller.now = { [now] in now }
        let stub = Stub()
        controller.registry.register(stub)
        controller.installPanel()
        defer { controller.panel?.close() }
        stub.signals = [session("a")]
        controller.refresh()
        XCTAssertEqual(controller.barState.openLength, AppController.openLength(rows: 1), accuracy: 0.5)
        stub.signals += [usage("Claude", 300), usage("Claude", 10080)]
        controller.refresh()
        XCTAssertEqual(controller.barState.openLength, AppController.openLength(rows: 1, usageLines: 3),
                       accuracy: 0.5)
        XCTAssertEqual(controller.barState.usageTop, AppController.usageTop(rows: 1), accuracy: 0.5)
        stub.signals = [usage("Claude", 300)]
        controller.refresh()
        XCTAssertEqual(controller.barState.openLength, AppController.openLength(rows: 0, usageLines: 2),
                       accuracy: 0.5, "no sessions: the block alone")
        XCTAssertEqual(controller.barState.usageTop, AppController.usageTop(rows: 0), accuracy: 0.5)
    }

    /// The body is wide enough for the block, and never past the window's room.
    func testTheOpenWidthHoldsTheBlock() {
        let lines = UsageBlockModel.lines(from: [usage("Claude", 300), usage("Claude", 10080)], now: now)
        for lang in ["en", "tr"] {
            let block = UsageBlock.minWidth(lines: lines, in: lang)
            XCTAssertGreaterThan(block, SessionColumn.minOpenWidth, "\(lang): the block sets the width")
            XCTAssertLessThanOrEqual(block, AppController.expandedBarWidth, "\(lang): it fits the window")
            XCTAssertEqual(AppController.openWidth(rows: [], usage: lines, in: lang), block, accuracy: 0.5)
        }
        XCTAssertEqual(UsageBlock.minWidth(lines: [], in: "en"), 0)
        XCTAssertEqual(AppController.openWidth(rows: [], usage: [], in: "en"),
                       AppController.barWidth, "nothing to hold: the body hugs the mascot")
    }

    /// The window is built once for the longest open body: seven and a half
    /// rows, the summary and a full block.
    func testTheEnvelopeHoldsTheLongestOpenBody() {
        let longest = AppController.openLength(rows: 1000, usageLines: UsageBlockModel.maxLines)
        XCTAssertLessThanOrEqual(longest + AppController.shadowGutter, AppController.envelopeSize.height + 0.5)
    }

    /// The block is not the list: over it no row is picked and no scroll taken.
    func testTheBlockIsNotTheList() {
        for rows in [0, 3, 20] {
            let y = AppController.usageTop(rows: rows) + AppController.usageHeight(lines: 3) / 2
            let width = AppController.expandedBarWidth
            XCTAssertNil(AppController.slot(fromEdge: 30, fromTop: y, width: width, rows: rows), "\(rows) rows")
            XCTAssertFalse(AppController.isOverList(fromEdge: 30, fromTop: y, width: width, rows: rows),
                           "\(rows) rows")
        }
    }
}
