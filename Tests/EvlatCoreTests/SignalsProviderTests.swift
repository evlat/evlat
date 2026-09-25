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
    // MARK: - A machine's instance (`013`)

    private let devbox = Signal.Machine.Identity(id: "M", name: "devbox")
    private lazy var remote = SignalsProvider(now: { [unowned self] in self.clock }, machine: devbox)

    /// The machine's rows live in their own namespace and carry its name; the
    /// provider, kind and fidelity are the local row's.
    func testAMachinesRowIsNamespacedAndCarriesTheMachine() {
        remote.setLink(connected: true)
        XCTAssertEqual(remote.apply(report("x")), .stored)
        let row = remote.currentSignals().first
        XCTAssertEqual(row?.entity, "signal:M:x")
        XCTAssertEqual(row?.provider, SignalsProvider.id)
        XCTAssertEqual(row?.kind, .custom)
        XCTAssertEqual(row?.fidelity, .manual)
        XCTAssertEqual(row?.machine, Signal.Machine(name: "devbox"))
        XCTAssertEqual(row?.isLive, true)
    }

    /// The same id on two machines and on this Mac is three rows.
    func testTheSameIDOnTwoMachinesAndLocallyIsThreeRows() {
        let other = SignalsProvider(now: { [unowned self] in self.clock },
                                    machine: Signal.Machine.Identity(id: "N", name: "build"))
        for instance in [provider, remote, other] {
            instance.setLink(connected: true)
            _ = instance.apply(report("x"))
        }
        let entities = [provider, remote, other].flatMap { $0.currentSignals().map(\.entity) }
        XCTAssertEqual(Set(entities), ["signal:x", "signal:M:x", "signal:N:x"])
        XCTAssertNil(provider.currentSignals().first?.machine, "the local row has no machine")
    }

    /// The tunnel going down dims the row from that moment: it no longer
    /// drives the mascot or `hasLive`.
    func testALostLinkDimsTheRow() {
        remote.setLink(connected: true)
        _ = remote.apply(report("x"))
        clock += 30
        let lost = clock
        remote.setLink(connected: false)
        clock += 10
        let row = remote.currentSignals().first
        XCTAssertEqual(row?.isLive, false)
        XCTAssertEqual(row?.machine?.dim, Signal.Machine.Dim(reason: .disconnected, since: lost))
    }

    /// Back again, a row not heard from since stays dimmed with its first
    /// mark; one report makes it live.
    func testAReturningLinkLeavesUnheardRowsDim() {
        remote.setLink(connected: true)
        _ = remote.apply(report("x"))
        clock += 5
        let lost = clock
        remote.setLink(connected: false)
        clock += 5
        remote.setLink(connected: true)
        XCTAssertEqual(remote.currentSignals().first?.machine?.dim,
                       Signal.Machine.Dim(reason: .disconnected, since: lost))
        clock += 1
        _ = remote.apply(report("x"))
        XCTAssertEqual(remote.currentSignals().first?.isLive, true)
    }

    /// A row that arrives before the link is known is dimmed since it was heard.
    func testARowWithoutALinkIsDimSinceItWasHeard() {
        let heard = clock
        _ = remote.apply(report("x"))
        clock += 3
        XCTAssertEqual(remote.currentSignals().first?.machine?.dim,
                       Signal.Machine.Dim(reason: .disconnected, since: heard))
    }

    /// The row's life does not wait for the tunnel: a dimmed row still expires.
    func testTheTTLRunsWhileTheLinkIsDown() {
        remote.setLink(connected: true)
        _ = remote.apply(report("x", ttl: 5))
        remote.setLink(connected: false)
        clock += 5
        XCTAssertTrue(remote.currentSignals().isEmpty)
    }

    /// The cap is each instance's own: a full local bar does not stop a
    /// machine's first row.
    func testTheCapIsPerInstance() {
        for index in 0..<SignalsProvider.limit { _ = provider.apply(report("row-\(index)")) }
        XCTAssertEqual(provider.apply(report("more")), .dropped(limit: SignalsProvider.limit))
        XCTAssertEqual(remote.apply(report("row-0")), .stored)
    }
}
