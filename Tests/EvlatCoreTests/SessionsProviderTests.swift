import XCTest
@testable import EvlatCore

/// The `claude-sessions` provider's contract. Entirely **headless**: fixtures
/// are written to a temporary directory and liveness is handed in as a fake
/// closure.
final class SessionsProviderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Fields taken from a real record (Claude Code 2.1.278).
    private func write(pid: Int32, sessionId: String, status: String,
                       name: String = "project", cwd: String = "/tmp/project",
                       updatedAt: Int = 1_790_000_000_000, statusUpdatedAt: Int? = nil,
                       extra: String = "") throws {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"\(cwd)","kind":"interactive",
         "name":"\(name)","nameSource":"derived","status":"\(status)",
         "updatedAt":\(updatedAt),"statusUpdatedAt":\(statusUpdatedAt ?? updatedAt)\(extra)}
        """
        try json.write(to: dir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    private func provider(alive: @escaping (Int32) -> Bool = { _ in true }) -> SessionsProvider {
        SessionsProvider(directory: dir, platform: Platform(isAlive: alive))
    }

    // MARK: - Cases

    func testReadsLiveSession() throws {
        try write(pid: 100, sessionId: "s-1", status: "busy", name: "evlat-v2")
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].entity, "s-1")
        XCTAssertEqual(signals[0].phase, .working, "busy → working")
        XCTAssertEqual(signals[0].label, "evlat-v2")
        XCTAssertEqual(signals[0].fidelity, .derived, "the format is undocumented")
        XCTAssertEqual(signals[0].provider, SessionsProvider.id)
        XCTAssertNil(signals[0].progress, "sessions produce no percentage")
        XCTAssertEqual(signals[0].source, .claude, "session files are Claude Code's")
    }

    /// The file record's only contribution to the card is the process: it
    /// knows no tool and no reply.
    func testTheRowCarriesOnlyThePid() throws {
        try write(pid: 100, sessionId: "s-1", status: "busy")
        XCTAssertEqual(provider().currentSignals().first?.activity, Signal.Activity(pid: 100))
    }

    func testDeadPidIsDropped() throws {
        try write(pid: 100, sessionId: "live", status: "busy")
        try write(pid: 200, sessionId: "dead", status: "busy")
        let signals = provider(alive: { $0 == 100 }).currentSignals()
        XCTAssertEqual(signals.map(\.entity), ["live"])
    }

    /// `claude --resume` in another terminal changes the pid, so one
    /// `sessionId` can survive in two files. The live one wins.
    func testSameSessionInTwoFilesCollapsesToOne_livePidWins() throws {
        try write(pid: 100, sessionId: "same", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "same", status: "busy", updatedAt: 1_790_000_000_001)
        let signals = provider(alive: { $0 == 100 }).currentSignals()
        XCTAssertEqual(signals.count, 1, "one record per sessionId")
        XCTAssertEqual(signals[0].phase, .idle, "the live pid wins, not the newer one")
    }

    /// When both are alive the newest `updatedAt` wins.
    func testSameSessionBothAlive_newestWins() throws {
        try write(pid: 100, sessionId: "same", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "same", status: "busy", updatedAt: 1_790_000_009_999)
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].phase, .working)
    }

    func testBrokenJsonDropsOnlyItsOwnRecord() throws {
        try write(pid: 100, sessionId: "intact", status: "busy")
        try "{ not json".write(to: dir.appendingPathComponent("200.json"),
                                    atomically: true, encoding: .utf8)
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.map(\.entity), ["intact"], "a broken record does not drop the others")
    }

    /// The `proje.md` trap: an unrecognised `status` must not sink silently
    /// into `idle`. A value actually seen on this machine: `shell`.
    func testUnknownStatusStaysVisible() throws {
        try write(pid: 100, sessionId: "s-1", status: "shell")
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].rawStatus, "shell", "the source's word is preserved")
        XCTAssertTrue(p.unrecognizedStatuses.contains("shell"),
                      "an unrecognised value must be visible in diagnostics")
    }

    func testKnownStatusIsNotReportedAsUnrecognized() throws {
        try write(pid: 100, sessionId: "s-1", status: "idle")
        let p = provider()
        _ = p.currentSignals()
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty)
    }

    func testStatusMapping() throws {
        for (status, phase) in [("busy", Phase.working), ("idle", .idle), ("waiting", .waiting)] {
            try write(pid: 100, sessionId: "s", status: status)
            XCTAssertEqual(provider().currentSignals().first?.phase, phase, "\(status)")
        }
    }

    func testMissingDirectoryYieldsNoSignals() {
        let p = SessionsProvider(directory: dir.appendingPathComponent("absent"),
                                 platform: Platform(isAlive: { _ in true }))
        XCTAssertEqual(p.currentSignals().count, 0, "a missing directory means an empty list, not a crash")
    }

    func testRegistryHasLiveAndOrdering() throws {
        try write(pid: 100, sessionId: "resting", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "busy-one", status: "busy", updatedAt: 1_790_000_000_001)
        let registry = Registry()
        registry.register(provider())
        let snapshot = registry.snapshot()
        XCTAssertTrue(snapshot.hasLive)
        XCTAssertEqual(snapshot.aggregate, .working)
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["busy-one", "resting"],
                       "working sorts above idle")
    }

    func testEmptyDirectoryMeansNoLiveWork() {
        let registry = Registry()
        registry.register(provider())
        let snapshot = registry.snapshot()
        XCTAssertFalse(snapshot.hasLive, "with no live session the mascot goes to sleep")
        XCTAssertEqual(snapshot.aggregate, .idle)
    }
}

// MARK: - Pid recycling

extension SessionsProviderTests {
    private func providerWithStart(_ start: @escaping (Int32) -> Date?) -> SessionsProvider {
        SessionsProvider(directory: dir,
                         platform: Platform(isAlive: { _ in true }, processStartedAt: start))
    }

    /// macOS recycles pids and session records live for months. If another
    /// process now owns that pid, the record is a ghost.
    func testRecycledPidIsNotTheSameSession() throws {
        let sessionStart = 1_790_000_000_000
        try write(pid: 100, sessionId: "ghost", status: "busy",
                  extra: ",\"startedAt\":\(sessionStart)")
        // A process started MUCH later now owns the same pid.
        let laterStart = Date(timeIntervalSince1970: Double(sessionStart) / 1000 + 86_400)
        XCTAssertTrue(providerWithStart({ _ in laterStart }).currentSignals().isEmpty,
                      "a mismatched start time means the session counts as dead")
    }

    func testMatchingStartTimeKeepsTheSession() throws {
        let sessionStart = 1_790_000_000_000
        try write(pid: 100, sessionId: "real", status: "busy",
                  extra: ",\"startedAt\":\(sessionStart)")
        let same = Date(timeIntervalSince1970: Double(sessionStart) / 1000 + 3)  // within tolerance
        XCTAssertEqual(providerWithStart({ _ in same }).currentSignals().map(\.entity), ["real"])
    }

    /// When the start time cannot be read the record is trusted: dropping a
    /// fresh record over an unreadable field is worse than the ghost it
    /// prevents.
    func testUnreadableStartTimeDoesNotDropTheSession() throws {
        try write(pid: 100, sessionId: "s", status: "busy", extra: ",\"startedAt\":1790000000000")
        XCTAssertEqual(providerWithStart({ _ in nil }).currentSignals().count, 1)
    }

    /// With no `startedAt` in the record (older format) no comparison runs.
    func testRecordWithoutStartedAtIsKept() throws {
        try write(pid: 100, sessionId: "s", status: "busy")
        let far = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(providerWithStart({ _ in far }).currentSignals().count, 1)
    }
}

// MARK: - Missing fields (gate findings)

extension SessionsProviderTests {
    private func writeRaw(_ name: String, _ json: String) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A **missing** field and an **unrecognised value** are different things;
    /// a record without the field must not be reported as an unknown word.
    func testMissingStatusIsNotReportedAsUnrecognized() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","cwd":"/tmp","updatedAt":1790000000000}"#)
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertNil(signals[0].rawStatus, "a missing field is nil, not an empty string")
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty, "absence is not an unrecognised value")
        XCTAssertEqual(signals[0].phase, .idle)
    }

    func testBlankStatusIsTreatedAsMissing() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"   ","updatedAt":1790000000000}"#)
        let p = provider()
        XCTAssertNil(p.currentSignals().first?.rawStatus)
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty)
    }

    /// The row's stamp is the **status** stamp. Measured in `phase-3`: on 2 of
    /// 22 live records the two fields disagree, by up to 188 690 ms. They are
    /// different facts — `updatedAt` moves when anything in the record is
    /// written, a session name included, so with that stamp a rename looks
    /// three minutes fresher than a live state.
    func testTheRowCarriesTheStatusStamp() throws {
        let status = 1_790_000_000_000
        try write(pid: 100, sessionId: "s", status: "busy",
                  updatedAt: status + 188_690, statusUpdatedAt: status)
        let signal = try XCTUnwrap(provider().currentSignals().first)
        XCTAssertEqual(signal.updatedAt.timeIntervalSince1970, Double(status) / 1000, accuracy: 0.001)
    }

    /// Picking which of two files for one session is current is a different
    /// question — "which record was written last", any write counting — and it
    /// keeps reading `updatedAt`.
    func testTheNewestFileStillWinsOnItsOwnUpdatedAt() throws {
        try write(pid: 100, sessionId: "same", status: "idle",
                  updatedAt: 1_790_000_000_000, statusUpdatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "same", status: "busy",
                  updatedAt: 1_790_000_009_999, statusUpdatedAt: 1_789_999_000_000)
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].phase, .working, "the newer file wins, stale status stamp or not")
    }

    /// If the status stamp disappears the row falls back to `updatedAt` — and
    /// says so, because a silent fallback is exactly the bug above coming back.
    func testMissingStatusUpdatedAtFallsBackAndIsVisible() throws {
        try writeRaw("100.json",
                     #"{"pid":100,"sessionId":"s","status":"busy","updatedAt":1790000000000}"#)
        let p = provider()
        let signal = try XCTUnwrap(p.currentSignals().first)
        XCTAssertEqual(signal.updatedAt.timeIntervalSince1970, 1_790_000_000, accuracy: 0.001)
        XCTAssertEqual(p.recordsMissingStatusUpdatedAt, 1, "format drift must be visible")
        XCTAssertEqual(p.recordsMissingUpdatedAt, 0, "the other field was readable")
    }

    /// An unreadable `updatedAt` must not fall back to 1970 and must stay
    /// **visible**; otherwise that record loses every dedup contest and 002's
    /// pruning wipes it.
    func testMissingUpdatedAtFallsBackAndIsVisible() throws {
        let started = 1_790_000_000_000
        try writeRaw("100.json",
                     #"{"pid":100,"sessionId":"s","status":"busy","startedAt":\#(started)}"#)
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].updatedAt.timeIntervalSince1970,
                       Double(started) / 1000, accuracy: 1,
                       "falls back to startedAt, not to 1970")
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1, "format drift must be visible")
    }

    func testMissingUpdatedAtAndStartedAtFallsBackToFileDate() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"busy"}"#)
        let p = provider()
        let signal = try XCTUnwrap(p.currentSignals().first)
        XCTAssertGreaterThan(signal.updatedAt.timeIntervalSince1970, 1_700_000_000,
                             "falls back to the file modification date")
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1)
    }

    /// Unparseable records are counted, not swallowed: a renamed `pid` or
    /// `sessionId` would otherwise empty the list while the diagnostics reported
    /// a healthy idle machine.
    func testUnparseableRecordsAreCounted() throws {
        try write(pid: 100, sessionId: "intact", status: "busy")
        try writeRaw("200.json", "{ not json")
        try writeRaw("300.json", #"{"sessionId":"no pid here"}"#)
        let p = provider()
        XCTAssertEqual(p.currentSignals().map(\.entity), ["intact"])
        XCTAssertEqual(p.recordsUnparseable, 2)
    }

    /// The unrecognised-status set reports the **last** scan, not history: a
    /// value that appeared once used to be reported for the rest of the process,
    /// so a historical gap looked exactly like a live one.
    func testUnrecognizedStatusesResetBetweenScans() throws {
        try write(pid: 100, sessionId: "s", status: "shell")
        let p = provider()
        _ = p.currentSignals()
        XCTAssertEqual(p.unrecognizedStatuses, ["shell"])

        try FileManager.default.removeItem(at: dir.appendingPathComponent("100.json"))
        try write(pid: 100, sessionId: "s", status: "busy")
        _ = p.currentSignals()
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty,
                      "a value that is gone must stop being reported")
    }

    func testCounterResetsBetweenScans() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"busy"}"#)
        let p = provider()
        _ = p.currentSignals()
        _ = p.currentSignals()
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1, "the counter resets on each scan; it does not accumulate")
    }
}
