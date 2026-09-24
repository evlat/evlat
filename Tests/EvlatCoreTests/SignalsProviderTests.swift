import XCTest
@testable import EvlatCore

/// Outside rows' life: kept in memory, read against an injected clock, never
/// on a timer of their own.
final class SignalsProviderTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private lazy var provider = SignalsProvider(now: { [unowned self] in self.clock })

    private func report(_ id: String, ttl: Int = 60, phase: String? = "working",
                        progress: Double? = nil) -> SignalReport {
        var body: [String: Any] = ["id": id, "ttl": ttl]
        if let phase { body["phase"] = phase }
        if let progress { body["progress"] = progress }
        guard case .success(let report) = SignalReport.parse(json: body) else {
            fatalError("fixture \(body) was refused")
        }
        return report
    }

    func testAStoredRowIsARow() {
        XCTAssertEqual(provider.apply(report("a")), .stored)
        let rows = provider.currentSignals()
        XCTAssertEqual(rows.map(\.entity), ["signal:a"])
        XCTAssertEqual(rows.first?.provider, SignalsProvider.id)
        XCTAssertEqual(SignalsProvider.id, "signal")
    }

    /// Life is read when the rows are: the app's poll asks every 1.5 s, so
    /// an expired row leaves within one poll and nothing runs to remove it.
    func testAnExpiredRowLeavesOnTheNextRead() {
        _ = provider.apply(report("a", ttl: 5))
        clock += 4.9
        XCTAssertEqual(provider.currentSignals().count, 1)
        clock += 0.1
        XCTAssertTrue(provider.currentSignals().isEmpty, "at its expiry it is gone")
        XCTAssertEqual(provider.count, 0, "and not merely hidden")
    }

    /// Each POST is the whole row, and it restarts the row's life.
    func testAnUpdateRenewsTheLife() {
        _ = provider.apply(report("a", ttl: 5))
        clock += 4
        _ = provider.apply(report("a", ttl: 5))
        clock += 4
        XCTAssertEqual(provider.currentSignals().count, 1)
    }

    /// The row's stamp is when its phase began: a pulse every minute must not
    /// reset "working for 12 min" to zero.
    func testThePhaseStartSurvivesAnUpdateOfTheSamePhase() {
        let start = clock
        _ = provider.apply(report("a", progress: 0.1))
        clock += 30
        _ = provider.apply(report("a", progress: 0.5))
        let row = provider.currentSignals().first
        XCTAssertEqual(row?.updatedAt, start)
        XCTAssertEqual(row?.progress, 0.5, "everything else is the new report")
    }

    func testThePhaseStartMovesWhenThePhaseChanges() {
        _ = provider.apply(report("a"))
        clock += 30
        let finished = clock
        _ = provider.apply(report("a", phase: "done"))
        XCTAssertEqual(provider.currentSignals().first?.updatedAt, finished)
        XCTAssertEqual(provider.currentSignals().first?.phase, .review)
    }

    /// A row that expired and comes back is new: its phase begins again.
    func testAnExpiredRowComesBackWithANewStart() {
        _ = provider.apply(report("a", ttl: 5))
        clock += 10
        let back = clock
        _ = provider.apply(report("a", ttl: 5))
        XCTAssertEqual(provider.currentSignals().first?.updatedAt, back)
    }

    func testAZeroTTLClearsTheRow() {
        _ = provider.apply(report("a"))
        XCTAssertEqual(provider.apply(report("a", ttl: 0, phase: nil)), .cleared)
        XCTAssertTrue(provider.currentSignals().isEmpty)
        XCTAssertEqual(provider.apply(report("never", ttl: 0, phase: nil)), .cleared, "idempotent")
    }

    /// At most 32 live ids. A new one beyond that is dropped; one already on
    /// the bar keeps being updated.
    func testTheThirtyThirdIDIsDropped() {
        for index in 0..<SignalsProvider.limit {
            XCTAssertEqual(provider.apply(report("row-\(index)")), .stored)
        }
        XCTAssertEqual(SignalsProvider.limit, 32)
        XCTAssertEqual(provider.apply(report("row-33")), .dropped(limit: 32))
        XCTAssertEqual(provider.apply(report("row-0", phase: "done")), .stored, "an existing id is not new")
        XCTAssertEqual(provider.currentSignals().count, 32)
        XCTAssertFalse(provider.currentSignals().contains { $0.entity == "signal:row-33" })
    }

    /// Dead rows do not hold the cap: an expired row is removed before the
    /// count is taken, not only at the next read.
    func testExpiredRowsDoNotHoldTheCap() {
        for index in 0..<SignalsProvider.limit { _ = provider.apply(report("row-\(index)", ttl: 5)) }
        clock += 5
        XCTAssertEqual(provider.apply(report("fresh")), .stored)
    }

    func testTheRowsComeInAStableOrder() {
        for id in ["c", "a", "b"] { _ = provider.apply(report(id)) }
        XCTAssertEqual(provider.currentSignals().map(\.entity), ["signal:a", "signal:b", "signal:c"])
    }
}
