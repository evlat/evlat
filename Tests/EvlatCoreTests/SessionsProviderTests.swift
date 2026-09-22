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
                       updatedAt: Int = 1_790_000_000_000, extra: String = "") throws {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"\(cwd)","kind":"interactive",
         "name":"\(name)","nameSource":"derived","status":"\(status)",
         "updatedAt":\(updatedAt),"statusUpdatedAt":\(updatedAt)\(extra)}
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
        let p = SessionsProvider(directory: dir.appendingPathComponent("yok"),
                                 platform: Platform(isAlive: { _ in true }))
        XCTAssertEqual(p.currentSignals().count, 0, "a missing directory means an empty list, not a crash")
    }

    func testRegistryHasLiveAndOrdering() throws {
        try write(pid: 100, sessionId: "resting", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "busy-one", status: "busy", updatedAt: 1_790_000_000_001)
        let registry = Registry()
        registry.register(provider())
        XCTAssertTrue(registry.hasLive)
        XCTAssertEqual(registry.aggregate(), .working)
        XCTAssertEqual(registry.ordered().map(\.entity), ["busy-one", "resting"],
                       "working sorts above idle")
    }

    func testEmptyDirectoryMeansNoLiveWork() {
        let registry = Registry()
        registry.register(provider())
        XCTAssertFalse(registry.hasLive, "with no live session the mascot goes to sleep")
        XCTAssertEqual(registry.aggregate(), .idle)
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

    func testCounterResetsBetweenScans() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"busy"}"#)
        let p = provider()
        _ = p.currentSignals()
        _ = p.currentSignals()
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1, "the counter resets on each scan; it does not accumulate")
    }
}
