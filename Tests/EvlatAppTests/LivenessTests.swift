import XCTest
@testable import EvlatApp

/// Edge cases for pid liveness. `/code-review` found that the first,
/// `kill(pid, 0)`-based version reported "alive" wrongly in two places.
final class LivenessTests: XCTestCase {
    func testOwnProcessIsAlive() {
        XCTAssertTrue(AppController.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
    }

    /// `kill(0, 0)` targets the caller's own process group and returns 0;
    /// `kill(-1, 0)` targets every process. Neither means "this session lives".
    func testNonPositivePidsAreNotAlive() {
        XCTAssertFalse(AppController.isProcessAlive(0))
        XCTAssertFalse(AppController.isProcessAlive(-1))
        XCTAssertFalse(AppController.isProcessAlive(-999))
    }

    /// An unused, very large pid. macOS recycles pids so "never used" cannot be
    /// claimed, but anything above `PID_MAX` (99999) is safe.
    func testImplausiblePidIsNotAlive() {
        XCTAssertFalse(AppController.isProcessAlive(999_999))
    }

    /// launchd always runs and is never a zombie.
    func testLaunchdIsAlive() {
        XCTAssertTrue(AppController.isProcessAlive(1))
    }

    /// The start time is what separates a recycled pid from the real one, so it
    /// has to be readable at all for that guard to mean anything.
    func testStartTimeIsReadableForALiveProcess() throws {
        let start = try XCTUnwrap(AppController.processStartedAt(1))
        XCTAssertGreaterThan(start.timeIntervalSince1970, 0)
        XCTAssertLessThanOrEqual(start, Date())
    }

    func testStartTimeIsNilForAnImplausiblePid() {
        XCTAssertNil(AppController.processStartedAt(999_999))
    }
}

/// `EVLAT_SESSIONS` exists so the "nothing is live" state can be produced on a
/// machine that has live sessions — the idle-cost measurement needs it.
final class SessionsDirectoryTests: XCTestCase {
    func testDefaultsToTheClaudeSessionsDirectory() throws {
        // Skipped rather than failed when the override is set: it exists
        // precisely so someone can point the app at an empty directory to take
        // the idle measurement, and running `make hepsi` in that shell must not
        // turn an environment precondition into a red suite.
        try XCTSkipIf(ProcessInfo.processInfo.environment["EVLAT_SESSIONS"] != nil,
                      "EVLAT_SESSIONS is set; this test covers the default path")
        XCTAssertEqual(AppController.sessionsDirectory().lastPathComponent, "sessions")
        XCTAssertTrue(AppController.sessionsDirectory().path.contains(".claude"))
    }
}
