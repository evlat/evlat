import XCTest
import EvlatCore
@testable import EvlatApp

/// `--list` prints usage windows on their own rows, apart from the sessions.
final class UsageListLineTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_790_000_000)

    func testTheUsageLineNamesTheWindowAndItsNumbers() {
        let signal = Signal(provider: "claude-usage", entity: "usage:claude-usage:300", kind: .usage,
                            phase: .idle, progress: 1.04, label: "Claude", fidelity: .official,
                            updatedAt: observed,
                            usage: Signal.Usage(group: "Claude", windowMinutes: 300,
                                                resetsAt: observed.addingTimeInterval(3_600)))
        let line = AppController.usageLine(signal)
        XCTAssertTrue(line.contains("Claude 300m"), line)
        // Past the limit is printed as it is; only the drawing clips.
        XCTAssertTrue(line.contains("104%"), line)
        XCTAssertTrue(line.contains("resets 2026-09-21T15:13:20Z"), line)
        XCTAssertTrue(line.contains("seen 2026-09-21T14:13:20Z"), line)
        XCTAssertTrue(line.hasSuffix("(official)"), line)
    }

    func testAUsageRowWithoutItsFieldStillPrints() {
        let signal = Signal(provider: "stub", entity: "usage:bare", kind: .usage, phase: .idle,
                            label: "bare", fidelity: .derived, updatedAt: observed)
        let line = AppController.usageLine(signal)
        XCTAssertTrue(line.contains("usage:bare (no window)"), line)
        XCTAssertTrue(line.contains("—"), line)
    }

    /// `--list` is where an odd number is checked; it must not trap on one.
    func testANonFiniteProgressDoesNotTrap() {
        let signal = Signal(provider: "stub", entity: "usage:odd", kind: .usage, phase: .idle,
                            progress: .infinity, label: "odd", fidelity: .derived,
                            updatedAt: observed,
                            usage: Signal.Usage(group: "Odd", windowMinutes: 60, resetsAt: observed))
        XCTAssertTrue(AppController.usageLine(signal).contains("inf"))
    }
}
