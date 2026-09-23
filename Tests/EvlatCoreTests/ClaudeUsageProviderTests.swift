import XCTest
@testable import EvlatCore

/// The `claude-usage` provider and the parser in front of it. The body is the
/// status line's JSON, which Claude Code documents; only `rate_limits` is read.
final class ClaudeUsageProviderTests: XCTestCase {
    private let fiveHourReset = 1_790_206_798
    private let weekReset = 1_790_772_967

    /// Shaped like the documented status line input, with the fields that must
    /// never be kept (`cost`, `workspace`, `model`, `session_id`).
    private func body(fiveHour: String? = "25.0", sevenDay: String? = "39.5",
                      spendLimit: Bool = true) -> [String: Any] {
        var windows: [String] = []
        if let fiveHour {
            windows.append(#""five_hour":{"used_percentage":\#(fiveHour),"resets_at":\#(fiveHourReset)}"#)
        }
        if let sevenDay {
            windows.append(#""seven_day":{"used_percentage":\#(sevenDay),"resets_at":\#(weekReset)}"#)
        }
        if spendLimit { windows.append(#""spend_limit":{"used_percentage":12}"#) }
        let text = #"{"session_id":"secret-session","model":{"id":"claude-opus","display_name":"Opus"},"#
            + #""workspace":{"current_dir":"/Users/someone/private"},"cost":{"total_cost_usd":4.2},"#
            + #""rate_limits":{\#(windows.joined(separator: ","))}}"#
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    // MARK: - The parser

    /// The documented body: two windows, keyed to minutes here (the adapter's
    /// job), and `spend_limit` counted by name rather than drawn.
    func testTheDocumentedBodyGivesTwoWindowsAndCountsTheRest() {
        let report = UsageReport(claudeStatusLine: body())
        XCTAssertEqual(report.windows, [
            UsageReport.Window(minutes: 300, usedPercent: 25,
                               resetsAt: Date(timeIntervalSince1970: TimeInterval(fiveHourReset))),
            UsageReport.Window(minutes: 10080, usedPercent: 39.5,
                               resetsAt: Date(timeIntervalSince1970: TimeInterval(weekReset))),
        ])
        XCTAssertEqual(report.unrecognizedWindows, ["spend_limit"])
    }

    /// Before the first API answer, and for a user with no subscription, there
    /// is no `rate_limits` at all: an empty report, not an error.
    func testNoRateLimitsIsAnEmptyReport() {
        let report = UsageReport(claudeStatusLine: ["session_id": "s", "cost": ["total_cost_usd": 1]])
        XCTAssertEqual(report, UsageReport(windows: [], unrecognizedWindows: []))
        XCTAssertEqual(UsageReport(claudeStatusLine: ["rate_limits": "no"]).windows, [])
    }

    /// A field that is missing or of the wrong type drops that window only.
    func testAMalformedWindowIsLeftOut() {
        for broken in [#"true"#, #""25""#, #"null"#] {
            let report = UsageReport(claudeStatusLine: body(fiveHour: broken, spendLimit: false))
            XCTAssertEqual(report.windows.map(\.minutes), [10080], broken)
        }
        let noReset = try! JSONSerialization.jsonObject(
            with: Data(#"{"rate_limits":{"five_hour":{"used_percentage":3}}}"#.utf8)) as! [String: Any]
        XCTAssertEqual(UsageReport(claudeStatusLine: noReset).windows, [])
    }

    /// Past the limit is a legal reading; it is kept as the source said it.
    func testAPercentPastOneHundredIsKept() {
        let report = UsageReport(claudeStatusLine: body(fiveHour: "134.0"))
        XCTAssertEqual(report.windows.first?.usedPercent, 134)
    }

    // MARK: - The provider

    func testAReportBecomesOfficialSignalsStampedWithTheInjectedClock() {
        let seen = Date(timeIntervalSince1970: 1_790_200_000)
        let provider = ClaudeUsageProvider(now: { seen })
        provider.handle(UsageReport(claudeStatusLine: body()))
        let signals = provider.currentSignals()
        XCTAssertEqual(signals.map(\.entity), ["usage:claude-usage:300", "usage:claude-usage:10080"])
        for signal in signals {
            XCTAssertEqual(signal.kind, .usage)
            XCTAssertEqual(signal.phase, .idle)
            XCTAssertEqual(signal.fidelity, .official)
            XCTAssertEqual(signal.provider, "claude-usage")
            XCTAssertEqual(signal.usage?.group, "Claude")
            XCTAssertEqual(signal.updatedAt, seen, "observed now, not when the window resets")
        }
        XCTAssertEqual(signals.first?.progress ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(provider.unrecognizedWindows, ["spend_limit"])
    }

    /// Windows merge one by one: a report carrying only one of them leaves the
    /// other where it was, and an empty report erases nothing.
    func testAWindowThatDidNotComeStays() {
        var clock = Date(timeIntervalSince1970: 1_790_200_000)
        let provider = ClaudeUsageProvider(now: { clock })
        provider.handle(UsageReport(claudeStatusLine: body()))
        clock += 60
        provider.handle(UsageReport(claudeStatusLine: body(fiveHour: "30.0", sevenDay: nil)))
        provider.handle(UsageReport(claudeStatusLine: ["session_id": "s"]))
        let byMinutes = Dictionary(uniqueKeysWithValues: provider.currentSignals().map { ($0.usage!.windowMinutes, $0) })
        XCTAssertEqual(byMinutes[300]?.progress ?? 0, 0.30, accuracy: 1e-9)
        XCTAssertEqual(byMinutes[300]?.updatedAt, clock)
        XCTAssertEqual(byMinutes[10080]?.progress ?? 0, 0.395, accuracy: 1e-9)
        XCTAssertEqual(byMinutes[10080]?.updatedAt, clock - 60, "the old window keeps its own stamp")
    }

    /// A window past its reset may still be a signal (the bar does not draw it),
    /// and the next report that carries it replaces it.
    func testAnExpiredWindowIsReplacedByTheNextReport() {
        var clock = Date(timeIntervalSince1970: TimeInterval(fiveHourReset) - 10)
        let provider = ClaudeUsageProvider(now: { clock })
        provider.handle(UsageReport(claudeStatusLine: body(sevenDay: nil)))
        clock = Date(timeIntervalSince1970: TimeInterval(fiveHourReset) + 10)
        XCTAssertEqual(provider.currentSignals().count, 1, "reading does not prune")

        let fresh = try! JSONSerialization.jsonObject(with: Data(
            #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":\#(fiveHourReset + 18_000)}}}"#.utf8))
            as! [String: Any]
        provider.handle(UsageReport(claudeStatusLine: fresh))
        let signal = provider.currentSignals().first
        XCTAssertEqual(signal?.usage?.resetsAt, Date(timeIntervalSince1970: TimeInterval(fiveHourReset + 18_000)))
        XCTAssertEqual(signal?.updatedAt, clock)
    }

    /// A window that stopped coming is dropped once it is past its own reset:
    /// Claude Code releases an expired window, so nothing will replace it.
    func testAnExpiredWindowThatStoppedComingIsDroppedOnTheNextReport() {
        var clock = Date(timeIntervalSince1970: TimeInterval(fiveHourReset) - 10)
        let provider = ClaudeUsageProvider(now: { clock })
        provider.handle(UsageReport(claudeStatusLine: body()))
        clock = Date(timeIntervalSince1970: TimeInterval(fiveHourReset) + 10)
        provider.handle(UsageReport(claudeStatusLine: body(fiveHour: nil)))
        XCTAssertEqual(provider.currentSignals().map { $0.usage?.windowMinutes }, [10080])
    }
}
