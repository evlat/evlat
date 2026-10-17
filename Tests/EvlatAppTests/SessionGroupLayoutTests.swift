import XCTest
@testable import EvlatApp

final class SessionGroupLayoutTests: XCTestCase {
    func testGroupGapSeparatesHitTargetsAndMovesSummary() async {
        await MainActor.run {
            let starts = [3]
            let gap = AppController.groupGap
            XCTAssertEqual(AppController.listHeight(rows: 6, groupStarts: starts),
                           AppController.listHeight(rows: 6) + gap)
            XCTAssertEqual(AppController.summaryTop(rows: 6, groupStarts: starts),
                           AppController.summaryTop(rows: 6) + gap)
            let boundary = AppController.listTop + 3 * AppController.rowPitch
            XCTAssertNil(AppController.slot(fromEdge: 20, fromTop: boundary + gap / 2,
                                            width: 200, rows: 6, groupStarts: starts))
            XCTAssertEqual(AppController.slot(fromEdge: 20, fromTop: boundary + gap + 1,
                                              width: 200, rows: 6, groupStarts: starts), 3)
        }
    }

    func testRevealAccountsForAllGroupGaps() async {
        await MainActor.run {
            let starts = [3, 6, 9]
            let end = AppController.maxScrollOffset(rows: 12, groupStarts: starts)
            XCTAssertEqual(end, AppController.maxScrollOffset(rows: 12) + 3 * AppController.groupGap)
            XCTAssertEqual(AppController.offset(revealing: 11, rows: 12, from: 0, groupStarts: starts), end)
            XCTAssertTrue(AppController.isRowVisible(11, rows: 12, offset: end, groupStarts: starts))
        }
    }
}
