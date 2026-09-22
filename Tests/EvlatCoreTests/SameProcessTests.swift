import XCTest
@testable import EvlatCore

/// The shared liveness check. One helper, but the two callers hand it a
/// reference start time from **different places**, so both shapes are pinned
/// here: the file provider passes the start time a record *claims*, and a
/// source that keeps no record passes the one it read at *first sight*.
final class SameProcessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func platform(alive: Bool = true, actualStart: Date?) -> Platform {
        Platform(isAlive: { _ in alive }, processStartedAt: { _ in actualStart })
    }

    func testADeadPidIsNeverTheSameProcess() {
        XCTAssertFalse(platform(alive: false, actualStart: start)
            .sameProcess(pid: 100, startedAt: start))
    }

    // MARK: - Shape one: the record's claim

    /// The gap a real record shows: the file is written a moment after the
    /// process starts.
    func testAClaimedStartWithinToleranceIsTheSameProcess() {
        XCTAssertTrue(platform(actualStart: start.addingTimeInterval(6))
            .sameProcess(pid: 100, startedAt: start))
    }

    /// The gap a recycled pid shows. Records live for months.
    func testARecycledPidIsNotTheSameProcess() {
        XCTAssertFalse(platform(actualStart: start.addingTimeInterval(86_400))
            .sameProcess(pid: 100, startedAt: start))
    }

    // MARK: - Shape two: the first sighting

    /// No claim exists, so the start time read on first contact becomes the
    /// reference for every later one. Same call, different origin for the
    /// second argument.
    func testAFirstSightingIsTheReferenceForTheNext() {
        let firstSighting = platform(actualStart: start).processStartedAt(100)
        XCTAssertNotNil(firstSighting)
        XCTAssertTrue(platform(actualStart: start)
            .sameProcess(pid: 100, startedAt: firstSighting))
        XCTAssertFalse(platform(actualStart: start.addingTimeInterval(3_600))
            .sameProcess(pid: 100, startedAt: firstSighting))
    }

    // MARK: - Unknowns

    /// Dropping a live session over a field that could not be read is worse
    /// than the ghost it would prevent, so both unknowns are trusted.
    func testAnUnreadableActualStartKeepsTheProcess() {
        XCTAssertTrue(platform(actualStart: nil).sameProcess(pid: 100, startedAt: start))
    }

    func testAMissingReferenceStartKeepsTheProcess() {
        XCTAssertTrue(platform(actualStart: start).sameProcess(pid: 100, startedAt: nil))
    }

    /// The tolerance is a parameter rather than a constant because the two
    /// shapes above measure different things.
    func testToleranceIsHonoured() {
        let platform = platform(actualStart: start.addingTimeInterval(30))
        XCTAssertTrue(platform.sameProcess(pid: 100, startedAt: start))
        XCTAssertFalse(platform.sameProcess(pid: 100, startedAt: start, tolerance: 10))
    }
}
